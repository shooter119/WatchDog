import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';

/// 水元素辅助头像（Design System v3.0）。
///
/// 统一采用单层圆形容器 + 1px 语义描边承载（零重影），自适应昼白/暗曜双主题，
/// 供欢迎态（64dp）与消息列表（32dp）复用同一套尺寸与兜底渲染逻辑。
class AssistantAvatar extends StatelessWidget {
  const AssistantAvatar({
    super.key,
    this.size = 56,
    this.margin,
  });

  final double size;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return Semantics(
      label: '辅助头像',
      image: true,
      child: Container(
        margin: margin,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          shape: BoxShape.circle,
          border: Border.all(color: colors.border, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(
          'assets/avatars/water-element-avatar-selected.png',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => Icon(
            Icons.water_drop_rounded,
            size: size * 0.5,
            color: colors.brandText,
          ),
        ),
      ),
    );
  }
}
