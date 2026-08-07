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

/// 统一头像控件：圆形白底 + 边框 + 克制阴影，内部为透明底消防机器人
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
            shell: AppColors.surfaceSubtle,
          ),
        ),
      ),
    );
  }
}

class AssistantAvatarPainter extends CustomPainter {
  final Color line;
  final Color accent;
  final Color shell;

  const AssistantAvatarPainter({
    this.line = AppColors.textPrimary,
    this.accent = AppColors.voice,
    this.shell = AppColors.surfaceSubtle,
  });

  static const double _stroke = 1.25;

  Paint _strokePaint(Color c, [double width = _stroke]) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint _fillPaint(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = _strokePaint(line);

    // 顶部低矮天线：保留机器人识别点，但避免卡通化的长触角。
    canvas.drawLine(const Offset(12, 3.6), const Offset(12, 2.1), stroke);
    canvas.drawCircle(const Offset(12, 1.55), 0.62, _fillPaint(accent));

    // 一体式防护头罩：圆角六边形轮廓比“方盒子脑袋”更接近消防面罩。
    final helmet = Path()
      ..moveTo(8.1, 4.1)
      ..quadraticBezierTo(12, 2.9, 15.9, 4.1)
      ..cubicTo(18.3, 4.8, 19.4, 6.6, 19.4, 9)
      ..lineTo(19.4, 13.8)
      ..cubicTo(19.4, 17.5, 16.3, 20.3, 12, 21.4)
      ..cubicTo(7.7, 20.3, 4.6, 17.5, 4.6, 13.8)
      ..lineTo(4.6, 9)
      ..cubicTo(4.6, 6.6, 5.7, 4.8, 8.1, 4.1)
      ..close();
    canvas.drawPath(helmet, _fillPaint(shell));
    canvas.drawPath(helmet, stroke);

    // 两侧加固件，提供工业防护感并稳定小尺寸轮廓。
    canvas.drawLine(const Offset(4.6, 10), const Offset(3.5, 10.8), stroke);
    canvas.drawLine(const Offset(4.6, 13.8), const Offset(3.5, 13), stroke);
    canvas.drawLine(const Offset(19.4, 10), const Offset(20.5, 10.8), stroke);
    canvas.drawLine(const Offset(19.4, 13.8), const Offset(20.5, 13), stroke);

    // 深色防护目镜：横向比例克制，避免像夸张卡通眼睛。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(6.6, 7.1, 17.4, 12.2),
        const Radius.circular(2.2),
      ),
      _fillPaint(line),
    );

    // 双传感器是唯一高亮色区域，保持正面、冷静、无表情。
    canvas.drawCircle(const Offset(9.5, 9.65), 0.82, _fillPaint(accent));
    canvas.drawCircle(const Offset(14.5, 9.65), 0.82, _fillPaint(accent));

    // 下部呼吸防护模块，使用两道水平进气槽而不是“嘴巴/牙齿”。
    final respirator = Path()
      ..moveTo(8.7, 14.2)
      ..lineTo(15.3, 14.2)
      ..lineTo(14.5, 17.8)
      ..quadraticBezierTo(12, 19, 9.5, 17.8)
      ..close();
    canvas.drawPath(respirator, stroke);
    final vent = _strokePaint(line, 0.9);
    canvas.drawLine(const Offset(10.2, 15.5), const Offset(13.8, 15.5), vent);
    canvas.drawLine(const Offset(10.6, 16.8), const Offset(13.4, 16.8), vent);
  }

  @override
  bool shouldRepaint(AssistantAvatarPainter oldDelegate) =>
      oldDelegate.line != line ||
      oldDelegate.accent != accent ||
      oldDelegate.shell != shell;
}
