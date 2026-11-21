import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_spacing.dart';

/// 表面容器层级。
enum DsSurfaceLevel {
  /// 扁平次级表面（无边框、无阴影，使用 `surfaceMuted`）
  flat,

  /// 标准描边卡片（1px `border`，无厚阴影）
  outlined,

  /// 轻浮起表面（1px `border` + 昼白态极轻发丝阴影，暗曜态纯靠边线区分）
  raised,
}

/// Design System v3.0 表面卡片容器。
///
/// 采用 `Material(clipBehavior: Clip.antiAlias)` 与 1px 细描边，杜绝双层边框与厚重阴影；
/// 支持左侧 4dp 语义色条（使用 `Stack` + `Positioned` 实现，兼容内含 `LayoutBuilder` 的子组件）。
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.level = DsSurfaceLevel.outlined,
    this.accentStatus,
    this.padding,
    this.borderRadius,
    this.backgroundColor,
    this.borderColor,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final DsSurfaceLevel level;
  final DsStatus? accentStatus;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Color? backgroundColor;
  final Color? borderColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final effectiveRadius = borderRadius ?? DsRadius.borderLg;
    final effectivePadding = padding ?? DsSpacing.cardAll;

    final Color bg;
    final BorderSide side;
    final List<BoxShadow>? boxShadow;

    switch (level) {
      case DsSurfaceLevel.flat:
        bg = backgroundColor ?? colors.surfaceMuted;
        side = borderColor != null
            ? BorderSide(color: borderColor!, width: 1)
            : BorderSide.none;
        boxShadow = null;
      case DsSurfaceLevel.outlined:
        bg = backgroundColor ?? colors.surface;
        side = BorderSide(color: borderColor ?? colors.border, width: 1);
        boxShadow = null;
      case DsSurfaceLevel.raised:
        bg = backgroundColor ?? colors.surface;
        side = BorderSide(color: borderColor ?? colors.border, width: 1);
        boxShadow = ds.brightness == Brightness.light
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x0D0F172A),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ]
            : null;
    }

    final Color? accentColor = accentStatus != null
        ? colors.statusColors(accentStatus!).fill
        : null;

    Widget content = Padding(
      padding: EdgeInsets.only(left: accentColor != null ? 4.0 : 0.0),
      child: Padding(
        padding: effectivePadding,
        child: child,
      ),
    );

    if (accentColor != null) {
      content = Stack(
        children: <Widget>[
          content,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4.0,
            child: ColoredBox(color: accentColor),
          ),
        ],
      );
    }

    if (onTap != null || onLongPress != null) {
      content = InkWell(
        borderRadius: effectiveRadius,
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        onLongPress: onLongPress,
        child: content,
      );
    }

    final Widget cardMaterial = Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: effectiveRadius,
        side: side,
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    if (boxShadow != null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: effectiveRadius,
          boxShadow: boxShadow,
        ),
        child: cardMaterial,
      );
    }

    return cardMaterial;
  }
}
