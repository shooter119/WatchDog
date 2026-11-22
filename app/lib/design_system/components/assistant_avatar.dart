import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';

/// 水元素辅助头像（Design System v3.0 方案一：纯矢量几何水滴 + AI 星芒徽章）。
///
/// 采用极简现代双主题原生矢量绘制：淡指挥蓝渐变圆环 + 1px 细边框 + 指挥蓝几何水滴
/// 与四芒星闪耀徽记，零位图背景色违和感，任意尺寸（32dp / 64dp）均清晰锐利。
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
    final ds = context.ds;
    final colors = ds.colors;
    final bool isDark = ds.brightness == Brightness.dark;

    final Color bgTopLeft = Color.lerp(
      colors.surface,
      colors.brand,
      isDark ? 0.24 : 0.13,
    )!;
    final Color bgBottomRight = Color.lerp(
      colors.surface,
      colors.brand,
      isDark ? 0.09 : 0.04,
    )!;
    final Color borderColor = colors.brand.withValues(
      alpha: isDark ? 0.36 : 0.22,
    );
    final Color dropletTop = isDark ? colors.brandText : colors.brand;
    final Color dropletBottom = isDark
        ? colors.brand
        : Color.lerp(colors.brand, colors.textPrimary, 0.15)!;
    final Color sheenColor = colors.onBrand.withValues(
      alpha: isDark ? 0.36 : 0.48,
    );
    final Color sparkleColor = Color.lerp(
      colors.brandText,
      colors.onBrand,
      isDark ? 0.28 : 0.0,
    )!;

    return Semantics(
      label: '辅助头像',
      image: true,
      child: Container(
        margin: margin,
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[bgTopLeft, bgBottomRight],
          ),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: SizedBox.square(
          dimension: size * 0.64,
          child: CustomPaint(
            painter: _WaterElementMarkPainter(
              dropletTop: dropletTop,
              dropletBottom: dropletBottom,
              sheenColor: sheenColor,
              sparkleColor: sparkleColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _WaterElementMarkPainter extends CustomPainter {
  const _WaterElementMarkPainter({
    required this.dropletTop,
    required this.dropletBottom,
    required this.sheenColor,
    required this.sparkleColor,
  });

  final Color dropletTop;
  final Color dropletBottom;
  final Color sheenColor;
  final Color sparkleColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = math.min(size.width, size.height) / 24.0;
    final Offset offset = Offset(
      (size.width - 24.0 * scale) / 2.0,
      (size.height - 24.0 * scale) / 2.0,
    );
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    final Path droplet = Path()
      ..moveTo(10.8, 3.0)
      ..cubicTo(13.1, 6.3, 17.1, 10.1, 17.1, 14.3)
      ..cubicTo(17.1, 17.9, 14.3, 20.6, 10.8, 20.6)
      ..cubicTo(7.3, 20.6, 4.5, 17.9, 4.5, 14.3)
      ..cubicTo(4.5, 10.1, 8.5, 6.3, 10.8, 3.0)
      ..close();

    final Paint dropletPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[dropletTop, dropletBottom],
      ).createShader(const Rect.fromLTRB(4.5, 3.0, 17.1, 20.6));
    canvas.drawPath(droplet, dropletPaint);

    final Path sheen = Path()
      ..moveTo(7.3, 14.3)
      ..cubicTo(7.3, 16.5, 8.7, 17.9, 10.5, 18.1);
    final Paint sheenPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = sheenColor;
    canvas.drawPath(sheen, sheenPaint);

    const double sx = 18.6;
    const double sy = 6.4;
    const double sr = 3.1;
    final Path sparkle = Path()
      ..moveTo(sx, sy - sr)
      ..quadraticBezierTo(sx, sy, sx + sr, sy)
      ..quadraticBezierTo(sx, sy, sx, sy + sr)
      ..quadraticBezierTo(sx, sy, sx - sr, sy)
      ..quadraticBezierTo(sx, sy, sx, sy - sr)
      ..close();
    final Paint sparklePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = sparkleColor;
    canvas.drawPath(sparkle, sparklePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WaterElementMarkPainter oldDelegate) =>
      oldDelegate.dropletTop != dropletTop ||
      oldDelegate.dropletBottom != dropletBottom ||
      oldDelegate.sheenColor != sheenColor ||
      oldDelegate.sparkleColor != sparkleColor;
}
