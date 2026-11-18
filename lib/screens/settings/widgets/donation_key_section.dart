// Anna's Archive donation key — the user's own key, stored locally in
// secure storage (see external_download.dart). Entering it enables Anna
// fast downloads; with no key, slow download is the only Anna route
// (LibGen needs no key). The key is never logged and never leaves the
// device except to the Anna fast-download endpoint.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/external_download.dart';
import 'section_header.dart';
import 'settings_card.dart';


class DonationKeySection extends ConsumerStatefulWidget {
  const DonationKeySection({super.key});

  @override
  ConsumerState<DonationKeySection> createState() => _DonationKeySectionState();
}

class _DonationKeySectionState extends ConsumerState<DonationKeySection> {
  String _key = '';

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final value = await readAnnasDonationKey();
    if (mounted) setState(() => _key = value);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final key = _key;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        SectionHeader(icon: Icons.key_rounded, title: t.sourceAnnasArchive),
        SettingsCard(
          child: ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(t.annasDonationKey),
            subtitle: Text(
              key.isEmpty ? t.annasDonationKeyHint : '••••••••',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await showDialog(
                context: context,
                builder: (_) => _DonationKeyDialog(initialValue: key),
              );
              // The dialog writes secure storage directly; re-read to
              // refresh the subtitle (set / still empty).
              if (mounted) await _loadKey();
            },
          ),
        ),
      ],
    );
  }
}

class _DonationKeyDialog extends StatefulWidget {
  const _DonationKeyDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_DonationKeyDialog> createState() => _DonationKeyDialogState();
}

class _DonationKeyDialogState extends State<_DonationKeyDialog> {
  late final TextEditingController _controller;
  bool _obscured = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(t.annasDonationKey),
      content: TextField(
        controller: _controller,
        obscureText: _obscured,
        decoration: InputDecoration(
          hintText: t.annasDonationKeyHint,
          suffixIcon: IconButton(
            icon: Icon(
              _obscured
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
            onPressed: () => setState(() => _obscured = !_obscured),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: () async {
            await saveAnnasDonationKey(_controller.text);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(t.save),
        ),
      ],
    );
  }
}
