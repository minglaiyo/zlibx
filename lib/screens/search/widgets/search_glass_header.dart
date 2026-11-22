import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderObject, RenderProxyBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart' show BookSource;
import '../../../providers/search_suggestions_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../theme/app_metrics.dart';
import '../../../widgets/motion/motion.dart';
import 'active_filter_chips.dart';
import 'search_bar_field.dart';
import 'search_mode_selector.dart';
import 'search_suggestions_panel.dart';
import 'source_selector.dart';

/// 毛玻璃遮罩头部（与首页同款，2026-11-20；审查 B2 拆分，2026-11-21）：
/// 搜索框 + 建议面板 + 来源/模式/chips 列，悬浮于结果区之上，结果从
/// 它底下穿过。头部高度经 [onHeightChanged] 在布局期上报（折叠/建议
/// 面板/键盘都会变），结果区的让位 padding 由屏幕用
/// ValueListenableBuilder 跟随。
///
/// 自己监听输入框与焦点：建议窗口（"聚焦 + 非空 + 正在编写新查询"）
/// 逐字刷新时只重建头部这一层，不再整屏 setState——旧实现（审查 v2
/// P2）每个按键都重建整个 Scaffold。焦点也监听：失焦时建议面板立即
/// 收起，不用等下一次按键（旧实现的收起依赖下次输入，有 staleness）。
/// chips 列的收起/展开走 [headerVisibleListenable]，折叠动画帧不再
/// 重挂结果区。
class SearchGlassHeader extends ConsumerStatefulWidget {
  const SearchGlassHeader({
    super.key,
    required this.l10n,
    required this.controller,
    required this.focusNode,
    required this.isExternal,
    required this.mode,
    required this.source,
    required this.activeFilterCount,
    required this.isQueryEmpty,
    required this.lastSubmittedQuery,
    required this.headerVisibleListenable,
    required this.showResults,
    required this.languageNames,
    required this.orderNames,
    required this.extensionNames,
    required this.selectedLanguage,
    required this.selectedOrder,
    required this.selectedExtension,
    required this.selectedYearFrom,
    required this.selectedYearTo,
    required this.exact,
    required this.selectedCategoryName,
    required this.selectedContentType,
    required this.onSubmitted,
    required this.onFilterTap,
    required this.onClear,
    required this.onScanTap,
    required this.onSelectSuggestion,
    required this.onHeightChanged,
    required this.onSwitchSource,
    required this.onSwitchMode,
    required this.onResetLanguage,
    required this.onResetOrder,
    required this.onResetExtension,
    required this.onResetYearFrom,
    required this.onResetYearTo,
    required this.onResetExact,
    required this.onResetCategory,
    required this.onResetContentType,
  });

  final AppLocalizations l10n;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isExternal;
  final SearchMode mode;
  final BookSource source;
  final int activeFilterCount;
  final bool isQueryEmpty;

  /// 最近一次提交的查询：与输入框当前文本相同 = 不是在编写新查询，
  /// 建议窗口关闭。提交后由屏幕更新并重建本组件。
  final String lastSubmittedQuery;

  /// chips 列的显隐（滚动折叠）。true = 展开。
  final ValueListenable<bool> headerVisibleListenable;

  /// 结果分支是否在屏（非结果分支没有可滚动内容，chips 强制展开）。
  final bool showResults;

  final Map<String, String> languageNames;
  final Map<String, String> orderNames;
  final Map<String, String> extensionNames;
  final String selectedLanguage;
  final String selectedOrder;
  final String selectedExtension;
  final int? selectedYearFrom;
  final int? selectedYearTo;

  /// 模式归一后的 exact 标志（全文用全文的，其余用通用的）。
  final bool exact;
  final String? selectedCategoryName;
  final String? selectedContentType;

  final VoidCallback onSubmitted;
  final VoidCallback onFilterTap;
  final VoidCallback onClear;

  /// Opens the ISBN barcode scanner (扫码搜书).
  final VoidCallback onScanTap;
  final ValueChanged<String> onSelectSuggestion;
  final ValueChanged<double> onHeightChanged;
  final ValueChanged<BookSource> onSwitchSource;
  final ValueChanged<SearchMode> onSwitchMode;
  final VoidCallback onResetLanguage;
  final VoidCallback onResetOrder;
  final VoidCallback onResetExtension;
  final VoidCallback onResetYearFrom;
  final VoidCallback onResetYearTo;
  final VoidCallback onResetExact;
  final VoidCallback onResetCategory;
  final VoidCallback onResetContentType;

  @override
  ConsumerState<SearchGlassHeader> createState() => _SearchGlassHeaderState();
}

