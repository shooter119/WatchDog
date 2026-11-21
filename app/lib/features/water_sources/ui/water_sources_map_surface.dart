import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design_system/design_system.dart';
import '../data/models/water_source.dart';

/// 周边水源地图交互桥接控制器（支持真实 WebView 与测试注入）。
class WaterSourcesMapSurfaceController {
  String? lastLoadedHtml;
  String? lastBaseUrl;
  final List<String> evaluatedScripts = [];
  Future<void> Function(String baseUrl, String html)? _onLoadHtml;
  Future<void> Function(String script)? _onEvalJs;

  void attach({
    required Future<void> Function(String baseUrl, String html) onLoadHtml,
    required Future<void> Function(String script) onEvalJs,
  }) {
    _onLoadHtml = onLoadHtml;
    _onEvalJs = onEvalJs;
  }

  void detach() {
    _onLoadHtml = null;
    _onEvalJs = null;
  }

  Future<void> loadHtml(String baseUrl, String html) async {
    lastBaseUrl = baseUrl;
    lastLoadedHtml = html;
    final fn = _onLoadHtml;
    if (fn != null) {
      await fn(baseUrl, html);
    }
  }

  Future<void> evalJs(String script) async {
    evaluatedScripts.add(script);
    final fn = _onEvalJs;
    if (fn != null) {
      await fn(script);
    }
  }
}

/// 传给可选 `mapBuilder` 的只读地图状态快照与回调。
class WaterSourcesMapState {
  final WaterSourcesMapSurfaceController surfaceController;
  final List<WaterSource> items;
  final WaterSource? selected;
  final ({double lat, double lng, double accuracy})? myGcj;
  final bool pickingMode;
  final ({double lat, double lng})? pickCenter;
  final void Function(String eventType, Map<String, dynamic> data)
  onBridgeEvent;
  final void Function(String id) onSelectMarker;
  final void Function(double lat, double lng) onPickCenterChanged;

  const WaterSourcesMapState({
    required this.surfaceController,
    required this.items,
    required this.selected,
    required this.myGcj,
    required this.pickingMode,
    required this.pickCenter,
    required this.onBridgeEvent,
    required this.onSelectMarker,
    required this.onPickCenterChanged,
  });
}

/// 可选自定义地图视图构建器，便于单测在无真实 WebView 环境下注入占位组件。
typedef WaterSourcesMapBuilder =
    Widget Function(BuildContext context, WaterSourcesMapState mapState);

/// 周边水源 Android 原生高德地图 PlatformView 桥接组件（严格保留 `watchdog/amap_view` 协议）。
class WaterSourcesMapSurface extends StatefulWidget {
  final WaterSourcesMapSurfaceController surfaceController;
  final int backgroundColor;
  final VoidCallback onReady;
  final void Function(String type, Map<String, dynamic> data) onBridgeEvent;

  const WaterSourcesMapSurface({
    super.key,
    required this.surfaceController,
    required this.backgroundColor,
    required this.onReady,
    required this.onBridgeEvent,
  });

  @override
  State<WaterSourcesMapSurface> createState() => _WaterSourcesMapSurfaceState();
}

class _WaterSourcesMapSurfaceState extends State<WaterSourcesMapSurface> {
  MethodChannel? _channel;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    widget.surfaceController.detach();
    super.dispose();
  }

  void _onPlatformViewCreated(int viewId) {
    final channel = MethodChannel('watchdog/amap_view_$viewId');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onBridgeMessage') {
        final raw = call.arguments as String? ?? '';
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map) {
            final type = parsed['type']?.toString() ?? '';
            final data = parsed['data'] is Map
                ? Map<String, dynamic>.from(parsed['data'] as Map)
                : const <String, dynamic>{};
            widget.onBridgeEvent(type, data);
          }
        } catch (_) {}
      }
      return null;
    });

    widget.surfaceController.attach(
      onLoadHtml: (baseUrl, html) => channel.invokeMethod<void>('loadHtml', {
        'baseUrl': baseUrl,
        'html': html,
      }),
      onEvalJs: (script) =>
          channel.invokeMethod<void>('evalJs', {'script': script}),
    );
    widget.onReady();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return Center(
        child: Text(
          '当前平台暂不支持内置地图视图',
          style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
        ),
      );
    }
    return AndroidView(
      viewType: 'watchdog/amap_view',
      creationParams: {'backgroundColor': widget.backgroundColor},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}

/// 地图中心选点十字准星。
class WaterCrosshairReticle extends StatelessWidget {
  const WaterCrosshairReticle({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: CustomPaint(painter: _CrosshairPainter()),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    final strokePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()
      ..color = const Color(0xFFDC2626)
      ..style = PaintingStyle.fill;

    for (final paint in [shadowPaint, strokePaint]) {
      canvas.drawCircle(center, 14, paint);
      canvas.drawLine(
        Offset(center.dx - 20, center.dy),
        Offset(center.dx - 7, center.dy),
        paint,
      );
      canvas.drawLine(
        Offset(center.dx + 7, center.dy),
        Offset(center.dx + 20, center.dy),
        paint,
      );
      canvas.drawLine(
        Offset(center.dx, center.dy - 20),
        Offset(center.dx, center.dy - 7),
        paint,
      );
      canvas.drawLine(
        Offset(center.dx, center.dy + 7),
        Offset(center.dx, center.dy + 20),
        paint,
      );
    }
    canvas.drawCircle(center, 3.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
