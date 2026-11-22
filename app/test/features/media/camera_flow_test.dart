import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/media/state/camera_session_store.dart';
import 'package:watchdog/features/media/state/media_gateway.dart';
import 'package:watchdog/features/media/ui/camera_page.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/services/watermark_settings.dart';

void _cameraTestWidgets(String name, WidgetTesterCallback callback) {
  testWidgets(name, (tester) async {
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const camera = MethodChannel('watchdog/camera');
  const media = MethodChannel('watchdog/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> calls;
  late List<MethodCall> mediaCalls;
  late List<MethodCall> platformCalls;
  late List<Map<Object?, Object?>> platformViewCreations;
  late bool permission;
  late int bytes;
  bool locationPermission = false;
  Object? location;
  late List<Map<Object?, Object?>> watermarks;
  int locationRequests = 0;
  Completer<String?>? photo;
  bool nativeRecording = false;
  bool reconcileFails = false;
  String? renderedMediaPath;

  Future<void> emitEvent(
    WidgetTester tester,
    String type, {
    String? path,
    int? durationMs,
  }) async {
    await messenger.handlePlatformMessage(
      'watchdog/camera_events',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': type,
        if (path != null) 'path': path,
        if (durationMs != null) 'durationMs': durationMs,
      }),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
  }

  MediaGateway createGateway({MediaIncidentRef? incident}) =>
      MediaGateway(readCurrentIncident: () => incident);

  Future<void> pumpCamera(
    WidgetTester tester, {
    double scale = 1,
    MediaIncidentRef? incident,
    Brightness brightness = Brightness.light,
    Future<void> Function(BuildContext context)? onOpenWatermarkSettings,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: CameraPage(
          gateway: createGateway(incident: incident),
          onOpenWatermarkSettings: onOpenWatermarkSettings,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpPushedCamera(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CameraPage(gateway: createGateway()),
                  ),
                ),
                child: const Text('打开相机'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开相机'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    calls = [];
    mediaCalls = [];
    platformCalls = [];
    platformViewCreations = [];
    permission = true;
    bytes = 1024 * 1024 * 1024;
    photo = null;
    locationPermission = false;
    location = null;
    locationRequests = 0;
    watermarks = [];
    nativeRecording = false;
    reconcileFails = false;
    renderedMediaPath = null;
    SharedPreferences.setMockInitialValues({});

    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(camera, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'requestPermissions':
          return {
            'camera': permission,
            'microphone': true,
            'location': locationPermission,
            'preciseLocation': locationPermission,
          };
        case 'updateWatermark':
          watermarks.add(Map<Object?, Object?>.from(call.arguments as Map));
          return null;
        case 'takePhoto':
          return photo?.future;
        case 'isRecording':
          if (reconcileFails) throw PlatformException(code: 'disconnected');
          return nativeRecording;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(media, (call) async {
      mediaCalls.add(call);
      if (call.method == 'renderWatermarkedCopy') return renderedMediaPath;
      return null;
    });
    for (final name in [
      'watchdog/camera_events',
      'watchdog/screen',
      'flutter/platform_views',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name == 'watchdog/screen' && call.method == 'openAppSettings') {
          calls.add('screen/openAppSettings');
        }
        if (name == 'flutter/platform_views') {
          if (call.method == 'create') {
            final arguments = Map<Object?, Object?>.from(call.arguments as Map);
            final encoded = arguments['params'] as Uint8List?;
            if (encoded != null) {
              final decoded = const StandardMessageCodec().decodeMessage(
                ByteData.sublistView(encoded),
              );
              platformViewCreations.add(
                Map<Object?, Object?>.from(decoded as Map),
              );
            }
            return 1;
          }
          if (call.method == 'resize') return {'width': 800.0, 'height': 600.0};
        }
        return null;
      });
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('watchdog/location'),
      (_) async {
        locationRequests++;
        return location;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('watchdog/storage'),
      (_) async => bytes,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    for (final name in [
      'watchdog/camera',
      'watchdog/media',
      'watchdog/camera_events',
      'watchdog/screen',
      'watchdog/storage',
      'watchdog/location',
      'flutter/platform_views',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  test('定位时效包含原生年龄和页面停留时间', () {
    final now = DateTime(2026, 10, 18);
    const fix = LocationFix(
      lat: 30,
      lon: 120,
      accuracyMeters: 5,
      provider: 'gps',
      ageMs: 60000,
    );
    expect(
      CameraFlowPolicy.locationExpired(
        fix,
        now,
        now.add(const Duration(minutes: 4)),
      ),
      isFalse,
    );
    expect(
      CameraFlowPolicy.locationExpired(
        fix,
        now,
        now.add(const Duration(minutes: 4, milliseconds: 1)),
      ),
      isTrue,
    );
    expect(CameraFlowPolicy.locationExpired(null, now, now), isTrue);
    expect(CameraFlowPolicy.minimumBytes(false), 20 * 1024 * 1024);
    expect(CameraFlowPolicy.minimumBytes(true), 200 * 1024 * 1024);
  });

  test('计时按真实时间差计算，跳过多个 tick 不丢秒', () {
    final start = DateTime(2026, 10, 18);
    expect(
      CameraFlowPolicy.elapsed(
        start,
        start.add(const Duration(seconds: 53, milliseconds: 420)),
      ),
      const Duration(seconds: 53, milliseconds: 420),
    );
  });

  _cameraTestWidgets('非 Android 平台显示不支持提示', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: CameraPage(gateway: createGateway()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前平台暂不支持水印相机'), findsOneWidget);
  });

  _cameraTestWidgets('拍照中禁用镜头手电筒模式并拦截重复拍摄', (tester) async {
    photo = Completer<String?>();
    await pumpCamera(tester);
    await tester.tap(find.text('点击拍照'));
    await tester.pump();
    expect(calls.where((e) => e == 'takePhoto'), hasLength(1));
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, DsIcons.cameraSwitch),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, DsIcons.flashOff))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('录像'));
    await tester.tap(find.text('点击拍照'));
    await tester.pump();
    expect(find.text('点击开始录像'), findsNothing);
    expect(calls.where((e) => e == 'takePhoto'), hasLength(1));
    photo!.complete(null);
    await tester.pumpAndSettle();
  });

  _cameraTestWidgets('照片水印生成失败保留母版并可原路径重试', (tester) async {
    photo = Completer<String?>()..complete('/tmp/watchdog-src.jpg');
    await pumpCamera(tester);

    await tester.tap(find.text('点击拍照'));
    await tester.pumpAndSettle();

    final first = mediaCalls.singleWhere(
      (call) => call.method == 'renderWatermarkedCopy',
    );
    expect((first.arguments as Map)['path'], '/tmp/watchdog-src.jpg');
    expect(find.textContaining('水印照片生成失败'), findsOneWidget);

    await tester.tap(find.text('重新生成水印版'));
    await tester.pumpAndSettle();

    final renders = mediaCalls
        .where((call) => call.method == 'renderWatermarkedCopy')
        .toList(growable: false);
    expect(renders, hasLength(2));
    for (final call in renders) {
      expect((call.arguments as Map)['path'], '/tmp/watchdog-src.jpg');
    }
  });

  _cameraTestWidgets('视频水印生成失败保留母版并可原路径重试', (tester) async {
    await pumpCamera(tester);
    await tester.tap(find.text('录像'));
    await tester.pumpAndSettle();
    await emitEvent(tester, 'started');
    await emitEvent(
      tester,
      'stopped',
      path: '/tmp/watchdog-src.mp4',
      durationMs: 1200,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('水印视频生成失败'), findsOneWidget);
    await tester.tap(find.text('重新生成水印版'));
    await tester.pumpAndSettle();

    final renders = mediaCalls
        .where((call) => call.method == 'renderWatermarkedCopy')
        .toList(growable: false);
    expect(renders, hasLength(2));
    for (final call in renders) {
      expect((call.arguments as Map)['path'], '/tmp/watchdog-src.mp4');
    }
  });

  _cameraTestWidgets('拍摄前重取过期定位，失败不写旧坐标', (tester) async {
    locationPermission = true;
    location = {'lat': 30.0, 'lon': 120.0, 'ageMs': 400000};
    await pumpCamera(tester);
    expect(locationRequests, 1);
    expect(watermarks.last['latitude'], isNull);
    location = null;
    photo = Completer<String?>();
    await tester.tap(find.text('点击拍照'));
    await tester.pumpAndSettle();
    expect(locationRequests, 2);
    expect(watermarks.last['latitude'], isNull);
    expect(watermarks.last['longitude'], isNull);
    expect(watermarks.last['address'], '');
    expect(find.text('定位不可用，水印不含地点与坐标'), findsOneWidget);
    photo!.complete(null);
    await tester.pumpAndSettle();
  });

  _cameraTestWidgets('空间不足同时阻止拍照与录像', (tester) async {
    bytes = 1;
    await pumpCamera(tester);
    await tester.tap(find.text('点击拍照'));
    await tester.pumpAndSettle();
    expect(find.textContaining('存储空间不足'), findsOneWidget);
    expect(calls, isNot(contains('takePhoto')));
    await tester.tap(find.text('录像'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击开始录像'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('startRecording')));
    expect(find.textContaining('200 MB'), findsOneWidget);
  });

  _cameraTestWidgets('点关闭按钮回到上级页面', (tester) async {
    await pumpPushedCamera(tester);
    expect(find.byType(CameraPage), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.byType(CameraPage), findsNothing);
    expect(find.text('打开相机'), findsOneWidget);
  });

  _cameraTestWidgets('系统返回键同样回到上级页面', (tester) async {
    await pumpPushedCamera(tester);
    expect(find.byType(CameraPage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(CameraPage), findsNothing);
    expect(find.text('打开相机'), findsOneWidget);
  });

  _cameraTestWidgets('权限引导有可调用的系统设置入口、用途说明与重新授权兜底', (tester) async {
    permission = false;
    await pumpCamera(tester, scale: 2);
    expect(find.text('需要相机权限才能拍摄现场资料'), findsOneWidget);
    expect(find.text('拍摄内容只保存在本机，不会自动上传'), findsOneWidget);
    expect(find.textContaining('麦克风用于'), findsOneWidget);

    await tester.ensureVisible(find.text('去系统设置'));
    await tester.tap(find.text('去系统设置'));
    await tester.pumpAndSettle();
    expect(calls, contains('screen/openAppSettings'));
    expect(calls, isNot(contains('openAppSettings')));
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '去系统设置'),
    );
    expect(button.style!.foregroundColor!.resolve({}), Colors.white);
    expect(
      tester.getSize(find.widgetWithText(TextButton, '去系统设置')).height,
      greaterThanOrEqualTo(48),
    );

    await tester.ensureVisible(find.text('重新授权'));
    await tester.tap(find.text('重新授权'));
    await tester.pumpAndSettle();
    expect(calls.where((e) => e == 'screen/openAppSettings'), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.3, 1.5, 2.0]) {
    _cameraTestWidgets('横屏控件在 $scale 倍字号无溢出', (tester) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpCamera(tester, scale: scale);
      expect(tester.takeException(), isNull);
    });
  }

  _cameraTestWidgets('竖屏 360×800 @ 130% 字号零溢出且取景区保持 16:9', (tester) async {
    SharedPreferences.setMockInitialValues({
      'watermark_settings_v1': jsonEncode({
        'captureOrientation': CameraCaptureOrientation.portrait.storageValue,
      }),
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpCamera(
      tester,
      scale: 1.3,
      incident: const MediaIncidentRef(id: 'incident-1', title: '示例路火情处置'),
    );

    expect(find.byKey(const Key('camera-portrait-layout')), findsOneWidget);
    final previewRect = tester.getRect(
      find.byKey(const Key('camera-portrait-preview')),
    );
    expect(previewRect.width / previewRect.height, closeTo(16 / 9, 0.001));
    expect(platformViewCreations.single['captureOrientation'], 'portrait');
    final controlsRect = tester.getRect(
      find.byKey(const Key('camera-portrait-controls-area')),
    );
    expect(controlsRect.height, closeTo(280, 1));
    expect(tester.takeException(), isNull);
  });

  _cameraTestWidgets('注入水印设置回调后返回自动刷新水印配置', (tester) async {
    var opened = 0;
    await pumpCamera(
      tester,
      onOpenWatermarkSettings: (_) async {
        opened++;
        await WatermarkSettings.save(
          WatermarkSettings.defaults.copyWith(unitTitle: '示例市消防救援支队'),
        );
      },
    );
    final beforeCount = watermarks.length;
    await tester.tap(find.byTooltip('水印设置'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(watermarks.length, greaterThan(beforeCount));
    expect(watermarks.last['unitTitle'], '示例市消防救援支队');
  });

  _cameraTestWidgets('错误事件保留原生仍录制状态，失败时提供重试', (tester) async {
    await pumpCamera(tester);
    await tester.tap(find.text('录像'));
    await tester.pumpAndSettle();
    nativeRecording = true;
    await emitEvent(tester, 'started');
    await emitEvent(tester, 'error');
    expect(find.text('点击停止'), findsOneWidget);
    expect(find.textContaining('仍在录像'), findsOneWidget);
    reconcileFails = true;
    await emitEvent(tester, 'error');
    expect(find.text('重试确认'), findsOneWidget);
    reconcileFails = false;
    nativeRecording = false;
    await tester.tap(find.text('重试确认'));
    await tester.pumpAndSettle();
    expect(find.text('点击开始录像'), findsOneWidget);
  });

  _cameraTestWidgets('inactive 不停录，paused 才请求停录', (tester) async {
    await pumpCamera(tester);
    await tester.tap(find.text('录像'));
    await tester.pumpAndSettle();
    await emitEvent(tester, 'started');
    tester
        .state<CameraPageState>(find.byType(CameraPage))
        .didChangeAppLifecycleState(AppLifecycleState.inactive);
    await tester.pump();
    expect(calls, isNot(contains('stopRecording')));
    tester
        .state<CameraPageState>(find.byType(CameraPage))
        .didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(calls, contains('stopRecording'));
    await emitEvent(tester, 'stopped');
    expect(find.text('视频已保存，正在生成水印版'), findsOneWidget);
    tester
        .state<CameraPageState>(find.byType(CameraPage))
        .didChangeAppLifecycleState(AppLifecycleState.resumed);
  });
}
