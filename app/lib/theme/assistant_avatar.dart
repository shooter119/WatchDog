import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// ============================================================
/// 辅助机器人头像（透明底 CustomPainter 矢量重绘）
/// 参考设计稿 watchdog-assistant-avatar.png 的视觉要素：
/// 正面消防机器人 · 防护面罩 · 双传感器 · 顶部天线
/// 深色线性工业风格 + 少量橙色点缀，无文字/火焰/耳机/聊天气泡。
/// 24×24 设计网格，线宽 1.8 与底部导航图标统一。
/// 不使用带白色背景的整张 PNG，浅色聊天背景上无白色方块。
/// ============================================================

/// 统一头像控件：圆形白底 + 边框 + 克制阴影，内部为透明底机器人
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
        child: CustomPaint(
          painter: AssistantAvatarPainter(
            line: AppColors.textPrimary,
            accent: AppColors.voice,
          ),
        ),
      ),
    );
  }
}

class AssistantAvatarPainter extends CustomPainter {
  final Color line;
  final Color accent;

  const AssistantAvatarPainter({
    this.line = AppColors.textPrimary,
    this.accent = AppColors.voice,
  });

  static const double _stroke = 1.8;

  Paint _strokePaint(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = _stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint _fillPaint(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = _strokePaint(line);

    // 顶部天线（杆 + 橙色球）
    canvas.drawLine(const Offset(12, 3.6), const Offset(12, 1.8), stroke);
    canvas.drawCircle(const Offset(12, 1.1), 1.1, _fillPaint(accent));

    // 头部
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(5, 3.6, 19, 15.8),
        const Radius.circular(3.2),
      ),
      stroke,
    );

    // 防护面罩（深色填充横条）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(7.2, 6, 16.8, 9.6),
        const Radius.circular(1.8),
      ),
      _fillPaint(line),
    );

    // 双传感器（橙色圆点）
    canvas.drawCircle(const Offset(10.2, 7.8), 1.15, _fillPaint(accent));
    canvas.drawCircle(const Offset(13.8, 7.8), 1.15, _fillPaint(accent));

    // 扬声器格栅（三条短竖线）
    for (final x in const [10.4, 12.0, 13.6]) {
      canvas.drawLine(
        Offset(x, 11.6),
        Offset(x, 13.4),
        stroke,
      );
    }

    // 机身
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(7, 15.8, 17, 20.8),
        const Radius.circular(2.4),
      ),
      stroke,
    );
  }

  @override
  bool shouldRepaint(AssistantAvatarPainter oldDelegate) =>
      oldDelegate.line != line || oldDelegate.accent != accent;
}
