// 首页推荐的独立设置区块。伪随机排序是内容/推荐行为，不是外观，
// 所以单独占一个区块（SectionHeader + 单开关卡片），不塞进外观
// 底部弹层——外观弹层只留主题/模糊/导航条/布局这类观感开关。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import 'section_header.dart';
import 'settings_card.dart';

class RecommendationSection extends ConsumerWidget {
  const RecommendationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final pseudoRandomRecommend = ref.watch(pseudoRandomRecommendProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        SectionHeader(
          icon: Icons.shuffle_rounded,
          title: t.recommended,
        ),
        SettingsCard(
          child: SwitchListTile(
            title: Text(t.recommendationPseudoRandom),
            subtitle: Text(
              t.recommendationPseudoRandomDesc,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: pseudoRandomRecommend,
            activeThumbColor: cs.primary,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            onChanged: (value) {
              ref
                  .read(pseudoRandomRecommendProvider.notifier)
                  .setEnabled(value);
            },
          ),
        ),
      ],
    );
  }
}
