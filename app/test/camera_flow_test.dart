import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/pages/camera_page.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/state/app_controller.dart';

void cameraTestWidgets(String name, WidgetTesterCallback callback) {
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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;
  late bool permission;
  late int bytes;
  bool locationPermission = false;
  Object? location;
  late List<Map<Object?, Object?>> watermarks;
  int locationRequests = 0;
  Completer<String?>? photo;
  bool nativeRecording = false;
  bool reconcileFails = false;

  Future<void> event(WidgetTester tester, String type) async {
    await messenger.handlePlatformMessage(
      'watchdog/camera_events',
      const StandardMethodCodec().encodeSuccessEnvelope({'type': type}),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> page(WidgetTester tester, {double scale = 1}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: CameraPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 从上级页面推入相机页，用于验证关闭按钮确实回到主界面。
  Future<void> pushedPage(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) => CameraPage(controller: controller),
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
    permission = true;
    bytes = 1024 * 1024 * 1024;
    photo = null;
    locationPermission = false;
    location = null;
    locationRequests = 0;
    watermarks = [];
    nativeRecording = false;
    reconcileFails = false;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(camera, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'requestPermissions':
          return {
            'camera': permission,
            'microphone': true,
            'location': locationPermission,
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
    for (final name in [
      'watchdog/camera_events',
      'watchdog/screen',
      'flutter/platform_views',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name == 'flutter/platform_views') {
          if (call.method == 'create') return 1;
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
    for (final name in [
      'watchdog/camera',
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

  cameraTestWidgets('拍照中禁用镜头手电筒模式并拦截重复拍摄', (tester) async {
    photo = Completer<String?>();
    await page(tester);
    await tester.tap(find.text('点击拍照'));
    await tester.pump();
    expect(calls.where((e) => e == 'takePhoto'), hasLength(1));
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.cameraswitch_outlined),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.flash_off))
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

  cameraTestWidgets('拍摄前重取过期定位，失败不写旧坐标', (tester) async {
    locationPermission = true;
    location = {'lat': 30.0, 'lon': 120.0, 'ageMs': 400000};
    await page(tester);
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

  cameraTestWidgets('空间不足同时阻止拍照与录像', (tester) async {
    bytes = 1;
    await page(tester);
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

  cameraTestWidgets('点关闭按钮回到上级页面', (tester) async {
    await pushedPage(tester);
    expect(find.byType(CameraPage), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.byType(CameraPage), findsNothing);
    expect(find.text('打开相机'), findsOneWidget);
  });

  cameraTestWidgets('系统返回键同样回到上级页面', (tester) async {
    await pushedPage(tester);
    expect(find.byType(CameraPage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(CameraPage), findsNothing);
    expect(find.text('打开相机'), findsOneWidget);
  });

  cameraTestWidgets('权限引导有可调用的系统设置入口和用途说明', (tester) async {
    permission = false;
    await page(tester, scale: 2);
    expect(find.textContaining('麦克风用于'), findsOneWidget);
    await tester.ensureVisible(find.text('去系统设置'));
    await tester.tap(find.text('去系统设置'));
    await tester.pumpAndSettle();
    expect(calls, contains('openAppSettings'));
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.5, 2.0]) {
    cameraTestWidgets('横屏控件在 $scale 倍字号无溢出', (tester) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await page(tester, scale: scale);
      expect(tester.takeException(), isNull);
    });
  }

  cameraTestWidgets('错误事件保留原生仍录制状态，失败时提供重试', (tester) async {
    await page(tester);
    await tester.tap(find.text('录像'));
    await tester.pumpAndSettle();
    nativeRecording = true;
    await event(tester, 'started');
    await event(tester, 'error');
    expect(find.text('点击停止'), findsOneWidget);
    expect(find.textContaining('仍在录像'), findsOneWidget);
    reconcileFails = true;
    await event(tester, 'error');
    expect(find.text('重试确认'), findsOneWidget);
    reconcileFails = false;
    nativeRecording = false;
    await tester.tap(find.text('重试确认'));
    await tester.pumpAndSettle();
    expect(find.text('点击开始录像'), findsOneWidget);
  });

  cameraTestWidgets('inactive 不停录，paused 才请求停录', (tester) async {
    await page(tester);
    await tester.tap(find.text('录像'));
    await tester.pumpAndSettle();
    await event(tester, 'started');
    (tester.state(find.byType(CameraPage)) as dynamic)
        .didChangeAppLifecycleState(AppLifecycleState.inactive);
    await tester.pump();
    expect(calls, isNot(contains('stopRecording')));
    (tester.state(find.byType(CameraPage)) as dynamic)
        .didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(calls, contains('stopRecording'));
    await event(tester, 'stopped');
    expect(find.text('视频已保存，可到现场资料查看'), findsOneWidget);
    (tester.state(find.byType(CameraPage)) as dynamic)
        .didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
