import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/domain_provider.dart';
import '../../../providers/speed_test_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/domain_selector.dart';
import '../mirrors_page.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// Network line picker — same chevron-tile shape as the other settings.
/// Shows "Line N · 234ms" (latency from the latest speed test) and only
/// ever displays the line index, never the underlying domain.
class NetworkSection extends ConsumerWidget {
  const NetworkSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final currentDomain = ref.watch(domainProvider);
    final domains = ref.watch(domainListProvider);
    final speedState = ref.watch(speedTestProvider);

    final idx = domains.indexOf(currentDomain);
    final lineLabel = idx >= 0
        ? t.lineNumber(idx + 1)
        : (AppLocalizations.of(context)!.customLine);

    // Look up the latency for the current line.
    int? latency;
    for (final r in speedState.results) {
      if (r.domain == currentDomain) {
        latency = r.latencyMs;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(icon: Icons.dns_rounded, title: t.network),
        SettingsCard(
          child: ListTile(
            leading: const Icon(Icons.public_rounded),
            title: Text(t.networkLine),
            subtitle: _LineStatus(
              label: lineLabel,
              latency: latency,
              testing: speedState.testing,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog(
              context: context,
              builder: (_) => const DomainSelectionDialog(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Mirror management (ported from OpenlibExtended): which
        // open-slum.org mirrors the app may talk to, and in what order.
        SettingsCard(
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(t.mirrors),
            subtitle: Text(t.mirrorsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MirrorsPage())),
          ),
        ),
      ],
    );
  }
}

class _LineStatus extends StatelessWidget {
  final String label;
  final int? latency;
  final bool testing;

  const _LineStatus({
    required this.label,
    required this.latency,
    required this.testing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (statusText, statusColor) = _statusFor(context, latency, testing, cs);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            statusText,
            style: TextStyle(
              fontSize: 12,
              color: statusColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _statusFor(
    BuildContext context,
    int? latency,
    bool testing,
    ColorScheme cs,
  ) {
    final status = domainLatencyStatus(latency);
    if (status == DomainLatencyStatus.untested) {
      return (
        testing
            ? (AppLocalizations.of(context)!.speedTesting)
            : (AppLocalizations.of(context)!.speedUntested),
        cs.onSurfaceVariant,
      );
    }
    if (status == DomainLatencyStatus.unavailable) {
      return (AppLocalizations.of(context)!.lineStatusUnavailable, cs.error);
    }
    if (status == DomainLatencyStatus.normal) {
      return ('${latency!}ms', AppColors.success);
    }
    if (status == DomainLatencyStatus.slow) {
      return ('${latency}ms', AppColors.warning);
    }
    return ('${latency}ms', cs.onSurfaceVariant);
  }
}
