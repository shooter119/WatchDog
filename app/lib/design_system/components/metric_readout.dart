import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_spacing.dart';
import '../tokens/ds_typography.dart';

/// 关键数值读数展示组件。
///
/// 强制启用 `FontFeature.tabularFigures()` 消除动态计时/读数横向抖动，
/// 并通过 `FittedBox(fit: BoxFit.scaleDown)` 保障窄屏与 130% 字号下不溢出。
/// 开启 [colorByStatus] 且提供 [status] 时采用 AAA 级 `metricText` 通道（≥ 7.0:1）。
class MetricReadout extends StatelessWidget {
  const MetricReadout({
    super.key,
    required this.value,
    this.unit,
    this.label,
    this.status,
    this.colorByStatus = false,
    this.large = false,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final String value;
  final String? unit;
  final String? label;
  final DsStatus? status;
  final bool colorByStatus;
  final bool large;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;

    final Color valueColor = (colorByStatus && status != null)
        ? colors.statusColors(status!).metricText
        : colors.textPrimary;

    final baseStyle =
        large ? ds.typography.metricLarge : ds.typography.metric;
    final valueStyle =
        DsTypography.tabular(baseStyle).copyWith(color: valueColor);
    final unitStyle = ds.typography.caption.copyWith(
      color: colors.textSecondary,
      fontWeight: FontWeight.w500,
    );

    final AlignmentGeometry fitAlignment = switch (crossAxisAlignment) {
      CrossAxisAlignment.end => Alignment.centerRight,
      CrossAxisAlignment.center => Alignment.center,
      _ => Alignment.centerLeft,
    };

    return MergeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAxisAlignment,
        children: <Widget>[
          if (label != null && label!.isNotEmpty) ...<Widget>[
            Text(
              label!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: DsSpacing.xs),
          ],
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: fitAlignment,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(value, style: valueStyle),
                if (unit != null && unit!.isNotEmpty) ...<Widget>[
                  const SizedBox(width: DsSpacing.xs),
                  Text(unit!, style: unitStyle),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
