import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/video/data/models/video_resource.dart';
import 'package:watchdog/features/video/data/video_repository.dart';
import 'package:watchdog/features/video/state/video_resources_store.dart';
import 'package:watchdog/features/video/ui/video_playback_surface.dart';
import 'package:watchdog/features/video/ui/video_resource_card.dart';
import 'package:watchdog/features/video/ui/video_resources_page.dart';
import 'package:watchdog/services/video_playback_session.dart';

const _resource = VideoResource(
  id: 'camera-1',
  name: '合成监控',
  streamUrl: 'https://video.example.test/live.flv',
  description: '用于自动化测试',
  version: 3,
);

const _invalidUrlResource = VideoResource(
  id: 'camera-http',
  name: '非安全监控',
  streamUrl: 'http://video.example.test/insecure.flv',
  description: '非 HTTPS 测试项',
);

class _FakeVideoRepository implements VideoRepository {
  _FakeVideoRepository({
    this.resources = const <VideoResource>[_resource],
    this.canManage = false,
    this.fetchError,
  });

  List<VideoResource> resources;
  bool canManage;
  Object? fetchError;
  int fetchCount = 0;

  @override
  Future<Map<String, dynamic>> videoResourceAccess() async => <String, dynamic>{
    'can_manage': canManage,
  };

  @override
  Future<List<VideoResource>> fetchVideoResources({
    bool includeInactive = false,
  }) async {
    fetchCount++;
    if (fetchError != null) throw fetchError!;
    return resources
        .where((item) => includeInactive || item.active)
        .toList(growable: false);
  }

  @override
  Future<VideoResource> addVideoResource({
    required String name,
    required String streamUrl,
    String description = '',
    bool active = true,
  }) => throw UnimplementedError();

  @override
  Future<VideoResource> updateVideoResource(
    String id, {
    required int expectedVersion,
    String? name,
    String? streamUrl,
    String? description,
    bool? active,
  }) => throw UnimplementedError();
}

class _DisposableProbe extends StatefulWidget {
  const _DisposableProbe({super.key, required this.onDispose});

  final VoidCallback onDispose;

  @override
  State<_DisposableProbe> createState() => _DisposableProbeState();
}

class _DisposableProbeState extends State<_DisposableProbe> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

