import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import 'incident_category_style.dart';

/// DS v3.0 警情三大类徽标（统一使用 RemixIcon 矢量并与头部标签图标严格一致）。
class IncidentCategoryIconBadge extends StatelessWidget {
  const IncidentCategoryIconBadge({
    super.key,
    required this.category,
    this.size = 40,
    this.iconSize = 22,
  });

  final DsIncidentCategory category;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final palette = IncidentCategoryStyle.paletteOf(
      category,
      context.ds.colors,
    );
    final label = IncidentCategoryStyle.labelOf(category);

    return Semantics(
      label: '$label类警情',
      image: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: DsRadius.borderMd,
          border: Border.all(color: palette.border, width: 1),
        ),
        child: Icon(
          IncidentCategoryStyle.iconOf(category),
          size: iconSize,
          color: palette.text,
        ),
      ),
    );
  }
}

/// DS v3.0 警情分类芯片（支持静态胶囊与 48dp 可选交互态）。
class IncidentCategoryChip extends StatelessWidget {
  const IncidentCategoryChip({
    super.key,
    required this.category,
    this.label,
    this.selected = false,
    this.onTap,
  });

  final DsIncidentCategory category;
  final String? label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final palette = IncidentCategoryStyle.paletteOf(category, colors);
    final resolvedLabel =
        (label != null && label!.isNotEmpty)
            ? label!
            : IncidentCategoryStyle.labelOf(category);
    final icon = IncidentCategoryStyle.iconOf(category);

    final Color bg = selected ? palette.fill : palette.surface;
    final Color fg = selected
        ? (category == DsIncidentCategory.aid
              ? colors.onBrand
              : colors
                    .statusColors(
                      category == DsIncidentCategory.fire
                          ? DsStatus.alarm
                          : DsStatus.caution,
                    )
                    .onFill)
        : palette.text;
    final Color borderColor = selected ? palette.fill : palette.border;

    final Widget content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: onTap != null ? DsSpacing.md : DsSpacing.sm,
        vertical: onTap != null ? DsSpacing.sm : DsSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: DsSizes.iconSm, color: fg),
          const SizedBox(width: DsSpacing.xs),
          Flexible(
            child: Text(
              resolvedLabel,
              style: ds.typography.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return Container(
        constraints: const BoxConstraints(minHeight: 26),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: DsRadius.borderPill,
          border: Border.all(color: borderColor, width: 1),
        ),
        child: content,
      );
    }

    return Semantics(
      button: true,
      selected: selected,
      label: resolvedLabel,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderPill,
          side: BorderSide(color: borderColor, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: DsRadius.borderPill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: DsSizes.touchTarget,
              minWidth: DsSizes.touchTarget,
            ),
            child: Center(widthFactor: 1, child: content),
          ),
        ),
      ),
    );
  }
}

/// 自适应防孤字文本组件：避免多行末行仅剩单个中文字符掉行。
class IncidentAntiOrphanText extends StatelessWidget {
  const IncidentAntiOrphanText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final maxWidth = constraints.maxWidth;
        final fontSize = style.fontSize ?? 14.0;
        if (!maxWidth.isFinite || maxWidth <= fontSize * 6) {
          return Text(
            text,
            style: style,
            maxLines: maxLines,
            overflow: overflow,
            softWrap: true,
          );
        }

        final effectiveWidth = _resolveAntiOrphanWidth(
          text: text,
          style: style,
          maxWidth: maxWidth,
          fontSize: fontSize,
          scaler: MediaQuery.textScalerOf(context),
          direction: Directionality.of(context),
          maxLines: maxLines,
        );

        final textWidget = Text(
          text,
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          softWrap: true,
        );
        if (effectiveWidth == null) return textWidget;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: effectiveWidth),
          child: textWidget,
        );
      },
    );
  }

  static double? _resolveAntiOrphanWidth({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required double fontSize,
    required TextScaler scaler,
    required TextDirection direction,
    int? maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: scaler,
      textDirection: direction,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);

    final metrics = painter.computeLineMetrics();
    if (metrics.length < 2) {
      painter.dispose();
      return null;
    }

    final lastLineText = _lastLineText(painter, text, metrics.last);
    painter.dispose();
    if (lastLineText.runes.length != 1) return null;

    final step = scaler.scale(fontSize) * 1.35;
    final candidateWidth = maxWidth - step;
    if (candidateWidth < scaler.scale(fontSize) * 4) return null;

    final adjustedPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: scaler,
      textDirection: direction,
      maxLines: maxLines,
    )..layout(maxWidth: candidateWidth);

    final adjustedMetrics = adjustedPainter.computeLineMetrics();
    final tooManyLines =
        adjustedMetrics.length < 2 ||
        (maxLines != null && adjustedMetrics.length > maxLines);
    final adjustedLastLine = tooManyLines
        ? ''
        : _lastLineText(adjustedPainter, text, adjustedMetrics.last);
    adjustedPainter.dispose();

    return adjustedLastLine.runes.length >= 2 ? candidateWidth : null;
  }

  static String _lastLineText(
    TextPainter painter,
    String text,
    LineMetrics lastMetric,
  ) {
    final pos = painter.getPositionForOffset(Offset(0, lastMetric.baseline));
    final range = painter.getLineBoundary(pos);
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    return text.substring(start, end).trim();
  }
}
