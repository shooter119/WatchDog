import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// ============================================================
/// 水元素辅助头像
///
/// 使用已选定的第 2 排第 4 个水元素头像：液态侧向护目镜、波刃形水冠、
/// 深色防护模块与少量 WatchDog 橙色传感器。外层仍由统一的圆形表面、边框
/// 和阴影承载，确保欢迎态 56dp 与聊天消息 30dp 使用同一套尺寸逻辑。
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
        color: AppColors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.card,
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/avatars/water-element-avatar-selected.png',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}
