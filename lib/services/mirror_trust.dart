// Which mirror hosts may receive the user's account (password at login,
// session key on re-verify).
//
// The built-in line list is made of community mirrors that the
// Z-Library project does not operate. Whoever runs one can read the
// email/password typed into the login form and the `remix_userkey`
// session that is re-sent when the user switches line. So the app asks
// ONCE per host before any credential is sent there, and remembers the
// answer.
//
// Rules ([isConfirmed]):
//  * hosts of the Z-Library site family ([isZlibFamilyHost]) need no
//    prompt — that includes the default line `bookroom.lifestyle`;
//  * a host the user typed in as a custom line is their own explicit
//    choice — no prompt;
//  * every other built-in mirror needs a stored confirmation;
//  * a host that is neither family, nor user-entered, nor built-in
//    (a SLUM mirror never in the list, or one since delisted) is
//    NOT confirmed — it gets a prompt, and the stored session is
//    never auto-sent there;
//  * upgrades keep working: the line an existing install is already on
//    is confirmed once at startup ([grandfatherCurrent]); a fresh
//    install on a non-family built-in mirror asks on first login.
import 'package:zlibx/utils/host_utils.dart';

import 'hive_service.dart';


class MirrorTrust {
  MirrorTrust._();

  static const String _key = 'confirmed_mirror_hosts';

  /// Hosts the user typed in as a custom line (M7). This is the only
  /// record of "the user explicitly chose this host": the old
  /// `!builtIn` shortcut in [isConfirmed] treated "not currently in
  /// the built-in list" as "user typed it", so a mirror delisted from
  /// the list (or a SLUM mirror never in it) silently inherited trust
  /// and received the stored session.
  static const String _customKey = 'custom_mirror_hosts';

  static String hostOf(String domain) =>
      domain.trim().toLowerCase().split(':').first;

  static Set<String> confirmed() {
    final raw = HiveService.settingsBox.get(_key);
    if (raw is! List) return <String>{};
    return {for (final v in raw) v.toString()};
  }

  static Set<String> customEntered() {
    final raw = HiveService.settingsBox.get(_customKey);
    if (raw is! List) return <String>{};
    return {for (final v in raw) v.toString()};
  }

  /// [builtIn]: whether [domain] belongs to the built-in mirror list.
  static bool isConfirmed(String domain, {required bool builtIn}) {
    final host = hostOf(domain);
    if (isZlibFamilyHost(host)) return true;
    if (customEntered().contains(host)) return true;
    if (!builtIn) return false;
    return confirmed().contains(host);
  }

  static Future<void> confirm(String domain) async {
    final set = confirmed()..add(hostOf(domain));
    await HiveService.settingsBox.put(_key, set.toList());
  }

  /// Record a host the user typed in as a custom line. Called from
  /// [DomainNotifier.setCustomDomain] (see domain_provider.dart).
  static Future<void> recordCustomEntered(String domain) async {
    final set = customEntered()..add(hostOf(domain));
    await HiveService.settingsBox.put(_customKey, set.toList());
  }

  /// Startup migration: an existing install (it has a saved `domain`)
  /// keeps its current line working without a prompt. Runs once per
  /// key — it does nothing when the list already exists.
  static Future<void> grandfatherCurrent() async {
    final box = HiveService.settingsBox;
    if (!box.containsKey(_key)) {
      final saved = box.get('domain');
      await box.put(
        _key,
        saved is String && saved.isNotEmpty ? [hostOf(saved)] : <String>[],
      );
    }
    // M7: one-time migration for the custom-entered set. Installs
    // already running on a non-built-in line (a domain the user typed
    // before this set existed, or a mirror since delisted) keep
    // working without a prompt.
    if (!box.containsKey(_customKey)) {
      final saved = box.get('domain');
      final host = saved is String && saved.isNotEmpty ? hostOf(saved) : '';
      await box.put(
        _customKey,
        host.isEmpty || isZlibFamilyHost(host) ? <String>[] : [host],
      );
    }
  }
}
