import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/auth_provider.dart';
import '../../../widgets/loading_widget.dart';

import '../../../utils/app_snack.dart';
enum AccountManagerResult { switched, addAccount }

Future<AccountManagerResult?> showAccountManagerSheet(
  BuildContext context, {
  String? currentUserId,
}) {
  return showModalBottomSheet<AccountManagerResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AccountManagerSheet(currentUserId: currentUserId),
  );
}

class AccountManagerSheet extends ConsumerStatefulWidget {
  final String? currentUserId;

  const AccountManagerSheet({super.key, this.currentUserId});

  @override
  ConsumerState<AccountManagerSheet> createState() =>
      _AccountManagerSheetState();
}

class _AccountManagerSheetState extends ConsumerState<AccountManagerSheet> {
  List<Map<String, dynamic>> _accounts = const [];
  String? _switchingUserId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final stored = await ref.read(authProvider.notifier).getSavedAccounts();
    if (!mounted) return;

    setState(() {
      _accounts = stored.map((account) {
        return Map<String, dynamic>.from(account);
      }).toList();
      _isLoading = false;
    });
  }

  Future<void> _switchAccount(Map<String, dynamic> account) async {
    final userId = account['userId']?.toString();
    if (userId == null || userId == widget.currentUserId) return;

    setState(() => _switchingUserId = userId);
    final success = await ref
        .read(authProvider.notifier)
        .switchAccount(account);
    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop(AccountManagerResult.switched);
      return;
    }

    setState(() => _switchingUserId = null);
    showAppSnack(context,
          AppLocalizations.of(context)!.switchAccountFailed,
        );
  }

  Future<void> _confirmRemove(Map<String, dynamic> account) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.removeAccountTitle),
        content: Text(l10n.removeAccountMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: Text(l10n.remove),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    unawaited(HapticFeedback.mediumImpact());

    await ref
        .read(authProvider.notifier)
        .removeAccount(account['userId'].toString());
    await _loadAccounts();

    if (!mounted) return;
    showAppSnack(context, l10n.accountRemoved);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.accountManagement,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: l10n.close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(child: _buildAccountList(context)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(AccountManagerResult.addAccount),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(l10n.addAccount),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountList(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return const LoadingWidget.page();
    }

    if (_accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline_rounded,
              size: 40,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.noSavedAccounts,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.noSavedAccountsMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _accounts.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, indent: 68, color: cs.outlineVariant),
      itemBuilder: (context, index) {
        final account = _accounts[index];
        return _AccountTile(
          account: account,
          isCurrent: account['userId']?.toString() == widget.currentUserId,
          isSwitching: account['userId']?.toString() == _switchingUserId,
          onTap: () => _switchAccount(account),
          onRemove: () => _confirmRemove(account),
        );
      },
    );
  }
}

class _AccountTile extends StatelessWidget {
  final Map<String, dynamic> account;
  final bool isCurrent;
  final bool isSwitching;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _AccountTile({
    required this.account,
    required this.isCurrent,
    required this.isSwitching,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final name = account['name']?.toString().trim();
    final email = account['email']?.toString().trim();
    final displayName = name == null || name.isEmpty
        ? l10n.unknown
        : name;
    final displayEmail = email == null || email.isEmpty ? '-' : email;

    return ListTile(
      enabled: !isSwitching,
      contentPadding: const EdgeInsets.only(left: 8, right: 4),
      leading: CircleAvatar(
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        child: Text(displayName.substring(0, 1).toUpperCase()),
      ),
      title: Text(
        displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        displayEmail,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isSwitching
          ? const LoadingWidget.inline()
          : isCurrent
          ? Tooltip(
              message: l10n.currentAccount,
              child: Icon(Icons.check_circle_rounded, color: cs.primary),
            )
          : PopupMenuButton<String>(
              tooltip: l10n.accountActions,
              onSelected: (_) => onRemove(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'remove',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline_rounded,
                        color: cs.error,
                      ),
                      const SizedBox(width: 12),
                      Text(l10n.removeAccount),
                    ],
                  ),
                ),
              ],
            ),
      onTap: isCurrent || isSwitching ? null : onTap,
    );
  }
}
