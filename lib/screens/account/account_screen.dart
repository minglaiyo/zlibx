import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../routes/app_routes.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/user_profile_section.dart';
import '../auth/login_screen.dart';
import '../auth/widgets/account_manager_sheet.dart';
import '../settings/widgets/settings_card.dart';

/// Account tab (third nav destination): the signed-in user's profile
/// hero card (the one from Settings — avatar, name, email,
/// downloads-left chip, switch-account button) plus four entry cards
/// — My Library (the old bookshelf screen, unchanged), My Comments
/// (comments the user posted), Booklists (own + public booklists,
/// read-only v1) and Download History (cloud — books downloaded on
/// any device) — and logout at the bottom. The old plain profile
/// header is gone, and Settings no longer carries the profile card
/// or logout.
///
/// No AppBar: as a tab the page starts below the status bar (SafeArea)
/// and the bottom nav already says where you are. The detail page's
/// per-book comments entry is untouched, and the Settings login card
/// stays as the other way back to login.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(authProvider).user;

    // Material instead of a nested Scaffold (see SettingsScreen).
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: true,
        bottom: false,
        child: user == null
            ? EmptyState(
                icon: Icons.person_outlined,
                title: l10n.loginToContinue,
                action: FilledButton(
                  onPressed: () =>
                      AppRoutes.openLogin(context),
                  child: Text(l10n.login),
                ),
              )
            : ListView(
                // Bottom 112 = 16 gap + 96 floating-nav clearance,
                // reserved inside the list so items scroll behind
                // the pill (like the home grid).
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 112),
                children: [
                  UserProfileSection(
                    user: user,
                    onManageAccounts: () =>
                        _manageAccounts(context, user.id.toString()),
                  ),
                  const SizedBox(height: 16),
                  _EntryCard(
                    icon: Icons.library_books_outlined,
                    title: l10n.myLibrary,
                    subtitle: l10n.myLibrarySubtitle,
                    onTap: () =>
                        AppRoutes.openFavorites(context),
                  ),
                  const SizedBox(height: 12),
                  _EntryCard(
                    icon: Icons.comment_outlined,
                    title: l10n.myComments,
                    subtitle: l10n.myCommentsSubtitle,
                    onTap: () =>
                        AppRoutes.openMyComments(context),
                  ),
                  const SizedBox(height: 12),
                  _EntryCard(
                    icon: Icons.collections_bookmark_outlined,
                    title: l10n.booklists,
                    subtitle: l10n.booklistsSubtitle,
                    onTap: () =>
                        AppRoutes.openBooklists(context),
                  ),
                  const SizedBox(height: 12),
                  _EntryCard(
                    icon: Icons.history,
                    title: l10n.downloadHistory,
                    subtitle: l10n.booksDownloadedAnyDevice,
                    onTap: () =>
                        AppRoutes.openHistory(context),
                  ),
                  const SizedBox(height: 12),
                  _EntryCard(
                    icon: Icons.manage_history,
                    title: l10n.viewHistory,
                    subtitle: l10n.viewHistorySubtitle,
                    onTap: () =>
                        AppRoutes.openViewHistory(context),
                  ),
                  const SizedBox(height: 28),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => _confirmLogout(context, ref),
                      icon: const Icon(Icons.logout, size: 18),
                      label: Text(l10n.logout),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _manageAccounts(
    BuildContext context,
    String currentUserId,
  ) async {
    final result = await showAccountManagerSheet(
      context,
      currentUserId: currentUserId,
    );
    if (result != AccountManagerResult.addAccount || !context.mounted) return;

    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const LoginScreen(addAccountMode: true),
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    unawaited(showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.logoutConfirmTitle),
        content: Text(l10n.logoutConfirmDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.logoutAction),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed != true || !context.mounted) return;
      await ref.read(authProvider.notifier).logout();
      if (context.mounted) {
        await AppRoutes.logoutToLogin(context);
      }
    }));
  }
}

class _EntryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Same bordered container as the Settings page, so the account
    // entry cards and the settings cards look identical.
    return SettingsCard(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: cs.primaryContainer,
          child: Icon(icon, color: cs.onPrimaryContainer),
        ),
        title: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: cs.onSurfaceVariant,
        ),
        onTap: onTap,
      ),
    );
  }
}
