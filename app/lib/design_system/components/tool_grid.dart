import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';

/// [ToolGrid] 单个工具入口数据模型。
@immutable
class DsToolItem {
  const DsToolItem({
    required this.id,
    required this.icon,
    required this.label,
    this.badge,
    this.badgeStatus = DsStatus.alarm,
    this.enabled = true,
    this.onTap,
  });

  final String id;
  final IconData icon;
  final String label;
  final String? badge;
  final DsStatus badgeStatus;
  final bool enabled;
  final VoidCallback? onTap;
}

/// Design System v3.0 响应式 4 列工具网格。
///
/// 采用分块 `IntrinsicHeight` + `Row` + `Expanded` 等分单元格实现（严禁使用固定
/// `childAspectRatio` 的 `GridView`），保证 360dp 窄屏与 130% 字号放大下每行自适应撑开且零溢出。
class ToolGrid extends StatelessWidget {
  const ToolGrid({
    super.key,
    required this.items,
    this.columns = 4,
    this.spacing = DsSpacing.sm,
    this.runSpacing = DsSpacing.sm,
  }) : assert(columns > 0, 'ToolGrid 列数必须大于 0');

  final List<DsToolItem> items;
  final int columns;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final rows = <List<DsToolItem?>>[];
    for (var i = 0; i < items.length; i += columns) {
      final chunk = <DsToolItem?>[];
      for (var j = 0; j < columns; j++) {
        final index = i + j;
        chunk.add(index < items.length ? items[index] : null);
      }
      rows.add(chunk);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var r = 0; r < rows.length; r++) ...<Widget>[
          if (r > 0) SizedBox(height: runSpacing),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var c = 0; c < columns; c++) ...<Widget>[
                  if (c > 0) SizedBox(width: spacing),
                  Expanded(
                    child: rows[r][c] != null
                        ? _ToolGridCell(item: rows[r][c]!)
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ToolGridCell extends StatelessWidget {
  const _ToolGridCell({required this.item});

  final DsToolItem item;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final bool interactive = item.enabled && item.onTap != null;
    final badgePair = colors.statusColors(item.badgeStatus);
    final hasBadge = item.badge != null && item.badge!.isNotEmpty;

    return Semantics(
      button: true,
      enabled: interactive,
      label: hasBadge ? '${item.label}，${item.badge}' : item.label,
      child: Material(
        key: Key('ds-tool-${item.id}'),
        color: item.enabled ? colors.surface : colors.surfaceMuted,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderMd,
          side: BorderSide(color: colors.border, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: DsRadius.borderMd,
          onTap: interactive
              ? () {
                  HapticFeedback.selectionClick();
                  item.onTap!();
                }
              : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.xs,
                vertical: DsSpacing.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 44,
                    height: 38,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: <Widget>[
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: item.enabled
                                ? colors.brand.withValues(alpha: 0.08)
                                : colors.surface,
                            borderRadius: DsRadius.borderMd,
                            border: Border.all(
                              color: item.enabled
                                  ? colors.brand.withValues(alpha: 0.14)
                                  : colors.border,
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            item.icon,
                            size: 20,
                            color: item.enabled
                                ? colors.brandText
                                : colors.textTertiary,
                          ),
                        ),
                        if (hasBadge)
                          Positioned(
                            top: -2,
                            right: -4,
                            child: Container(
                              constraints: const BoxConstraints(
                                minWidth: 16,
                                minHeight: 16,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: badgePair.fill,
                                borderRadius: DsRadius.borderPill,
                              ),
                              child: Text(
                                item.badge!,
                                textAlign: TextAlign.center,
                                style: typo.micro.copyWith(
                                  fontSize: 10,
                                  height: 1.1,
                                  color: badgePair.onFill,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    item.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: typo.caption.copyWith(
                      color: item.enabled
                          ? colors.textPrimary
                          : colors.textTertiary,
                      fontWeight: FontWeight.w500,
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
