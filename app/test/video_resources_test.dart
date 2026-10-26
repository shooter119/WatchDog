import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/models/video_resources.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/pages/settings_page.dart';
import 'package:watchdog/pages/video_resource_admin_page.dart';
import 'package:watchdog/pages/video_playback_surface.dart';
import 'package:watchdog/pages/video_resources_page.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/video_playback_session.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_widgets.dart';

const _resource = VideoResource(
  id: 'camera-1',
  name: '合成监控',
  streamUrl: 'https://video.example.test/live.flv',
  description: '用于自动化测试',
  version: 3,
);

class _VideoApi extends ApiClient {
  _VideoApi({
    List<VideoResource> resources = const [_resource],
    this.canManage = false,
  }) : resources = [...resources],
       super(
         baseUrl: 'https://example.test',
         incidentId: '',
         sessionToken: 'synthetic-session',
       );

  List<VideoResource> resources;
  bool canManage;
  bool? lastActive;
  Map<String, String>? added;

  @override
  Future<Map<String, dynamic>> videoResourceAccess() async => {
    'can_manage': canManage,
  };

  @override
  Future<List<VideoResource>> fetchVideoResources({
    bool includeInactive = false,
  }) async => resources
      .where((item) => includeInactive || item.active)
      .toList(growable: false);

  @override
  Future<VideoResource> addVideoResource({
    required String name,
    required String streamUrl,
    String description = '',
    bool active = true,
  }) async {
    added = {
      'name': name,
      'streamUrl': streamUrl,
      'description': description,
      'active': '$active',
    };
    final created = VideoResource(
      id: 'camera-2',
      name: name,
      streamUrl: streamUrl,
      description: description,
      active: active,
    );
    resources.add(created);
    return created;
  }

  @override
  Future<VideoResource> updateVideoResource(
    String id, {
    required int expectedVersion,
    String? name,
    String? streamUrl,
    String? description,
    bool? active,
  }) async {
    lastActive = active;
    final current = resources.firstWhere((item) => item.id == id);
    final updated = VideoResource(
      id: current.id,
      name: name ?? current.name,
      streamUrl: streamUrl ?? current.streamUrl,
      description: description ?? current.description,
      active: active ?? current.active,
      version: expectedVersion + 1,
    );
    resources = resources
        .map((item) => item.id == id ? updated : item)
        .toList();
    return updated;
  }
}

class _VideoController extends AppController {
  _VideoController(ApiClient client) {
    api = client;
  }

  @override
  bool get isGuest => false;

  @override
  bool get needsAuthentication => false;

  @override
  bool get connectionLost => false;
}

class _DisposableProbe extends StatefulWidget {
  final VoidCallback onDispose;

  const _DisposableProbe({super.key, required this.onDispose});

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PostgreSQL BIGINT 字符串可解析为整数', () {
    final resource = VideoResource.fromJson({
      'id': 'camera-1',
      'name': '现场监控',
      'stream_url': 'https://video.example.test/live.flv',
      'description': '',
      'active': true,
      'sort_order': '10',
      'version': '2',
      'updated_at': '1792510609327',
    });

