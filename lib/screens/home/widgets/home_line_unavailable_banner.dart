import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../widgets/domain_selector.dart';

/// Orange strip shown when the current mirror line is unavailable.
class HomeLineUnavailableBanner extends StatelessWidget {
  const HomeLineUnavailableBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.orange.shade50,
      child: InkWell(
        // DomainNotifier.setDomain handles reverify + cache invalidation
        // internally, so just opening the picker is enough.
        onTap: () => showDialog(
          context: context,
          builder: (_) => const DomainSelectionDialog(),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  color: Colors.orange.shade800,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context)!.lineUnavailableCurrent,
                        style: TextStyle(
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        AppLocalizations.of(context)!.lineCachedLoginHint,
                        style: TextStyle(
                          color: Colors.orange.shade800,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Colors.orange.shade700,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
