import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/video_resources.dart';
import 'package:watchdog/pages/video_playback_surface.dart';
import 'package:watchdog/services/system_pip.dart';
import 'package:watchdog/services/video_playback_session.dart';
import 'package:watchdog/widgets/pip_shell.dart';

const _testResource = VideoResource(
  id: 'pip-camera-1',
  name: '画中画测试监控',
  streamUrl: 'https://video.example.test/pip.flv',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('watchdog/pip');

  setUp(() {
    SystemPip.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SystemPip.resetForTesting();
  });

  test('非 Android 平台 initialize() 不抛异常且各方法返回 false', () async {
    SystemPip.debugBypassPlatformCheck = false;
    await SystemPip.initialize();
    expect(SystemPip.supported, isFalse);
    expect(await SystemPip.setAutoEnter(enabled: true), isFalse);
    expect(await SystemPip.enter(), isFalse);
    expect(await SystemPip.exit(), isFalse);
  });

  test('setAutoEnter 发出正确的通道参数，enter 与 exit 按契约调用', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'isSupported':
              return true;
            case 'setAutoEnter':
            case 'enter':
            case 'exit':
              return true;
          }
          return null;
        });

    SystemPip.debugBypassPlatformCheck = true;
    await SystemPip.initialize();
    expect(SystemPip.supported, isTrue);

    final enableResult = await SystemPip.setAutoEnter(enabled: true);
    expect(enableResult, isTrue);
    expect(calls.last.method, 'setAutoEnter');
    expect(calls.last.arguments, {
      'enabled': true,
      'aspectW': 16,
      'aspectH': 9,
    });

    final disableResult = await SystemPip.setAutoEnter(enabled: false);
    expect(disableResult, isTrue);
    expect(calls.last.method, 'setAutoEnter');
    expect(calls.last.arguments, {
      'enabled': false,
      'aspectW': 16,
      'aspectH': 9,
    });

    final enterResult = await SystemPip.enter();
    expect(enterResult, isTrue);
    expect(calls.last.method, 'enter');
    expect(calls.last.arguments, {'aspectW': 16, 'aspectH': 9});

    final exitResult = await SystemPip.exit();
    expect(exitResult, isTrue);
    expect(calls.last.method, 'exit');
  });

  test('原生回调 pipChanged 更新 SystemPip.isActive', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isSupported') return true;
          return true;
        });

    SystemPip.debugBypassPlatformCheck = true;
    await SystemPip.initialize();
    expect(SystemPip.isActive.value, isFalse);

    final codec = const StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'watchdog/pip',
          codec.encodeMethodCall(
            const MethodCall('pipChanged', {'active': true}),
          ),
          (_) {},
        );
    expect(SystemPip.isActive.value, isTrue);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'watchdog/pip',
          codec.encodeMethodCall(
            const MethodCall('pipChanged', {'active': false}),
          ),
          (_) {},
        );
    expect(SystemPip.isActive.value, isFalse);
  });

  test('isSupported=false 时 setAutoEnter 返回 false 且不产生通道调用', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'isSupported') return false;
          return true;
        });

    SystemPip.debugBypassPlatformCheck = true;
    await SystemPip.initialize();
    expect(SystemPip.supported, isFalse);
    calls.clear();

    final result = await SystemPip.setAutoEnter(enabled: true);
    expect(result, isFalse);
    expect(calls, isEmpty);
  });

  testWidgets('PipShell 仅渲染 16:9 视频区域，不包含底部导航文案', (tester) async {
    final session = VideoPlaybackSession.forTesting(resource: _testResource);
    addTearDown(session.dispose);

    await tester.pumpWidget(PipShell(session: session));
    await tester.pump();

    expect(find.byType(VideoPlaybackSurface), findsOneWidget);
    expect(find.byType(AspectRatio), findsOneWidget);
    expect(find.text('看板'), findsNothing);
    expect(find.text('设置'), findsNothing);
    expect(find.text('日志'), findsNothing);
    expect(find.text('辅助'), findsNothing);
  });
}