    expect(resource.sortOrder, 10);
    expect(resource.version, 2);
    expect(resource.updatedAt, 1792510609327);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('首页提供视频资源模块', (tester) async {
    final api = _VideoApi();
    final controller = _VideoController(api);
    final now = DateTime.now().millisecondsSinceEpoch;
    controller.currentIncident = Incident(
      id: 'incident-video',
      number: 'VIDEO-1',
      title: '视频入口测试',
      status: 'active',
      createdAt: now,
      lastActivityAt: now,
    );
    await tester.pumpWidget(
      MaterialApp(home: HomePage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tool-视频资源')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });

  testWidgets('普通成员不显示管理入口，管理员显示且可停用资源', (tester) async {
    final memberApi = _VideoApi();
    final memberController = _VideoController(memberApi);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoResourcesPage(
          controller: memberController,
          availabilityChecker: (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-resource-manage')), findsNothing);
    expect(find.text('合成监控'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    memberController.dispose();
    memberApi.dispose();

    final adminApi = _VideoApi(canManage: true);
    final adminController = _VideoController(adminApi);
    await tester.pumpWidget(
      MaterialApp(home: VideoResourceAdminPage(api: adminApi)),
    );
    await tester.pumpAndSettle();
    expect(find.text('合成监控'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(adminApi.lastActive, false);
    expect(find.text('已停用 · 点击编辑'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    adminController.dispose();
    adminApi.dispose();
  });

  testWidgets('资源名称容器用绿点表示可用、红点表示不可用', (tester) async {
    final api = _VideoApi();
    final controller = _VideoController(api);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoResourcesPage(
          controller: controller,
          availabilityChecker: (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    var dot = tester.widget<Container>(
      find.byKey(const ValueKey('video-resource-status-camera-1')),
    );
    expect((dot.decoration! as BoxDecoration).color, AppColors.online);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();

    final offlineApi = _VideoApi();
    final offlineController = _VideoController(offlineApi);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoResourcesPage(
          controller: offlineController,
          availabilityChecker: (_) async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    dot = tester.widget<Container>(
      find.byKey(const ValueKey('video-resource-status-camera-1')),
    );
    expect((dot.decoration! as BoxDecoration).color, AppColors.alarm);

    await tester.pumpWidget(const SizedBox());
    offlineController.dispose();
    offlineApi.dispose();
  });

  testWidgets('点击资源行内展开播放器，关闭后立即收起并销毁播放器', (tester) async {
    final api = _VideoApi();
    final controller = _VideoController(api);
    var playerDisposed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoResourcesPage(
          controller: controller,
          availabilityChecker: (_) async => true,
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
      find.byKey(const ValueKey('video-resource-expanded-camera-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-resource-close-camera-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('video-resource-close-camera-1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inline-video-player')), findsNothing);
    expect(playerDisposed, isTrue);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });

  testWidgets('展开后的播放器提供全屏、浮窗和关闭三个独立操作', (tester) async {
    var fullscreen = 0;
    var floating = 0;
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
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

    await tester.tap(
      find.byKey(const ValueKey('video-resource-fullscreen-camera-1')),
    );
    await tester.tap(
      find.byKey(const ValueKey('video-resource-floating-camera-1')),
    );
    await tester.tap(
      find.byKey(const ValueKey('video-resource-close-camera-1')),
    );

    expect(fullscreen, 1);
    expect(floating, 1);
    expect(closed, 1);
  });

  testWidgets('浮窗画面提供切换全屏的悬浮按钮', (tester) async {
    final session = VideoPlaybackSession();
    var fullscreen = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FloatingVideoWindow(
              session: session,
              onFullscreen: () => fullscreen++,
            ),
          ),
        ),
      ),
    );

    for (final key in const [
      Key('video-floating-fullscreen'),
      Key('video-floating-close'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    await tester.tap(find.byKey(const Key('video-floating-fullscreen')));
    expect(fullscreen, 1);
    expect(find.byKey(const Key('video-floating-close')), findsOneWidget);

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

    final session = VideoPlaybackSession.forTesting(resource: _resource);
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
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    session.returnInline();
    await tester.pump();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    session.dispose();
  });

  testWidgets('16:9 行内播放器在 1.3 倍字体下显示失败态不溢出', (tester) async {
    tester.view.physicalSize = const Size(430, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = VideoPlaybackSession.forTesting(
      resource: _resource,
      status: VideoPlaybackStatus.failed,
      lastError: 'synthetic failure',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Center(
            child: SizedBox(
              width: 398,
              height: 224,
              child: VideoPlaybackSurface(
                session: session,
                key: const Key('constrained-video-failure'),
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

  testWidgets('视频资源管理页拒绝非 HTTPS 地址并支持新增', (tester) async {
    final api = _VideoApi(resources: const [], canManage: true);
    await tester.pumpWidget(
      MaterialApp(home: VideoResourceAdminPage(api: api)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新增视频资源'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '门口监控');
    await tester.enterText(fields.at(2), 'http://video.example.test/live.flv');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('视频地址必须使用 HTTPS'), findsOneWidget);
    expect(api.added, isNull);

    await tester.enterText(fields.at(2), 'https://video.example.test/live.flv');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.added?['name'], '门口监控');
    expect(find.text('门口监控'), findsOneWidget);
    api.dispose();
  });

  testWidgets('设置页仅对管理员显示视频资源管理', (tester) async {
    tester.view.physicalSize = const Size(430, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await Settings.setRealName('合成成员');
    await Settings.setUnitId('unit-1');
    await Settings.setUnitName('合成消防单位');
    await Settings.setUnitCode('test');

    await Settings.setUserRole('member');
    final memberApi = _VideoApi();
    final memberController = _VideoController(memberApi);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: memberController)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-resource-settings')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    memberController.dispose();
    memberApi.dispose();

    await Settings.setUserRole('admin');
    final adminApi = _VideoApi(canManage: true);
    final adminController = _VideoController(adminApi);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: adminController)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-resource-settings')), findsOneWidget);
    expect(find.text('视频资源管理'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    adminController.dispose();
    adminApi.dispose();
  });

  test('reattachSurface 不改变会话状态，无会话时安全返回', () {
    final session = VideoPlaybackSession.forTesting(
      resource: _resource,
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
    expect(notified, 0, reason: '无播放器时不应触发重建通知');
    idle.dispose();
  });

  testWidgets('切到浮窗时提示画中画会持续耗电，且只提示一次', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const hint = '切到后台会以系统画中画继续播放；视频解码会持续耗电，不用时请关闭浮窗。';
    final api = _VideoApi();
    final controller = _VideoController(api);

    Future<void> openPageAndFloat() async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoResourcesPage(
            controller: controller,
            availabilityChecker: (_) async => true,
            expandedPlayerBuilder: (_) => const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('合成监控'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('video-resource-floating-camera-1')),
      );
      await tester.pump();
    }

    // 第一次：提示出现并落盘
    await openPageAndFloat();
    expect(find.text(hint), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    // 第二次（新页面实例，从持久化标记读取）：不再提示
    await openPageAndFloat();
    expect(find.text(hint), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
}
