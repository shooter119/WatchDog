import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/video/data/models/video_resource.dart';
import 'package:watchdog/features/video/ui/pip_shell.dart';
import 'package:watchdog/features/video/ui/video_playback_surface.dart';
import 'package:watchdog/services/system_pip.dart';
import 'package:watchdog/services/video_playback_session.dart';

const _testResource = VideoResource(
  id: 'camera-1',
  name: '合成监控',
  streamUrl: 'https://video.example.test/live.flv',
  description: '用于三态与画中画测试',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pipChannel = MethodChannel('watchdog/pip');

  setUp(() {
    SystemPip.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pipChannel, null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pipChannel, null);
    SystemPip.resetForTesting();
  });

  testWidgets('FloatingVideoOverlay 提供 48dp 全屏与关闭按钮并复用会话', (tester) async {
    final session = VideoPlaybackSession.forTesting(
      resource: _testResource,
      status: VideoPlaybackStatus.playing,
    );
    var fullscreen = 0;
    var closed = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: FloatingVideoOverlay(
              session: session,
              onFullscreen: () => fullscreen++,
              onClose: () => closed++,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('video-floating-window')), findsOneWidget);
    for (final key in const <Key>[
      Key('video-floating-fullscreen'),
      Key('video-floating-close'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    await tester.tap(find.byKey(const Key('video-floating-fullscreen')));
    expect(fullscreen, 1);

    await tester.tap(find.byKey(const Key('video-floating-close')));
    expect(closed, 1);
    expect(session.hasResource, isFalse);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('VideoFullscreenScreen 进入沉浸式并退出恢复边缘模式，关闭按钮停止播放', (tester) async {
    final uiModeCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            uiModeCalls.add('${call.arguments}');
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final session = VideoPlaybackSession.forTesting(
      resource: _testResource,
      status: VideoPlaybackStatus.playing,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: CommandButton(
                label: '打开全屏',
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => VideoFullscreenScreen(session: session),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开全屏'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-fullscreen-surface')), findsOneWidget);
    expect(uiModeCalls.any((arg) => arg.contains('immersiveSticky')), isTrue);

    await tester.tap(find.byKey(const Key('video-fullscreen-close')));
    await tester.pumpAndSettle();

    expect(find.byType(VideoFullscreenScreen), findsNothing);
    expect(session.hasResource, isFalse);
    expect(uiModeCalls.last, contains('edgeToEdge'));

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('全屏自动横屏，返回浮窗或行内后恢复竖屏', (tester) async {
    final orientations = <List<Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientations.add(call.arguments as List<Object?>);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final session = VideoPlaybackSession.forTesting(resource: _testResource);
    session.enterFullscreen();
    await tester.pump();
    expect(
      orientations.last,
      containsAll(<String>[
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]),
    );

    session.enterFloating();
    await tester.pump();
    expect(orientations.last, <String>['DeviceOrientation.portraitUp']);

    session.returnInline();
    await tester.pump();
    expect(orientations.last, <String>['DeviceOrientation.portraitUp']);
    session.dispose();
  });

  testWidgets('360dp 窄屏 16:9 行内播放器在 1.3 倍字体下显示失败态零溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = VideoPlaybackSession.forTesting(
      resource: _testResource,
      status: VideoPlaybackStatus.failed,
      lastError: 'synthetic failure',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Center(
            child: SizedBox(
              width: 304,
              height: 171,
              child: VideoPlaybackSurface(
                key: const Key('constrained-video-failure'),
                session: session,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('视频连接失败'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    session.dispose();
  });

  test('reattachSurface 不改变会话状态，无会话时安全返回', () {
    final session = VideoPlaybackSession.forTesting(
      resource: _testResource,
      status: VideoPlaybackStatus.playing,
    );
    final beforeStatus = session.status;
    final beforePresentation = session.presentation;
    expect(() => session.reattachSurface(), returnsNormally);
    expect(session.status, beforeStatus);
    expect(session.presentation, beforePresentation);
    session.dispose();

    final idle = VideoPlaybackSession.forTesting();
    var notified = 0;
    idle.addListener(() => notified++);
    expect(() => idle.reattachSurface(), returnsNormally);
    expect(notified, 0);
    idle.dispose();
  });

  testWidgets('CommandPipShell 独立渲染 16:9 视频且失败态在无 Navigator 下无报错', (
    tester,
  ) async {
    final session = VideoPlaybackSession.forTesting(
      resource: _testResource,
      status: VideoPlaybackStatus.failed,
      lastError: 'stream dropped',
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(CommandPipShell(session: session));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(VideoPlaybackSurface), findsOneWidget);
    expect(find.byType(AspectRatio), findsOneWidget);
    expect(find.byTooltip('重新连接视频'), findsOneWidget);
    expect(find.text('看板'), findsNothing);
    expect(find.text('设置'), findsNothing);
    expect(find.text('日志'), findsNothing);
    expect(find.text('辅助'), findsNothing);
  });

  test('syncVideoSystemPip 将会话持流状态同步至原生 SystemPip 通道', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pipChannel, (call) async {
          calls.add(call);
          return true;
        });

    SystemPip.debugBypassPlatformCheck = true;
    await SystemPip.initialize();

    final active = VideoPlaybackSession.forTesting(resource: _testResource);
    final idle = VideoPlaybackSession.forTesting();
    addTearDown(() {
      active.dispose();
      idle.dispose();
    });

    expect(await syncVideoSystemPip(active), isTrue);
    expect(calls.last.method, 'setAutoEnter');
    expect(calls.last.arguments, <String, Object>{
      'enabled': true,
      'aspectW': 16,
      'aspectH': 9,
    });

    expect(await syncVideoSystemPip(idle), isTrue);
    expect(calls.last.method, 'setAutoEnter');
    expect(calls.last.arguments, <String, Object>{
      'enabled': false,
      'aspectW': 16,
      'aspectH': 9,
    });
  });
}
