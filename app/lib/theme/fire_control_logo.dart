import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// Renders the canonical assets/branding/fire-control-mark.svg geometry
/// without adding an SVG runtime dependency to the offline fireground app.
class FireControlLogo extends StatelessWidget {
  final double size;
  final Color background;
  final Color foreground;

  const FireControlLogo({
    super.key,
    required this.size,
    this.background = AppColors.actionPrimary,
    this.foreground = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '火场智控标志',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _FireControlLogoPainter(
            background: background,
            foreground: foreground,
          ),
        ),
      ),
    );
  }
}

class _FireControlLogoPainter extends CustomPainter {
  final Color background;
  final Color foreground;

  const _FireControlLogoPainter({
    required this.background,
    required this.foreground,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 512;
    final offset = Offset(
      (size.width - 512 * scale) / 2,
      (size.height - 512 * scale) / 2,
    );
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    final paint = Paint()..style = PaintingStyle.fill;
    paint.color = background;
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
    paint.color = foreground;
    canvas.drawPath(fieldFrame, paint);

    final decisionCore = Path()
      ..moveTo(256, 196)
      ..lineTo(316, 256)
      ..lineTo(256, 316)
      ..lineTo(196, 256)
      ..close();
    canvas.drawPath(decisionCore, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FireControlLogoPainter oldDelegate) {
    return oldDelegate.background != background ||
        oldDelegate.foreground != foreground;
  }
}
