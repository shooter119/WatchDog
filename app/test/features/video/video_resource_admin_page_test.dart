import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/video/data/models/video_resource.dart';
import 'package:watchdog/features/video/data/video_repository.dart';
import 'package:watchdog/features/video/ui/video_resource_admin_page.dart';

class _FakeVideoRepository implements VideoRepository {
  _FakeVideoRepository({
    List<VideoResource> resources = const <VideoResource>[],
  }) : _resources = <VideoResource>[...resources];

  final List<VideoResource> _resources;
  Object? fetchError;
  Object? toggleError;
  int lastUpdatedVersion = -1;

  @override
  Future<Map<String, dynamic>> videoResourceAccess() async => <String, dynamic>{
    'can_manage': true,
  };

  @override
  Future<List<VideoResource>> fetchVideoResources({
    bool includeInactive = false,
  }) async {
    if (fetchError != null) throw fetchError!;
    return <VideoResource>[..._resources];
  }

  @override
  Future<VideoResource> addVideoResource({
    required String name,
    required String streamUrl,
    String description = '',
    bool active = true,
  }) async {
    final created = VideoResource(
      id: 'cam-${_resources.length + 1}',
      name: name.trim(),
      streamUrl: streamUrl.trim(),
      description: description.trim(),
      active: active,
      version: 1,
    );
    _resources.add(created);
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
    if (toggleError != null) throw toggleError!;
    lastUpdatedVersion = expectedVersion;
    final idx = _resources.indexWhere((item) => item.id == id);
    final old = _resources[idx];
    final updated = VideoResource(
      id: old.id,
      name: name?.trim() ?? old.name,
      streamUrl: streamUrl?.trim() ?? old.streamUrl,
      description: description?.trim() ?? old.description,
      active: active ?? old.active,
      sortOrder: old.sortOrder,
      version: old.version + 1,
      updatedAt: old.updatedAt,
    );
    _resources[idx] = updated;
    return updated;
  }
}

Widget _wrapDs(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? appChild) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: appChild!,
    ),
    home: child,
  );
}

void main() {
  testWidgets('非管理员禁止进入维护操作并展示锁定空态', (WidgetTester tester) async {
    final repo = _FakeVideoRepository();
    await tester.pumpWidget(
      _wrapDs(VideoResourceAdminPage(repository: repo, canManage: false)),
    );
    await tester.pumpAndSettle();

    expect(find.text('仅管理员可维护视频资源'), findsOneWidget);
    expect(find.byTooltip('新增视频资源'), findsNothing);
  });

  testWidgets('视频资源管理页支持新增校验、编辑与启停切换', (WidgetTester tester) async {
    final repo = _FakeVideoRepository(
      resources: const <VideoResource>[
        VideoResource(
          id: 'cam-1',
          name: '示例东门监控',
          streamUrl: 'https://video.example.test/east.flv',
          description: '东门通道',
          active: true,
          version: 3,
        ),
      ],
    );

    await tester.pumpWidget(_wrapDs(VideoResourceAdminPage(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.text('示例东门监控'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);

    // 停用开关
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(repo.lastUpdatedVersion, 3);
    expect(find.text('已停用'), findsOneWidget);

    // 新增资源并校验非 HTTPS 拦截
    await tester.tap(find.byTooltip('新增视频资源'));
    await tester.pumpAndSettle();
    expect(find.text('新增视频资源'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '示例西门监控');
    await tester.enterText(
      find.byType(TextField).at(2),
      'http://video.example.test/west.flv',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('视频地址必须使用 HTTPS'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).at(2),
      'https://video.example.test/west.flv',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('示例西门监控'), findsOneWidget);

    // 点击卡片编辑名称
    await tester.tap(find.text('示例东门监控'));
    await tester.pumpAndSettle();
    expect(find.text('编辑视频资源'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '示例东门高清监控');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('示例东门高清监控'), findsOneWidget);
  });

  testWidgets('360dp 窄屏与 130% 字号下昼白/暗曜双主题零溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _FakeVideoRepository(
      resources: const <VideoResource>[
        VideoResource(
          id: 'cam-long',
          name: '示例危化品装卸区南侧通道高空瞭望双光云台球机一号监控点位',
          streamUrl: 'https://video.example.test/long.flv',
          active: true,
          version: 1,
        ),
      ],
    );

    for (final brightness in const <Brightness>[
      Brightness.light,
      Brightness.dark,
    ]) {
      await tester.pumpWidget(
        _wrapDs(
          VideoResourceAdminPage(repository: repo, isOffline: true),
          brightness: brightness,
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
