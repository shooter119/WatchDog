import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/camera_page.dart';
import 'package:watchdog/pages/watermark_settings_page.dart';
import 'package:watchdog/services/watermark_settings.dart';
import 'package:watchdog/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('拍摄方向配置', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('旧配置和非法值回退横屏，竖屏可完整持久化', () async {
      SharedPreferences.setMockInitialValues({
        'watermark_settings_v1': jsonEncode({'unitTitle': '旧设置'}),
      });
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.landscape,
      );

      SharedPreferences.setMockInitialValues({
        'watermark_settings_v1': jsonEncode({'captureOrientation': 'sideways'}),
      });
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.landscape,
      );

      await WatermarkSettings.save(
        WatermarkSettings.defaults.copyWith(
          captureOrientation: CameraCaptureOrientation.portrait,
        ),
      );
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.portrait,
      );
    });
  });

  group('水印设置页拍摄方向', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({'unit_name': '测试单位'});
    });

    testWidgets('默认横屏，切换竖屏后自动保存', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: WatermarkSettingsPage()));
      await tester.pumpAndSettle();

      RadioGroup<CameraCaptureOrientation> group() =>
          tester.widget<RadioGroup<CameraCaptureOrientation>>(
            find.byType(RadioGroup<CameraCaptureOrientation>),
          );

      expect(group().groupValue, CameraCaptureOrientation.landscape);
      expect(find.text('横屏拍摄（16:9）'), findsOneWidget);
      expect(find.text('竖屏拍摄（16:9中心裁切）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture-orientation-portrait')));
      await tester.pump();
      expect(group().groupValue, CameraCaptureOrientation.portrait);
      await tester.pumpAndSettle();
      expect(find.text('保存'), findsNothing);
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.portrait,
      );
      await tester.pump(const Duration(seconds: 5));
    });

    for (final scale in [1.3, 2.0]) {
      testWidgets('320dp 字号 $scale 下方向选项无溢出', (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const WatermarkSettingsPage(),
          ),
        );
        await tester.pumpAndSettle();

        for (final key in const [
          Key('capture-orientation-landscape'),
          Key('capture-orientation-portrait'),
        ]) {
          await tester.scrollUntilVisible(
            find.byKey(key),
            180,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            tester.getSize(find.byKey(key)).height,
            greaterThanOrEqualTo(48),
          );
        }
        await tester.drag(find.byType(ListView), const Offset(0, -1600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('相机页拍摄方向', () {
    late List<MethodCall> platformCalls;
    late List<Map<Object?, Object?>> platformViewCreations;

    setUp(() {
      platformCalls = [];
      platformViewCreations = [];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('watchdog/camera'),
        (call) async {
          if (call.method == 'requestPermissions') {
            return {
              'camera': true,
              'microphone': true,
              'location': true,
              'preciseLocation': true,
            };
          }
          if (call.method == 'isRecording') return false;
          return null;
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('watchdog/camera_events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('watchdog/location'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('watchdog/storage'),
        (_) async => 1024 * 1024 * 1024,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'),
        (call) async {
          if (call.method == 'create') {
            final arguments = Map<Object?, Object?>.from(call.arguments as Map);
            final encoded = arguments['params'] as Uint8List;
            final decoded = const StandardMessageCodec().decodeMessage(
              ByteData.sublistView(encoded),
            );
            platformViewCreations.add(
              Map<Object?, Object?>.from(decoded as Map),
            );
            return 1;
          }
          if (call.method == 'resize') {
            return {'width': 800.0, 'height': 600.0};
          }
          return null;
        },
      );
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      for (final channel in [
        SystemChannels.platform,
        const MethodChannel('watchdog/camera'),
        const MethodChannel('watchdog/camera_events'),
        const MethodChannel('watchdog/location'),
        const MethodChannel('watchdog/storage'),
        const MethodChannel('flutter/platform_views'),
      ]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    List<String> preferredOrientations() {
      final call = platformCalls.lastWhere(
        (call) => call.method == 'SystemChrome.setPreferredOrientations',
      );
      return (call.arguments as List<Object?>).cast<String>();
    }

    Future<void> pumpCamera(
      WidgetTester tester,
      CameraCaptureOrientation orientation,
      Size size, {
      double textScale = 1,
      bool linkedIncident = false,
    }) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({
        'watermark_settings_v1': jsonEncode({
          'captureOrientation': orientation.storageValue,
        }),
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AppController();
      if (linkedIncident) {
        controller.currentIncident = const Incident(
          id: 'incident-1',
          number: '2026-001',
          title: '沈家衢江边人员想跳桥',
          status: 'active',
          createdAt: 1,
          lastActivityAt: 1,
        );
      }
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: CameraPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('横屏模式锁定左右横屏并传入原生模式', (tester) async {
      await pumpCamera(
        tester,
        CameraCaptureOrientation.landscape,
        const Size(800, 400),
      );

      expect(preferredOrientations(), [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      expect(find.byKey(const Key('camera-landscape-layout')), findsOneWidget);
      expect(find.byKey(const Key('camera-portrait-layout')), findsNothing);
      expect(platformViewCreations.single['captureOrientation'], 'landscape');

      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('竖屏模式锁定竖直，取景区保持 16:9 并传入原生裁切模式', (tester) async {
      await pumpCamera(
        tester,
        CameraCaptureOrientation.portrait,
        const Size(400, 800),
        linkedIncident: true,
      );

      expect(preferredOrientations(), ['DeviceOrientation.portraitUp']);
      expect(find.byKey(const Key('camera-portrait-layout')), findsOneWidget);
      expect(find.byKey(const Key('camera-landscape-layout')), findsNothing);
      final preview = find.byKey(const Key('camera-portrait-preview'));
      final size = tester.getSize(preview);
      expect(size.width / size.height, closeTo(16 / 9, 0.001));
      final incidentChip = tester.getRect(
        find.byKey(const Key('camera-incident-chip')),
      );
      expect(
        incidentChip.right,
        closeTo(size.width - 12, 1),
        reason: '竖屏警情标签应靠右，避开左下角水印',
      );
      expect(
        tester.getRect(find.byTooltip('现场资料')).right,
        closeTo(size.width - 16, 1),
        reason: '没有权限提示时，现场资料入口应保持右上角位置',
      );
      final controls = tester.getRect(find.byKey(const Key('camera-controls')));
      final layout = tester.getRect(
        find.byKey(const Key('camera-portrait-layout')),
      );
      final controlsAreaCenter =
          (preview.evaluate().isNotEmpty
              ? tester.getBottomLeft(preview).dy + layout.bottom
              : layout.center.dy) /
          2;
      expect(
        (controls.center.dy - controlsAreaCenter).abs(),
        lessThan(16),
        reason: '竖屏控制组应在留白区内垂直居中，而不是堆在取景区下方',
      );
      expect(platformViewCreations.single['captureOrientation'], 'portrait');

      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(preferredOrientations(), isEmpty);
    });

    for (final scale in [1.5, 2.0]) {
      testWidgets('竖屏模式字号 $scale 下取景区和控制区无溢出', (tester) async {
        await pumpCamera(
          tester,
          CameraCaptureOrientation.portrait,
          const Size(400, 800),
          textScale: scale,
        );

        expect(find.byKey(const Key('camera-portrait-layout')), findsOneWidget);
        final preview = find.byKey(const Key('camera-portrait-preview'));
        final size = tester.getSize(preview);
        expect(size.width / size.height, closeTo(16 / 9, 0.001));
        expect(tester.takeException(), isNull);

        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  });
}
