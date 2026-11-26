// Address picker: network-state branching, mobile-data handling,
// interface-name fallback honesty, ARP parsing.
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/lan_share.dart';

LanCandidate c(String name, String ip, LanKind kind) =>
    LanCandidate(name: name, address: ip, kind: kind);

void main() {
  // The real environment from the requirements: the phone is the
  // hotspot host (10.197.10.152); mobile data is 10.100.126.143.
  final hotspot = c('ap0', '10.197.10.152', LanKind.hotspot);
  final cellular = c('rmnet_data1', '10.100.126.143', LanKind.cellular);
  final wifi = c('wlan0', '192.168.1.23', LanKind.wifi);
  final tun = c('tun0', '198.18.0.1', LanKind.other);

  group('selectLanAddress (native state)', () {
    test('hotspot on → the hotspot address is primary', () {
      final sel = selectLanAddress(
        LanAddressInfo(
          hotspotOn: true,
          wifiConnected: false,
          candidates: [cellular, hotspot],
        ),
      );
      expect(sel.primary, hotspot);
      expect(sel.fromNative, isTrue);
    });

    test('mobile data is never primary, is flagged and sorted last', () {
      final sel = selectLanAddress(
        LanAddressInfo(
          hotspotOn: true,
          wifiConnected: false,
          candidates: [cellular, tun, hotspot],
        ),
      );
      expect(sel.primary, isNot(cellular));
      expect(sel.others.map((e) => e.address), contains('10.100.126.143'));
      expect(sel.others.last, cellular);
      expect(sel.others.last.kind, LanKind.cellular);
    });

    test('wifi connected (no hotspot) → the Wi-Fi address is primary', () {
      final sel = selectLanAddress(
        LanAddressInfo(
          hotspotOn: false,
          wifiConnected: true,
          candidates: [cellular, wifi],
        ),
      );
      expect(sel.primary, wifi);
      expect(sel.primary!.kind, LanKind.wifi);
    });

    test('hotspot wins when both hotspot and Wi-Fi are up', () {
      final sel = selectLanAddress(
        LanAddressInfo(
          hotspotOn: true,
          wifiConnected: true,
          candidates: [wifi, hotspot],
        ),
      );
      expect(sel.primary, hotspot);
    });

    test('no hotspot and no Wi-Fi → no address at all', () {
      final sel = selectLanAddress(
        LanAddressInfo(
          hotspotOn: false,
          wifiConnected: false,
          candidates: [cellular, wifi],
        ),
      );
      expect(sel.primary, isNull);
    });

    test('state says hotspot but no hotspot address: do not guess wlan', () {
      final sel = selectLanAddress(
        LanAddressInfo(
          hotspotOn: true,
          wifiConnected: false,
          candidates: [wifi, cellular],
        ),
      );
      expect(sel.primary, isNull);
    });
  });

  group('selectLanAddress (channel unavailable → name fallback)', () {
    test('primary is labelled lan, never hotspot or wifi', () {
      final sel = selectLanAddress(
        null,
        fallback: [
          c('rmnet_data1', '10.100.126.143', LanKind.other),
          c('wlan0', '10.197.10.152', LanKind.other),
        ],
      );
      expect(sel.fromNative, isFalse);
      expect(sel.primary!.address, '10.197.10.152');
      expect(sel.primary!.kind, LanKind.lan);
      expect(sel.primary!.kind, isNot(LanKind.hotspot));
      expect(sel.primary!.kind, isNot(LanKind.wifi));
    });

    test('mobile data stays out of the primary slot', () {
      final sel = selectLanAddress(
        null,
        fallback: [c('rmnet_data1', '10.100.126.143', LanKind.other)],
      );
      expect(sel.primary, isNull);
      expect(sel.others.single.kind, LanKind.cellular);
    });

    test('loopback / link-local addresses are ignored', () {
      final sel = selectLanAddress(
        null,
        fallback: [
          c('wlan0', '127.0.0.1', LanKind.other),
          c('wlan1', '169.254.3.4', LanKind.other),
        ],
      );
      expect(sel.primary, isNull);
      expect(sel.others, isEmpty);
    });
  });

  group('LanAddressInfo.fromMap', () {
    test('parses a channel payload and drops unusable addresses', () {
      final info = LanAddressInfo.fromMap(<String, Object?>{
        'hotspotOn': true,
        'wifiConnected': false,
        'interfaces': <Object?>[
          <String, Object?>{
            'name': 'ap0',
            'address': '10.197.10.152',
            'kind': 'hotspot',
          },
          <String, Object?>{
            'name': 'lo',
            'address': '127.0.0.1',
            'kind': 'other',
          },
          'garbage',
        ],
      });
      expect(info, isNotNull);
      expect(info!.hotspotOn, isTrue);
      expect(info.candidates, [hotspot.copyNamed('ap0')]);
    });

    test('a non-map payload means "channel unavailable"', () {
      expect(LanAddressInfo.fromMap(null), isNull);
      expect(LanAddressInfo.fromMap('x'), isNull);
    });
  });

  test('isUsableIPv4', () {
    expect(isUsableIPv4('10.197.10.152'), isTrue);
    expect(isUsableIPv4('192.168.0.1'), isTrue);
    expect(isUsableIPv4('127.0.0.1'), isFalse);
    expect(isUsableIPv4('0.0.0.0'), isFalse);
    expect(isUsableIPv4('169.254.1.1'), isFalse);
    expect(isUsableIPv4('256.1.1.1'), isFalse);
    expect(isUsableIPv4('1.2.3'), isFalse);
    expect(isUsableIPv4('fe80::1'), isFalse);
  });

  test('lanUrl carries the actual port', () {
    expect(lanUrl('10.197.10.152', 8080), 'http://10.197.10.152:8080/');
    expect(lanUrl('10.197.10.152', 41269), 'http://10.197.10.152:41269/');
  });

  group('parseArpClients', () {
    const header =
        'IP address       HW type     Flags       HW address            Mask     Device\n';

    test('reads a connected client', () {
      final text =
          '${header}10.197.10.60    0x1         0x2         aa:bb:cc:dd:ee:ff     *        ap0\n';
      expect(parseArpClients(text), ['10.197.10.60']);
    });

    test('incomplete / zero-MAC entries are skipped', () {
      final text =
          '${header}10.197.10.61    0x1         0x0         00:00:00:00:00:00     *        ap0\n';
      expect(parseArpClients(text), isNull);
    });

    test('header only (Android 10+) is unknown, not "no devices"', () {
      expect(parseArpClients(header), isNull);
      expect(parseArpClients(''), isNull);
    });

    test('device filter', () {
      final text =
          '${header}10.197.10.60    0x1         0x2         aa:bb:cc:dd:ee:ff     *        ap0\n'
          '192.168.1.9      0x1         0x2         11:22:33:44:55:66     *        wlan0\n';
      expect(parseArpClients(text, device: 'wlan0'), ['192.168.1.9']);
    });
  });
}

extension on LanCandidate {
  LanCandidate copyNamed(String n) =>
      LanCandidate(name: n, address: address, kind: kind);
}
