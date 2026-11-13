import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// ============================================================
/// 水元素辅助头像
///
/// 暖砂浅米底色 + 消防救援头盔护目镜与几何水滴盾纹 + 救援橙传感器细节，
/// 统一由单层圆形容器 + 1px 主题边框承载（零重影），适配昼白/暖砂/夜间战术主题，
/// 确保欢迎态 64dp 与聊天消息 32dp 使用同一套尺寸逻辑。
/// ============================================================

class AssistantAvatar extends StatelessWidget {
  final double size;
  final EdgeInsetsGeometry? margin;

  const AssistantAvatar({super.key, this.size = 56, this.margin});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.avatarBackdrop,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/avatars/water-element-avatar-selected.png',
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
