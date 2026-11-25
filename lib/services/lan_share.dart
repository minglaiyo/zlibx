// Pure logic for the LAN web service's address picker (no platform
// access, so it is unit-testable on the host).
//
// Why this exists: a phone has several IPv4 addresses at once — the
// hotspot / Wi-Fi address a computer can reach, and the mobile-data
// address nobody on the LAN can reach (both may look like `10.x`).
// Listing them all unlabelled made users try the mobile-data one and
// time out. The picker therefore chooses ONE labelled primary address
// from the *network state* (hotspot on / Wi-Fi connected) and puts
// everything else in a "other addresses" fold, with the mobile-data
// address flagged as unreachable.
//
// Hard rules (see the requirements doc, 5.3):
//  * never hard-code an IP (not even 192.168.43.1);
//  * never guess the primary address from interface names when the
//    native network state is available — the user's phone is the
//    hotspot HOST, and a `wlan*` guess is wrong there;
//  * the interface-name fallback may only ever say "LAN" — it must not
//    claim the address is a hotspot or Wi-Fi.

/// What kind of network an address belongs to.
enum LanKind {
  /// The phone is the hotspot host; this is the hotspot interface.
  hotspot,

  /// The phone is joined to a Wi-Fi network; this is its Wi-Fi address.
  wifi,

  /// Mobile data. Unreachable from any other device on the LAN.
  cellular,

  /// Some other interface (VPN, tun, ...). Not offered as the primary.
  other,

  /// Interface-name fallback only: "some LAN address", type unknown.
  lan,
}

/// One IPv4 address on one network interface.
class LanCandidate {
  final String name;
  final String address;
  final LanKind kind;

  const LanCandidate({
    required this.name,
    required this.address,
    required this.kind,
  });

  @override
  bool operator ==(Object other) =>
      other is LanCandidate &&
      other.name == name &&
      other.address == address &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(name, address, kind);

  @override
  String toString() => 'LanCandidate($name, $address, ${kind.name})';
}

/// Structured network state from the native `lanAddressInfo` call.
class LanAddressInfo {
  final bool hotspotOn;
  final bool wifiConnected;
  final List<LanCandidate> candidates;

  const LanAddressInfo({
    required this.hotspotOn,
    required this.wifiConnected,
    required this.candidates,
  });

  /// Tolerant parser for the platform-channel map. Returns null when
  /// the payload is not usable at all (treated like "channel
  /// unavailable" by the caller).
  static LanAddressInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['interfaces'];
    final candidates = <LanCandidate>[];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final address = item['address']?.toString() ?? '';
        if (!isUsableIPv4(address)) continue;
        candidates.add(
          LanCandidate(
            name: item['name']?.toString() ?? '',
            address: address,
            kind: _kindFromName(item['kind']?.toString()),
          ),
        );
      }
    }
    return LanAddressInfo(
      hotspotOn: raw['hotspotOn'] == true,
      wifiConnected: raw['wifiConnected'] == true,
      candidates: candidates,
    );
  }

  static LanKind _kindFromName(String? name) {
    switch (name) {
      case 'hotspot':
        return LanKind.hotspot;
      case 'wifi':
        return LanKind.wifi;
      case 'cellular':
        return LanKind.cellular;
      default:
        return LanKind.other;
    }
  }
}

/// The picker's verdict.
class LanSelection {
  /// The one address shown in the main area (and in the QR code), or
  /// null when no LAN address is available.
  final LanCandidate? primary;

  /// Everything else, for the collapsed section. Cellular entries are
  /// flagged by [LanKind.cellular] (UI: "unreachable, don't use", no
  /// copy button).
  final List<LanCandidate> others;

  /// True when the native channel answered; false when [primary] (if
  /// any) comes from the interface-name fallback.
  final bool fromNative;

  const LanSelection({
    required this.primary,
    required this.others,
    required this.fromNative,
  });

  static const empty = LanSelection(
    primary: null,
    others: <LanCandidate>[],
    fromNative: true,
  );
}

/// Lenient-but-safe IPv4 check: four 0..255 parts, not loopback, not
/// unspecified, not link-local (169.254/16).
bool isUsableIPv4(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255 || p.length > 3) return false;
    nums.add(n);
  }
  if (nums[0] == 127 || nums[0] == 0) return false;
  if (nums[0] == 169 && nums[1] == 254) return false;
  return true;
}

