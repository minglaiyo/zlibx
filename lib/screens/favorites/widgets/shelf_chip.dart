import 'package:flutter/material.dart';

/// 书架统一的胶囊筛选 chip；[dense] 用于次级（分类）筛选行。
class ShelfChip extends StatelessWidget {
  const ShelfChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(),
      shape: const StadiumBorder(),
      visualDensity: dense ? VisualDensity.compact : null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelStyle: TextStyle(
        fontSize: dense ? 12 : 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
      ),
      color: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? cs.primaryContainer
            : cs.surfaceContainerHigh,
      ),
      side: BorderSide.none,
    );
  }
}
