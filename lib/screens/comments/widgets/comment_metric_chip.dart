import 'package:flutter/material.dart';
import '../../../theme/app_metrics.dart';
import '../../../theme/motion.dart';

/// 评论下方的药丸形操作按钮：图标 + 计数。
/// 激活态（已点赞）带主色底与放大动效；忙碌中忽略点击并降透明度。
/// [onTap] 可为 null：纯展示计数（无水波、不可点），如“我的评论”页。
class CommentMetricChip extends StatelessWidget {
  final IconData icon;
  final int count;
  final VoidCallback? onTap;
  final bool active;
  final bool busy;

  const CommentMetricChip({
    super.key,
    required this.icon,
    required this.count,
    this.onTap,
    this.active = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = active ? cs.primary : cs.onSurfaceVariant;
    return IgnorePointer(
      ignoring: busy,
      child: AnimatedOpacity(
        duration: context.motionDuration(AppMotion.fast),
        opacity: busy ? 0.5 : 1,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: context.motionDuration(AppMotion.quick),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: active
                    ? cs.primary.withValues(alpha: 0.10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedScale(
                    scale: active ? 1.15 : 1,
                    duration: context.motionDuration(AppMotion.quick),
                    curve: MotionCurves.emphasized,
                    child: Icon(icon, size: 16, color: color),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    count.toString(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      // 等宽数字：点赞数变化时按钮不跳动。
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
