import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';

/// 渲染标准 `assets/branding/fire-control-mark.svg` 几何标志，
/// 零 SVG 运行时依赖，默认自适应 Design System v3.0 语义色（昼白/暗曜）。
class FireControlLogo extends StatelessWidget {
  const FireControlLogo({
    super.key,
    required this.size,
    this.background,
    this.foreground,
  });

  final double size;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    // 默认色在 build 期按当前主题解析，避免在构造阶段固化导致切换主题失效。
    final resolvedBackground = background ?? colors.brand;
    final resolvedForeground = foreground ?? colors.onBrand;
    return Semantics(
      label: '火场智控标志',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _FireControlLogoPainter(
            background: resolvedBackground,
            foreground: resolvedForeground,
          ),
        ),
      ),
    );
  }
}

class _FireControlLogoPainter extends CustomPainter {
  const _FireControlLogoPainter({
    required this.background,
    required this.foreground,
  });

  final Color background;
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 512;
    final offset = Offset(
      (size.width - 512 * scale) / 2,
      (size.height - 512 * scale) / 2,
    );
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..scale(scale);

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = background;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(24, 24, 464, 464),
        const Radius.circular(108),
      ),
      paint,
    );

    final fieldFrame = Path()
      ..moveTo(120, 120)
      ..lineTo(236, 120)
      ..lineTo(236, 164)
      ..lineTo(164, 164)
      ..lineTo(164, 236)
      ..lineTo(120, 236)
      ..close()
      ..moveTo(392, 120)
      ..lineTo(392, 236)
      ..lineTo(348, 236)
      ..lineTo(348, 164)
      ..lineTo(276, 164)
      ..lineTo(276, 120)
      ..close()
      ..moveTo(120, 392)
      ..lineTo(120, 276)
      ..lineTo(164, 276)
      ..lineTo(164, 348)
      ..lineTo(236, 348)
      ..lineTo(236, 392)
      ..close()
      ..moveTo(392, 392)
      ..lineTo(276, 392)
      ..lineTo(276, 348)
      ..lineTo(348, 348)
      ..lineTo(348, 276)
      ..lineTo(392, 276)
      ..close();

    final decisionCore = Path()
      ..moveTo(256, 196)
      ..lineTo(316, 256)
      ..lineTo(256, 316)
      ..lineTo(196, 256)
      ..close();

    paint.color = foreground;
    canvas
      ..drawPath(fieldFrame, paint)
      ..drawPath(decisionCore, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _FireControlLogoPainter oldDelegate) {
    return oldDelegate.background != background ||
        oldDelegate.foreground != foreground;
  }
}