class _SearchGlassHeaderState extends ConsumerState<SearchGlassHeader> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onInputChanged);
    widget.focusNode.addListener(_onInputChanged);
  }

  @override
  void didUpdateWidget(covariant SearchGlassHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onInputChanged);
      widget.controller.addListener(_onInputChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onInputChanged);
      widget.focusNode.addListener(_onInputChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onInputChanged);
    widget.focusNode.removeListener(_onInputChanged);
    super.dispose();
  }

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  /// 搜索建议（D1）：正在输入新查询时列出本地匹配（最近搜索 + 浏览
  /// 历史），选中即回填并搜索。提交后查询与 [SearchGlassHeader
  /// .lastSubmittedQuery] 相同，面板随之收起。
  bool get _suggestionWindowOpen =>
      widget.focusNode.hasFocus &&
      !widget.isQueryEmpty &&
      widget.controller.text.trim() != widget.lastSubmittedQuery;

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return _glassSurface(
      context,
      _MeasureSize(
        onChange: (size) => widget.onHeightChanged(size.height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SearchBarField(
              l10n: l10n,
              controller: widget.controller,
              focusNode: widget.focusNode,
              isExternal: widget.isExternal,
              activeFilterCount: widget.activeFilterCount,
              isQueryEmpty: widget.isQueryEmpty,
              hintText: widget.mode == SearchMode.fulltext
                  ? l10n.fullTextSearchHint
                  : null,
              onSubmitted: widget.onSubmitted,
              onFilterTap: widget.onFilterTap,
              onClear: widget.onClear,
              onScanTap: widget.onScanTap,
            ),
            if (_suggestionWindowOpen)
              SearchSuggestionsPanel(
                suggestions: ref.watch(
                  searchSuggestionsProvider(widget.controller.text),
                ),
                onSelect: widget.onSelectSuggestion,
              ),
            // The source / mode / filter-chip header folds away
            // (animated) while the user scrolls down through the
            // results, and folds back in when scrolling back up.
            ValueListenableBuilder<bool>(
              valueListenable: widget.headerVisibleListenable,
              builder: (context, headerVisible, _) => MotionSwitch(
                style: MotionSwitchStyle.size,
                duration: AppMotion.standard,
                child: headerVisible || !widget.showResults
                    ? Column(
                        key: const ValueKey('search-header'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SearchSourceSelector(
                            l10n: l10n,
                            selected: widget.source,
                            onSwitch: widget.onSwitchSource,
                          ),
                          if (!widget.isExternal)
                            SearchModeSelector(
                              l10n: l10n,
                              mode: widget.mode,
                              onSwitch: widget.onSwitchMode,
                            ),
                          if (!widget.isExternal &&
                              widget.activeFilterCount > 0)
                            SearchActiveFilterChips(
                              l10n: l10n,
                              mode: widget.mode,
                              languageNames: widget.languageNames,
                              orderNames: widget.orderNames,
                              extensionNames: widget.extensionNames,
                              contentTypeNames: {
                                'book': l10n.contentTypeBook,
                                'article': l10n.contentTypeArticle,
                              },
                              selectedLanguage: widget.selectedLanguage,
                              selectedOrder: widget.selectedOrder,
                              selectedExtension: widget.selectedExtension,
                              selectedYearFrom: widget.selectedYearFrom,
                              selectedYearTo: widget.selectedYearTo,
                              exact: widget.exact,
                              selectedCategoryName: widget.selectedCategoryName,
                              selectedContentType: widget.selectedContentType,
                              onResetLanguage: widget.onResetLanguage,
                              onResetOrder: widget.onResetOrder,
                              onResetExtension: widget.onResetExtension,
                              onResetYearFrom: widget.onResetYearFrom,
                              onResetYearTo: widget.onResetYearTo,
                              onResetExact: widget.onResetExact,
                              onResetCategory: widget.onResetCategory,
                              onResetContentType: widget.onResetContentType,
                            ),
                        ],
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('search-header-hidden'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 毛玻璃遮罩容器（与首页同款）：blurEnabled（外观设置）开 = 半透明
  /// surface + BackdropFilter 14；关 = 纯色实底。
  Widget _glassSurface(BuildContext context, Widget child) {
    final blurEnabled = ref.watch(blurEnabledProvider);
    final cs = Theme.of(context).colorScheme;
    final surface = Container(
      decoration: BoxDecoration(
        color: blurEnabled ? cs.surface.withValues(alpha: 0.65) : cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: child,
    );
    if (!blurEnabled) return surface;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: surface,
      ),
    );
  }
}

/// 布局期尺寸上报：子组件尺寸任何变化即时回调。头部高度用它驱动
/// 结果区的让位 padding（ValueNotifier + ValueListenableBuilder），
/// 不依赖后帧 setState——折叠动画/建议面板/键盘的每一次高度变化在
/// 下一帧重建时生效（onChange 在 performLayout 期触发，本帧 build
/// 已过；AnimatedPadding 兜住视觉过渡）。
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasureSize renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    final newSize = child?.size;
    if (newSize == null) return;
    if (_oldSize == null ||
        _oldSize!.width != newSize.width ||
        _oldSize!.height != newSize.height) {
      _oldSize = newSize;
      onChange(newSize);
    }
  }
}
