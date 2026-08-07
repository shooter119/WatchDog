import 'package:flutter/material.dart';

/// ============================================================
/// 底部导航图标集（24×24 设计网格，统一 1.8 线宽、圆头端点）
/// 形状与设计稿 watchdog-bottom-nav-icons 一致，使用 CustomPainter
/// 矢量重绘，任意屏幕/DPR 下保持清晰，不引入位图资源与额外依赖。
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

  Paint _fillPaint(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.fill;

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

  /// 日志：左侧时间线 + 三个节点圆点 + 三条记录线
  void _paintLog(Canvas canvas, Paint paint) {
    canvas.drawLine(const Offset(7, 4.5), const Offset(7, 19.5), paint);
    canvas.drawCircle(const Offset(7, 6), 1.5, _fillPaint(color));
    canvas.drawCircle(const Offset(7, 12), 1.5, _fillPaint(color));
    canvas.drawCircle(const Offset(7, 18), 1.5, _fillPaint(color));
    canvas.drawLine(const Offset(11, 6), const Offset(19, 6), paint);
    canvas.drawLine(const Offset(11, 12), const Offset(19, 12), paint);
    canvas.drawLine(const Offset(11, 18), const Offset(19, 18), paint);
  }

  /// 看板：2×2 四个独立圆角宫格（火场态势看板）
  void _paintBoard(Canvas canvas, Paint paint) {
    for (final r in [
      const Rect.fromLTWH(4, 4, 7, 7),
      const Rect.fromLTWH(13, 4, 7, 7),
      const Rect.fromLTWH(4, 13, 7, 7),
      const Rect.fromLTWH(13, 13, 7, 7),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(1.2)),
        paint,
      );
    }
  }

  /// 语音：麦克风（胶囊身 + 下方弧形拾音罩 + 支架）
  void _paintVoice(Canvas canvas, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(9, 3.5, 15, 14.5),
        const Radius.circular(3),
      ),
      paint,
    );
    final arc = Path()
      ..moveTo(5.5, 11.5)
      ..arcToPoint(
        const Offset(18.5, 11.5),
        radius: const Radius.circular(6.5),
        clockwise: false,
      );
    canvas.drawPath(arc, paint);
    canvas.drawLine(const Offset(12, 18), const Offset(12, 21), paint);
    canvas.drawLine(const Offset(8.5, 21), const Offset(15.5, 21), paint);
  }

  /// 辅助：正面消防机器人（头盔穹顶 + 侧护耳 + 面罩圆头 + 肩部）
  void _paintAssist(Canvas canvas, Paint paint) {
    final dome = Path()
      ..moveTo(4.5, 12)
      ..arcToPoint(
        const Offset(19.5, 12),
        radius: const Radius.circular(7.5),
        clockwise: true,
      );
    canvas.drawPath(dome, paint);
    canvas.drawLine(const Offset(19.5, 12), const Offset(19.5, 15.5), paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(4.5, 13, 6.5, 17),
        const Radius.circular(0.9),
      ),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(17.5, 13, 19.5, 17),
        const Radius.circular(0.9),
      ),
      paint,
    );
    canvas.drawCircle(const Offset(12, 8.5), 3.3, paint);
    final shoulder = Path()
      ..moveTo(5.5, 19)
      ..cubicTo(6.3, 16, 9.4, 14.5, 12, 14.5)
      ..cubicTo(14.6, 14.5, 17.7, 16, 18.5, 19);
    canvas.drawPath(shoulder, paint);
  }

  /// 设置：三条调节滑杆，旋钮白芯 + 描边
  void _paintSettings(Canvas canvas, Paint paint) {
    canvas.drawLine(const Offset(4, 7), const Offset(20, 7), paint);
    canvas.drawLine(const Offset(4, 12), const Offset(20, 12), paint);
    canvas.drawLine(const Offset(4, 17), const Offset(20, 17), paint);
    canvas.drawCircle(const Offset(9, 7), 1.7, _fillPaint(Colors.white));
    canvas.drawCircle(const Offset(9, 7), 1.7, paint);
    canvas.drawCircle(const Offset(15, 12), 1.7, _fillPaint(Colors.white));
    canvas.drawCircle(const Offset(15, 12), 1.7, paint);
    canvas.drawCircle(const Offset(10, 17), 1.7, _fillPaint(Colors.white));
    canvas.drawCircle(const Offset(10, 17), 1.7, paint);
  }

  @override
  bool shouldRepaint(NavIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
