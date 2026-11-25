// Dart wrapper for the `zlibx/network_state` platform channel and the
// two tiny platform reads the address picker needs.
//
// All the selection logic lives in lan_share.dart (pure, unit-tested);
// this file only talks to the platform and hands plain data over.
import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/diagnostics.dart';
import 'lan_share.dart';

class NetworkStateChannel {
  NetworkStateChannel._();

  static const MethodChannel _channel = MethodChannel('zlibx/network_state');

  /// Structured network state from Kotlin (`lanAddressInfo`), or null
  /// when the channel is unavailable / failed — the caller then uses
  /// the interface-name fallback and must not claim a network type.
  static Future<LanAddressInfo?> lanAddressInfo() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('lanAddressInfo');
      return LanAddressInfo.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      logIgnored('network_state', error);
      return null;
    }
  }

  /// All non-loopback IPv4 addresses by interface name (last-resort
  /// fallback input for [selectLanAddress]).
  static Future<List<LanCandidate>> fallbackInterfaces() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            LanCandidate(name: i.name, address: a.address, kind: LanKind.other),
      ];
    } catch (error) {
      logIgnored('network_state', error);
      return const <LanCandidate>[];
    }
  }

  /// Connected clients from `/proc/net/arp`, best effort. Null =
  /// unknown (unreadable or no entries) — never "no devices".
  static Future<List<String>?> arpClients({String? device}) async {
    try {
      final text = await File('/proc/net/arp').readAsString();
      return parseArpClients(text, device: device);
    } catch (_) {
      return null;
    }
  }
}
