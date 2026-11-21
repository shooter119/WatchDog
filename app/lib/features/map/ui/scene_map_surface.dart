import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design_system/design_system.dart';

/// 现场地图交互桥接控制器（方便测试观察脚本注入与图层/视角指令下发）。
class SceneMapSurfaceController {
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

/// 现场地图 Android 原生 PlatformView 桥接组件（严格保留 `watchdog/amap_view` 协议）。
class SceneMapSurface extends StatefulWidget {
  final SceneMapSurfaceController surfaceController;
  final int backgroundColor;
  final VoidCallback onReady;
  final void Function(String type, Map<String, dynamic> data) onBridgeEvent;

  const SceneMapSurface({
    super.key,
    required this.surfaceController,
    required this.backgroundColor,
    required this.onReady,
    required this.onBridgeEvent,
  });

  @override
  State<SceneMapSurface> createState() => _SceneMapSurfaceState();
}

class _SceneMapSurfaceState extends State<SceneMapSurface> {
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
