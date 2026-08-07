import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ============================================================
/// 底部导航图标集（24×24 设计网格，统一 1.8 线宽、圆头端点）
/// 使用 CustomPainter 按矢量重绘视觉稿，任意屏幕/DPR 下保持清晰，
/// 不引入位图资源与额外依赖。
/// ============================================================

enum NavGlyph { log, board, voice, assist, settings }

/// 语义化图标控件：glyph 决定形状，color 随选中态着色
class NavIcon extends StatelessWidget {
  final NavGlyph glyph;
  final Color color;
  final double size;

  const NavIcon({
    super.key,
    required this.glyph,
    required this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: NavIconPainter(glyph: glyph, color: color)),
    );
  }
}

class NavIconPainter extends CustomPainter {
  final NavGlyph glyph;
  final Color color;

  const NavIconPainter({required this.glyph, required this.color});

  static const double _stroke = 1.8;

  Paint _strokePaint(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = _stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = _strokePaint(color);
    switch (glyph) {
      case NavGlyph.log:
        _paintLog(canvas, paint);
      case NavGlyph.board:
        _paintBoard(canvas, paint);
      case NavGlyph.voice:
        _paintVoice(canvas, paint);
      case NavGlyph.assist:
        _paintAssist(canvas, paint);
      case NavGlyph.settings:
        _paintSettings(canvas, paint);
    }
  }

  /// 日志：翻开的本子 + 三行记录线
  void _paintLog(Canvas canvas, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(3, 4, 21, 20),
        const Radius.circular(3),
      ),
      paint,
    );
    canvas.drawLine(const Offset(7, 9.5), const Offset(17, 9.5), paint);
    canvas.drawLine(const Offset(7, 12.5), const Offset(17, 12.5), paint);
    canvas.drawLine(const Offset(7, 15.5), const Offset(15.5, 15.5), paint);
  }

  /// 看板：2×2 宫格（火场态势看板）
  void _paintBoard(Canvas canvas, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(3, 4, 21, 20),
        const Radius.circular(3),
      ),
      paint,
    );
    canvas.drawLine(const Offset(12, 4.9), const Offset(12, 19.1), paint);
    canvas.drawLine(const Offset(3.9, 12), const Offset(20.1, 12), paint);
  }

  /// 语音：麦克风（胶囊身 + 弧形支架）
  void _paintVoice(Canvas canvas, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(9.2, 2.6, 14.8, 13.4),
        const Radius.circular(2.8),
      ),
      paint,
    );
    canvas.drawLine(const Offset(12, 13.4), const Offset(12, 18.6), paint);
    final arc = Path()
      ..moveTo(7.4, 15.2)
      ..arcToPoint(
        const Offset(16.6, 15.2),
        radius: const Radius.circular(4.6),
        clockwise: false,
      );
    canvas.drawPath(arc, paint);
  }

  /// 辅助：消防机器人轮廓（天线 + 圆头 + 护目镜 + 侧耳）
  void _paintAssist(Canvas canvas, Paint paint) {
    canvas.drawLine(const Offset(12, 4.8), const Offset(12, 2.2), paint);
    canvas.drawCircle(const Offset(12, 1.2), 1.1, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(5, 4.8, 19, 14.6),
        const Radius.circular(3.4),
      ),
      paint,
    );
    canvas.drawLine(const Offset(5, 9.2), const Offset(3.1, 9.2), paint);
    canvas.drawLine(const Offset(19, 9.2), const Offset(20.9, 9.2), paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(8.2, 7.4, 15.8, 9.6),
        const Radius.circular(1.2),
      ),
      paint,
    );
  }

  /// 设置：八齿齿轮
  void _paintSettings(Canvas canvas, Paint paint) {
    const c = Offset(12, 12);
    canvas.drawCircle(c, 4.6, paint);
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      canvas.drawLine(
        c + Offset(math.cos(a) * 4.6, math.sin(a) * 4.6),
        c + Offset(math.cos(a) * 7.2, math.sin(a) * 7.2),
        paint,
      );
    }
    canvas.drawCircle(c, 1.4, paint);
  }

  @override
  bool shouldRepaint(NavIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
