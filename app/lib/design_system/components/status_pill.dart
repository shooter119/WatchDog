import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_icons.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';

/// 现场态势语义胶囊。
///
/// 强制同时渲染语义图标与文字标签（永不纯色表达），采用自适应最小高度，
/// 不截断、不限制单行省略号，保证 130% 字号下完整可读。
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.status,
    this.label,
    this.icon,
    this.solid = false,
  });

  final DsStatus status;
  final String? label;
  final IconData? icon;
  final bool solid;

  static (String label, IconData icon) _defaultsFor(DsStatus status) {
    return switch (status) {
      DsStatus.safe => ('安全', DsIcons.statusSafe),
      DsStatus.caution => ('注意', DsIcons.statusCaution),
      DsStatus.alarm => ('告警', DsIcons.statusAlarm),
      DsStatus.timeout => ('超时', DsIcons.statusTimeout),
      DsStatus.neutral => ('中性', DsIcons.statusNeutral),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final pair = colors.statusColors(status);
    final (defaultLabel, defaultIcon) = _defaultsFor(status);

    final resolvedLabel =
        (label != null && label!.isNotEmpty) ? label! : defaultLabel;
    final resolvedIcon = icon ?? defaultIcon;

    final Color bg = solid ? pair.fill : pair.pillBg;
    final Color fg = solid ? pair.onFill : pair.text;
    final Color borderColor = solid
        ? Colors.transparent
        : (status == DsStatus.neutral
            ? colors.border
            : pair.fill.withValues(alpha: 0.24));

    return Container(
      constraints: const BoxConstraints(minHeight: 26),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm + 2,
        vertical: DsSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: DsRadius.borderPill,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            resolvedIcon,
            size: DsSizes.iconSm,
            color: fg,
          ),
          const SizedBox(width: DsSpacing.xs),
          Flexible(
            child: Text(
              resolvedLabel,
              style: ds.typography.micro.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