Widget _wrapDs(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('普通成员不显示管理入口，管理员显示并触发注入的 onOpenAdmin 后刷新', (tester) async {
    final memberStore = VideoResourcesStore(
      repository: _FakeVideoRepository(canManage: false),
      availabilityChecker: (_) async => true,
    );
    await tester.pumpWidget(_wrapDs(VideoResourcesPage(store: memberStore)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-resource-manage')), findsNothing);
    expect(find.text('合成监控'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    memberStore.dispose();

    final adminRepo = _FakeVideoRepository(canManage: true);
    final adminStore = VideoResourcesStore(
      repository: adminRepo,
      availabilityChecker: (_) async => true,
    );
    var adminOpened = 0;
    await tester.pumpWidget(
      _wrapDs(
        VideoResourcesPage(
          store: adminStore,
          onOpenAdmin: (_) async {
            adminOpened++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-resource-manage')), findsOneWidget);
    final beforeFetch = adminRepo.fetchCount;
    await tester.tap(find.byKey(const Key('video-resource-manage')));
    await tester.pumpAndSettle();

    expect(adminOpened, 1);
    expect(adminRepo.fetchCount, greaterThan(beforeFetch));

    await tester.pumpWidget(const SizedBox());
    adminStore.dispose();
  });

  testWidgets('可达性探测通过双通道 StatusPill 展示检测中 / 绿在线 / 红离线', (tester) async {
    final probe = Completer<bool>();
    final pendingStore = VideoResourcesStore(
      repository: _FakeVideoRepository(),
      availabilityChecker: (_) => probe.future,
    );
    await tester.pumpWidget(_wrapDs(VideoResourcesPage(store: pendingStore)));
    await tester.pumpAndSettle();

    var pill = tester.widget<StatusPill>(
      find.byKey(const ValueKey<String>('video-resource-status-camera-1')),
    );
    expect(pill.status, DsStatus.neutral);
    expect(find.text('检测中'), findsOneWidget);

    probe.complete(true);
    await tester.pumpAndSettle();

    pill = tester.widget<StatusPill>(
      find.byKey(const ValueKey<String>('video-resource-status-camera-1')),
    );
    expect(pill.status, DsStatus.safe);
    expect(find.text('在线'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    pendingStore.dispose();

    final offlineStore = VideoResourcesStore(
      repository: _FakeVideoRepository(),
      availabilityChecker: (_) async => false,
    );
    await tester.pumpWidget(_wrapDs(VideoResourcesPage(store: offlineStore)));
    await tester.pumpAndSettle();

    pill = tester.widget<StatusPill>(
      find.byKey(const ValueKey<String>('video-resource-status-camera-1')),
    );
    expect(pill.status, DsStatus.alarm);
    expect(find.text('离线·不可播放'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    offlineStore.dispose();
  });

  testWidgets('点击资源行内展开播放器，关闭后立即收起并销毁播放器', (tester) async {
    final store = VideoResourcesStore(
      repository: _FakeVideoRepository(),
      availabilityChecker: (_) async => true,
    );
    var playerDisposed = false;
    await tester.pumpWidget(
      _wrapDs(
        VideoResourcesPage(
          store: store,
          expandedPlayerBuilder: (_) => _DisposableProbe(
            key: const Key('inline-video-player'),
            onDispose: () => playerDisposed = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('合成监控'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inline-video-player')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-resource-expanded-camera-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-resource-close-camera-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-close-camera-1')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inline-video-player')), findsNothing);
    expect(playerDisposed, isTrue);

    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  testWidgets('非 HTTPS 视频地址点击时提示错误且不展开播放器', (tester) async {
    final store = VideoResourcesStore(
      repository: _FakeVideoRepository(
        resources: const <VideoResource>[_invalidUrlResource],
      ),
      availabilityChecker: (_) async => false,
    );
    await tester.pumpWidget(
      _wrapDs(
        VideoResourcesPage(
          store: store,
          expandedPlayerBuilder: (_) => const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('非安全监控'));
    await tester.pumpAndSettle();

    expect(find.text('视频地址无效，请联系管理员更新'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-resource-expanded-camera-http')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  testWidgets('展开后的播放器提供全屏、浮窗和关闭三个独立 48dp 操作', (tester) async {
    var fullscreen = 0;
    var floating = 0;
    var closed = 0;
    await tester.pumpWidget(
      _wrapDs(
        Scaffold(
          body: VideoResourceCard(
            resource: _resource,
            available: true,
            expandedPlayer: const ColoredBox(color: Colors.black),
            onTap: () {},
            onClose: () => closed++,
            onFullscreen: () => fullscreen++,
            onFloating: () => floating++,
          ),
        ),
      ),
    );

    for (final key in const <Key>[
      ValueKey<String>('video-resource-fullscreen-camera-1'),
      ValueKey<String>('video-resource-floating-camera-1'),
      ValueKey<String>('video-resource-close-camera-1'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-fullscreen-camera-1')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-floating-camera-1')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-close-camera-1')),
    );

    expect(fullscreen, 1);
    expect(floating, 1);
    expect(closed, 1);
  });

  testWidgets('切到浮窗时提示画中画会持续耗电，且通过 pip_hint_shown_v1 只提示一次', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const hint = VideoResourcesStore.pipHintMessage;

    Future<void> openPageAndFloat() async {
      final store = VideoResourcesStore(
        repository: _FakeVideoRepository(),
        availabilityChecker: (_) async => true,
      );
      addTearDown(store.dispose);
      await tester.pumpWidget(
        _wrapDs(
          VideoResourcesPage(
            store: store,
            expandedPlayerBuilder: (_) => const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('合成监控'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('video-resource-floating-camera-1')),
      );
      await tester.pump();
    }

    await openPageAndFloat();
    expect(find.text(hint), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    await openPageAndFloat();
    expect(find.text(hint), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('行内展开切全屏复用同一会话，退出全屏回行内，全屏关闭后收起行内', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final session = VideoPlaybackSession.forTesting(
      resource: _resource,
      status: VideoPlaybackStatus.playing,
    );
    final store = VideoResourcesStore(
      repository: _FakeVideoRepository(),
      availabilityChecker: (_) async => true,
    );
    await tester.pumpWidget(
      _wrapDs(
        VideoResourcesPage(
          store: store,
          playback: session,
          expandedPlayerBuilder: (_) => VideoPlaybackSurface(session: session),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('合成监控'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-fullscreen-camera-1')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(VideoFullscreenScreen), findsOneWidget);
    expect(session.presentation, VideoPlaybackPresentation.fullscreen);

    await tester.tap(find.byKey(const Key('video-fullscreen-exit')));
    await tester.pumpAndSettle();
    expect(find.byType(VideoFullscreenScreen), findsNothing);
    expect(session.presentation, VideoPlaybackPresentation.inline);
    expect(
      find.byKey(const ValueKey<String>('video-resource-expanded-camera-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-fullscreen-camera-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-fullscreen-close')));
    await tester.pumpAndSettle();

    expect(session.hasResource, isFalse);
    expect(
      find.byKey(const ValueKey<String>('video-resource-expanded-camera-1')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
    store.dispose();
    session.dispose();
  });

  testWidgets('游客认证拦截、空态与加载失败重试正常工作', (tester) async {
    var authTapped = 0;
    final guestStore = VideoResourcesStore(
      repository: _FakeVideoRepository(),
      isGuestProvider: () => true,
      availabilityChecker: (_) async => true,
    );
    await tester.pumpWidget(
      _wrapDs(
        VideoResourcesPage(
          store: guestStore,
          onAuthenticate: () async {
            authTapped++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('需要完成单位认证'), findsOneWidget);
    await tester.tap(find.text('去完成认证'));
    await tester.pumpAndSettle();
    expect(authTapped, 1);

    await tester.pumpWidget(const SizedBox());
    guestStore.dispose();

    final failingRepo = _FakeVideoRepository(
      resources: const <VideoResource>[],
      fetchError: StateError('network down'),
    );
    final errorStore = VideoResourcesStore(
      repository: failingRepo,
      availabilityChecker: (_) async => true,
    );
    await tester.pumpWidget(_wrapDs(VideoResourcesPage(store: errorStore)));
    await tester.pumpAndSettle();

    expect(find.text('视频资源加载失败'), findsOneWidget);
    failingRepo.fetchError = null;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(find.text('暂无可用视频资源'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    errorStore.dispose();
  });

  testWidgets('360dp 窄屏与 130% 字号下昼白/暗曜双主题零溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longResources = const <VideoResource>[
      VideoResource(
        id: 'cam-long-1',
        name: '示例化工园区北门危化品装卸区高空瞭望全景监控一号点位',
        streamUrl: 'https://video.example.test/cam1.flv',
        description: '主通道高清云台球机与红外热成像双光联动画面',
      ),
      VideoResource(
        id: 'cam-long-2',
        name: '示例储罐区南侧消防泵房及泡沫站入口监控二号点位',
        streamUrl: 'https://video.example.test/cam2.flv',
        description: '离线测试点位用于验证窄屏大字号离线胶囊折行零溢出',
      ),
    ];

    for (final brightness in const <Brightness>[
      Brightness.light,
      Brightness.dark,
    ]) {
      final session = VideoPlaybackSession.forTesting(
        resource: longResources.first,
        status: VideoPlaybackStatus.failed,
        lastError: 'synthetic timeout',
      );
      final store = VideoResourcesStore(
        repository: _FakeVideoRepository(
          resources: longResources,
          canManage: true,
        ),
        availabilityChecker: (r) async => r.id == 'cam-long-1',
      );

      await tester.pumpWidget(
        _wrapDs(
          VideoResourcesPage(
            store: store,
            playback: session,
            isOffline: true,
            expandedPlayerBuilder: (_) => VideoPlaybackSurface(
              session: session,
            ),
          ),
          brightness: brightness,
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(longResources.first.name));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('在线'), findsOneWidget);
      expect(find.text('离线·不可播放'), findsOneWidget);
      expect(find.text('视频连接失败'), findsOneWidget);
      expect(find.text('重新连接'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      store.dispose();
      session.dispose();
    }
  });
}
