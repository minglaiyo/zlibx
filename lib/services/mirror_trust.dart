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
//  * upgrades keep working: the line an existing install is already on
//    is confirmed once at startup ([grandfatherCurrent]); a fresh
//    install on a non-family built-in mirror asks on first login.
import 'package:zlibx/utils/host_utils.dart';

import 'hive_service.dart';


class MirrorTrust {
  MirrorTrust._();

  static const String _key = 'confirmed_mirror_hosts';

  static String hostOf(String domain) =>
      domain.trim().toLowerCase().split(':').first;

  static Set<String> confirmed() {
    final raw = HiveService.settingsBox.get(_key);
    if (raw is! List) return <String>{};
    return {for (final v in raw) v.toString()};
  }

  /// [builtIn]: whether [domain] belongs to the built-in mirror list.
  static bool isConfirmed(String domain, {required bool builtIn}) {
    final host = hostOf(domain);
    if (isZlibFamilyHost(host)) return true;
    if (!builtIn) return true; // user typed it: explicit choice
    return confirmed().contains(host);
  }

  static Future<void> confirm(String domain) async {
    final set = confirmed()..add(hostOf(domain));
    await HiveService.settingsBox.put(_key, set.toList());
  }

  /// Startup migration: an existing install (it has a saved `domain`)
  /// keeps its current line working without a prompt. Runs once — it
  /// does nothing when the confirmation list already exists.
  static Future<void> grandfatherCurrent() async {
    final box = HiveService.settingsBox;
    if (box.containsKey(_key)) return;
    final saved = box.get('domain');
    await box.put(
      _key,
      saved is String && saved.isNotEmpty ? [hostOf(saved)] : <String>[],
    );
  }
}
