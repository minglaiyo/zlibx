import 'package:flutter/material.dart';
import '../../../theme/app_metrics.dart';
import '../../../widgets/loading_widget.dart';

/// 评论区底部输入区：可选的“回复 @某人”横幅 + 胶囊输入框 + 发送键。
/// 纯展示组件，文案由 screen 通过参数传入，因此不涉及 l10n 依赖。
class CommentComposer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// 非空时显示“正在回复”横幅。
  final String? replyBannerText;
  final String cancelTooltip;
  final String sendTooltip;
  final bool isPosting;
  final VoidCallback onCancelReply;
  final VoidCallback onSubmit;

  const CommentComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.replyBannerText,
    required this.cancelTooltip,
    required this.sendTooltip,
    required this.isPosting,
    required this.onCancelReply,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // “正在回复”横幅：出现/收起带尺寸过渡，不打断输入框布局。
          AnimatedSize(
            duration: AppMotion.quick,
            curve: Curves.easeOut,
            alignment: Alignment.bottomCenter,
            child: replyBannerText == null
                ? const SizedBox(width: double.infinity)
                : _ReplyBanner(
                    text: replyBannerText!,
                    onCancel: onCancelReply,
                    cancelTooltip: cancelTooltip,
                  ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    hintText: hintText,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSubmit(),
                ),
              ),
              const SizedBox(width: 8),
              _SendButton(
                controller: controller,
                isPosting: isPosting,
                tooltip: sendTooltip,
                onSubmit: onSubmit,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// “正在回复”横幅：主色调药丸 + 取消按钮。
class _ReplyBanner extends StatelessWidget {
  final String text;
  final VoidCallback onCancel;
  final String cancelTooltip;

  const _ReplyBanner({
    required this.text,
    required this.onCancel,
    required this.cancelTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: cancelTooltip,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 发送键：有文字才可点；发布中图标切换为加载指示。
class _SendButton extends StatelessWidget {
  final TextEditingController controller;
  final bool isPosting;
  final String tooltip;
  final VoidCallback onSubmit;

  const _SendButton({
    required this.controller,
    required this.isPosting,
    required this.tooltip,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final canSend = controller.text.trim().isNotEmpty && !isPosting;
        return IconButton.filled(
          onPressed: canSend ? onSubmit : null,
          tooltip: tooltip,
          icon: AnimatedSwitcher(
            duration: AppMotion.fast,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: isPosting
                ? const LoadingWidget.inline(color: Colors.white)
                : const Icon(Icons.send_rounded, size: 20),
          ),
        );
      },
    );
  }
}
