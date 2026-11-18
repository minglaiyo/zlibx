import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/mirror_trust.dart';


/// Asks the user, once per host, before credentials go to a community
/// mirror. Returns true when [domain] is (or has just been) confirmed.
///
/// Callers pass [builtIn] = whether the host is in the built-in line
/// list; custom lines the user typed never prompt (see [MirrorTrust]).
Future<bool> confirmMirrorTrust(
  BuildContext context,
  String domain, {
  required bool builtIn,
}) async {
  if (MirrorTrust.isConfirmed(domain, builtIn: builtIn)) return true;
  final l10n = AppLocalizations.of(context)!;
  final host = MirrorTrust.hostOf(domain);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.shield_outlined),
      title: Text(l10n.mirrorTrustTitle),
      content: Text(l10n.mirrorTrustBody(host)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.mirrorTrustConfirm),
        ),
      ],
    ),
  );
  if (ok == true) {
    await MirrorTrust.confirm(domain);
    return true;
  }
  return false;
}
