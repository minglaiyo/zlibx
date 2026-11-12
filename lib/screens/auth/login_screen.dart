import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:awesome_dialog/awesome_dialog.dart';
import '../../providers/auth_provider.dart';
import '../../providers/domain_provider.dart';
import '../../routes/app_routes.dart';
import '../../providers/update_provider.dart';
import '../../utils/app_snack.dart';
import '../../widgets/domain_selector.dart';
import '../../widgets/mirror_trust_dialog.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/update_dialog.dart';
import '../../l10n/generated/app_localizations.dart';
import 'widgets/account_manager_sheet.dart';
import 'login_failure.dart';

class LoginScreen extends ConsumerStatefulWidget {
  final bool addAccountMode;

  const LoginScreen({super.key, this.addAccountMode = false});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  List<Map<String, dynamic>> _savedAccounts = const [];
  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Check for updates after frame is rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates();
      _loadSavedAccounts(prefillCredentials: !widget.addAccountMode);
    });
  }

  Future<void> _checkForUpdates() async {
    final hasUpdate = await ref
        .read(updateProvider.notifier)
        .checkForUpdate(force: true);

    if (!hasUpdate || !mounted) return;

    if (ref.read(updateProvider).forceUpdate) {
      // Force update - non-dismissable dialog with download channels
      unawaited(showUpdateDialog(context));
    } else {
      // Normal update - just show info snackbar
      // 品牌视觉（primary 背景 + action）保留原生 SnackBar，只统一入口。
      showAppSnackRaw(
        context,
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            )!.newVersionFound(ref.read(updateProvider).latestVersion ?? ''),
          ),
          action: SnackBarAction(
            label: AppLocalizations.of(context)!.update,
            onPressed: () => showUpdateDialog(context),
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _loadSavedAccounts({bool prefillCredentials = false}) async {
    final accounts = await ref.read(authProvider.notifier).getSavedAccounts();
    if (!mounted) return;

    final savedAccounts = accounts
        .map((account) => Map<String, dynamic>.from(account))
        .toList();

    if (prefillCredentials &&
        savedAccounts.isNotEmpty &&
        _emailController.text.isEmpty &&
        _passwordController.text.isEmpty &&
        !_isLoading) {
      final lastAccount = savedAccounts.last;
      final email = lastAccount['email'] as String?;

      // Passwords are never persisted: only the email can be prefilled.
      if (email != null && email.isNotEmpty) {
        _emailController.text = email;
      }
    }

    setState(() => _savedAccounts = savedAccounts);
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final currentDomain = ref.read(domainProvider);
    // Community mirrors see the typed password: confirm once per host.
    final trusted = await confirmMirrorTrust(
      context,
      currentDomain,
      builtIn: ref.read(domainListProvider).contains(currentDomain),
    );
    if (!trusted || !mounted) return;
    final lineIndex = ref.read(domainListProvider).indexOf(currentDomain);
    final lineName = lineIndex >= 0
        ? AppLocalizations.of(context)!.lineNumber(lineIndex + 1)
        : AppLocalizations.of(context)!.custom;
    setState(() => _isLoading = true);

    final success = await ref
        .read(authProvider.notifier)
        .login(email, password);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      _navigateAfterAuthentication();
    } else {
      final error = ref.read(authProvider).error;
      final occurredAt = DateTime.now()
          .toLocal()
          .toIso8601String()
          .split('.')
          .first;

      final failureKind = classifyLoginFailure(error);
      if (failureKind == LoginFailureKind.line) {
        // 线路被拦截 / 连接失败 —— 不是账号密码问题，提示切换线路。
        final cf = error == 'cf_blocked';
        unawaited(
          AwesomeDialog(
            context: context,
            dialogType: DialogType.warning,
            animType: AnimType.bottomSlide,
            title: AppLocalizations.of(context)!.lineUnavailable,
            desc: cf
                ? AppLocalizations.of(context)!.loginLineBlockedCf
                : AppLocalizations.of(context)!.loginLineConnectFailed,
            btnCancelText: AppLocalizations.of(context)!.close,
            btnCancelOnPress: () {},
            btnOkText: AppLocalizations.of(context)!.switchLine,
            btnOkColor: Theme.of(context).colorScheme.primary,
            btnOkOnPress: () {
              unawaited(
                showDialog(
                  context: context,
                  builder: (_) => const DomainSelectionDialog(),
                ),
              );
            },
          ).show(),
        );
      } else {
        unawaited(
          AwesomeDialog(
            context: context,
            dialogType: DialogType.error,
            animType: AnimType.bottomSlide,
            title: AppLocalizations.of(context)!.loginFailed,
            desc: failureKind == LoginFailureKind.credentials
                ? (AppLocalizations.of(context)!.loginBadCredentials)
                : (AppLocalizations.of(context)!.loginUnknownFailure(
                    lineName,
                    occurredAt,
                    safeLoginErrorDetail(error, email, password),
                  )),
            btnOkText: AppLocalizations.of(context)!.confirmOk,
            btnOkColor: Theme.of(context).colorScheme.primary,
            btnOkOnPress: () {},
          ).show(),
        );
      }
    }
  }

  Future<void> _showSavedAccounts() async {
    final currentUserId = widget.addAccountMode
        ? ref.read(authProvider).user?.id.toString()
        : null;
    final result = await showAccountManagerSheet(
      context,
      currentUserId: currentUserId,
    );
    if (!mounted) return;

    await _loadSavedAccounts();
    if (!mounted) return;

    switch (result) {
      case AccountManagerResult.switched:
        _navigateAfterAuthentication();
      case AccountManagerResult.addAccount:
        _emailController.clear();
        _passwordController.clear();
        _emailFocusNode.requestFocus();
      case null:
        break;
    }
  }

  void _navigateAfterAuthentication() {
    if (widget.addAccountMode) {
      Navigator.of(context).pop(true);
    } else {
      AppRoutes.goHomeAfterLogin(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          const Padding(
            padding: EdgeInsets.only(right: 16),
            child: DomainSelector(compact: true, color: Colors.white),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.book,
                      size: 60,
                      color: Colors.white,
                    ),
                  ),

                  const SizedBox(height: 24),

                  Text(
                    widget.addAccountMode
                        ? AppLocalizations.of(context)!.addAccount
                        : AppLocalizations.of(context)!.welcomeBack,
                    style: Theme.of(
                      context,
                    ).textTheme.displayMedium?.copyWith(color: Colors.white),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    widget.addAccountMode
                        ? AppLocalizations.of(context)!.addAccountSubtitle
                        : AppLocalizations.of(context)!.loginToContinue,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Open Source & Free badges
                  _buildBadges(context),

                  const SizedBox(height: 32),

                  // Login Form
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          if (_savedAccounts.isNotEmpty) ...[
                            _buildRecentAccountEntry(context),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                const Expanded(child: Divider()),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    AppLocalizations.of(
                                      context,
                                    )!.useAnotherAccount,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                                const Expanded(child: Divider()),
                              ],
                            ),
                            const SizedBox(height: 20),
                          ],
                          TextFormField(
                            controller: _emailController,
                            focusNode: _emailFocusNode,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: AppLocalizations.of(context)!.email,
                              prefixIcon: const Icon(Icons.email_outlined),
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return AppLocalizations.of(context)!.enterEmail;
                              }
                              if (!value.contains('@')) {
                                return AppLocalizations.of(context)!.validEmail;
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: 16),

                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            decoration: InputDecoration(
                              labelText: AppLocalizations.of(context)!.password,
                              prefixIcon: const Icon(Icons.lock_outlined),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                              ),
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return AppLocalizations.of(
                                  context,
                                )!.enterPassword;
                              }
                              if (value.length < 6) {
                                return AppLocalizations.of(
                                  context,
                                )!.passwordMinLength;
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: 32),

                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _handleLogin,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                              child: _isLoading
                                  ? const LoadingWidget.inline(
                                      color: Colors.white,
                                    )
                                  : Text(AppLocalizations.of(context)!.login),
                            ),
                          ),
                          if (_savedAccounts.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _isLoading ? null : _showSavedAccounts,
                              icon: const Icon(Icons.manage_accounts_outlined),
                              label: Text(
                                AppLocalizations.of(context)!.manageAccounts,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Hint: Use Z站 official account
                  _buildAccountHint(context),

                  const SizedBox(height: 16),

                  // Skip login — enter Home without account
                  _buildSkipLogin(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentAccountEntry(BuildContext context) {
    final account = _savedAccounts.last;
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final name = account['name']?.toString().trim();
    final email = account['email']?.toString().trim();
    final displayName = name == null || name.isEmpty ? l10n.unknown : name;

    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _isLoading ? null : _showSavedAccounts,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                child: Text(displayName.substring(0, 1).toUpperCase()),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.recentAccount,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (email != null && email.isNotEmpty)
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccountHint(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.info_outline,
                color: Colors.white.withValues(alpha: 0.8),
                size: 16,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  AppLocalizations.of(context)!.loginUseZsiteAccount,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context)!.loginNoAccountHint,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildSkipLogin(BuildContext context) {
    return TextButton(
      onPressed: () {
        AppRoutes.goHomeAfterLogin(context);
      },
      child: Text(
        AppLocalizations.of(context)!.loginSkipExplore,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.7),
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _buildBadges(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildBadge(
          icon: Icons.code,
          text: AppLocalizations.of(context)!.badgeOpenSource,
          color: Colors.green,
        ),
        _buildBadge(
          icon: Icons.money_off,
          text: AppLocalizations.of(context)!.searchFree,
          color: Colors.blue,
        ),
        _buildBadge(
          icon: Icons.smart_toy_outlined,
          text: AppLocalizations.of(context)!.badgeAiBuilt,
          color: Colors.purple,
        ),
      ],
    );
  }

  Widget _buildBadge({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