/// Pick the address to show.
///
/// [info] is the native network state; null means the channel is
/// unavailable and the interface-name [fallback] list is used instead.
LanSelection selectLanAddress(
  LanAddressInfo? info, {
  List<LanCandidate> fallback = const <LanCandidate>[],
}) {
  if (info != null) return _selectFromState(info);
  return _selectFromNames(fallback);
}

LanSelection _selectFromState(LanAddressInfo info) {
  // Branch on the NETWORK STATE, never on interface names: hotspot on
  // → the hotspot interface; else Wi-Fi connected → the Wi-Fi one.
  LanKind? wanted;
  if (info.hotspotOn) {
    wanted = LanKind.hotspot;
  } else if (info.wifiConnected) {
    wanted = LanKind.wifi;
  }

  LanCandidate? primary;
  if (wanted != null) {
    for (final c in info.candidates) {
      if (c.kind == wanted) {
        primary = c;
        break;
      }
    }
  }
  final others = [
    for (final c in info.candidates)
      if (c != primary) c,
  ];
  return LanSelection(
    primary: primary,
    others: _sortOthers(others),
    fromNative: true,
  );
}

/// Interface names of mobile data. Used ONLY by the fallback, to keep
/// the mobile-data address out of the primary slot.
final RegExp _cellularName = RegExp(
  r'^(rmnet|v4-rmnet|ccmni|pdp|ppp|seth|wwan|rev_rmnet)',
  caseSensitive: false,
);

/// Interface names that are clearly not a LAN (VPN/tun/dummy/...).
final RegExp _nonLanName = RegExp(
  r'^(lo|tun|tap|dummy|ip6|sit|gre|ipsec|clat|bt-pan|p2p)',
  caseSensitive: false,
);

/// Names that usually carry a LAN. Only consulted by the fallback.
final RegExp _lanName = RegExp(
  r'^(wlan|swlan|ap|softap|wigig|rndis|eth|usb|ncm)',
  caseSensitive: false,
);

/// Last-resort path: the native channel is unavailable, so all we have
/// is interface names. The primary is labelled [LanKind.lan] — never
/// hotspot or Wi-Fi, because names cannot tell the two apart.
LanSelection _selectFromNames(List<LanCandidate> fallback) {
  LanCandidate? primary;
  final others = <LanCandidate>[];
  for (final c in fallback) {
    if (!isUsableIPv4(c.address)) continue;
    if (_cellularName.hasMatch(c.name)) {
      others.add(
        LanCandidate(name: c.name, address: c.address, kind: LanKind.cellular),
      );
    } else if (_nonLanName.hasMatch(c.name)) {
      others.add(
        LanCandidate(name: c.name, address: c.address, kind: LanKind.other),
      );
    } else if (primary == null && _lanName.hasMatch(c.name)) {
      primary = LanCandidate(
        name: c.name,
        address: c.address,
        kind: LanKind.lan,
      );
    } else {
      others.add(
        LanCandidate(name: c.name, address: c.address, kind: LanKind.other),
      );
    }
  }
  return LanSelection(
    primary: primary,
    others: _sortOthers(others),
    fromNative: false,
  );
}

/// Fold order: reachable-looking first, mobile data last.
List<LanCandidate> _sortOthers(List<LanCandidate> list) {
  int rank(LanKind k) => k == LanKind.cellular ? 1 : 0;
  final copy = [...list];
  copy.sort((a, b) => rank(a.kind).compareTo(rank(b.kind)));
  return copy;
}

/// The URL for a primary address.
String lanUrl(String address, int port) => 'http://$address:$port/';

/// Parse `/proc/net/arp` into connected-client IPv4 addresses.
///
/// Best effort: Android 10+ without root usually returns only the
/// header line. Returns null — "unknown" — when nothing usable was
/// found, so the UI never claims "no device connected" from an empty
/// or unreadable table. [device] limits entries to one interface.
List<String>? parseArpClients(String content, {String? device}) {
  final lines = content.split('\n');
  final clients = <String>[];
  for (var i = 1; i < lines.length; i++) {
    final cols = lines[i].trim().split(RegExp(r'\s+'));
    if (cols.length < 6) continue;
    final ip = cols[0];
    final flags = cols[2];
    final mac = cols[3];
    final dev = cols[5];
    if (!isUsableIPv4(ip)) continue;
    // Flags 0x0 = incomplete entry; all-zero MAC = no neighbour.
    if (flags == '0x0' || mac == '00:00:00:00:00:00') continue;
    if (device != null && dev != device) continue;
    if (!clients.contains(ip)) clients.add(ip);
  }
  return clients.isEmpty ? null : clients;
}
