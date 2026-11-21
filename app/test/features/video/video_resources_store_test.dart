import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/features/video/data/models/video_resource.dart';
import 'package:watchdog/features/video/data/video_repository.dart';
import 'package:watchdog/features/video/state/video_resources_store.dart';

const _cam1 = VideoResource(
  id: 'camera-1',
  name: '合成监控一',
  streamUrl: 'https://video.example.test/live1.flv',
  description: '主入口方向',
  version: 3,
);

const _cam2 = VideoResource(
  id: 'camera-2',
  name: '合成监控二',
  streamUrl: 'https://video.example.test/live2.flv',
  description: '东侧通道',
  version: 1,
);

class _FakeVideoRepository implements VideoRepository {
  _FakeVideoRepository({
    this.resources = const <VideoResource>[_cam1],
    this.canManage = false,
    this.throwOnAccess = false,
    this.fetchError,
  });

  List<VideoResource> resources;
  bool canManage;
  bool throwOnAccess;
  Object? fetchError;
  int fetchCount = 0;

  @override
  Future<Map<String, dynamic>> videoResourceAccess() async {
    if (throwOnAccess) {
      throw StateError('404 not found');
    }
    return <String, dynamic>{'can_manage': canManage};
  }

  @override
  Future<List<VideoResource>> fetchVideoResources({
    bool includeInactive = false,
  }) async {
    fetchCount++;
    if (fetchError != null) {
      throw fetchError!;
    }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('PostgreSQL BIGINT 字符串可解析为整数', () {
    final resource = VideoResource.fromJson(<String, dynamic>{
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

  test('URL 校验仅允许无凭据且无锚点的 HTTPS 地址', () {
    expect(
      VideoResourcesStore.isValidStreamUrl('https://video.example.test/a.flv'),
      isTrue,
    );
    expect(
      VideoResourcesStore.isValidStreamUrl('http://video.example.test/a.flv'),
      isFalse,
    );
    expect(
      VideoResourcesStore.isValidStreamUrl(
        'https://user:pass@video.example.test/a.flv',
      ),
      isFalse,
    );
    expect(
      VideoResourcesStore.isValidStreamUrl(
        'https://video.example.test/a.flv#frag',
      ),
      isFalse,
    );
    expect(VideoResourcesStore.isValidStreamUrl('not-a-url'), isFalse);
  });

  test('加载视频资源、管理权限与并发可达性探测', () async {
    final repo = _FakeVideoRepository(
      resources: const <VideoResource>[_cam1, _cam2],
      canManage: true,
    );
    final store = VideoResourcesStore(
      repository: repo,
      availabilityChecker: (resource) async => resource.id == 'camera-1',
    );
    addTearDown(store.dispose);

    await store.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(store.loading, isFalse);
    expect(store.error, isNull);
    expect(store.canManage, isTrue);
    expect(store.resources, hasLength(2));
    expect(store.availabilityOf('camera-1'), isTrue);
    expect(store.availabilityOf('camera-2'), isFalse);
  });

  test('旧版部署缺失 /access 接口时回退为非管理员且仍加载列表', () async {
    final repo = _FakeVideoRepository(throwOnAccess: true);
    final store = VideoResourcesStore(
      repository: repo,
      availabilityChecker: (_) async => true,
    );
    addTearDown(store.dispose);

    await store.load();
    await Future<void>.delayed(Duration.zero);

    expect(store.canManage, isFalse);
    expect(store.resources, hasLength(1));
    expect(store.error, isNull);
  });

  test('加载视频资源异常时记录错误并结束 loading 状态', () async {
    final repo = _FakeVideoRepository(fetchError: StateError('timeout'));
    final store = VideoResourcesStore(
      repository: repo,
      availabilityChecker: (_) async => true,
    );
    addTearDown(store.dispose);

    await store.load();

    expect(store.loading, isFalse);
    expect(store.error, contains('timeout'));
    expect(store.resources, isEmpty);
  });

  test('并发重刷时丢弃过期的可达性探测结果', () async {
    final firstProbe = Completer<bool>();
    var probeCalls = 0;
    final repo = _FakeVideoRepository(resources: const <VideoResource>[_cam1]);
    final store = VideoResourcesStore(
      repository: repo,
      availabilityChecker: (_) {
        probeCalls++;
        if (probeCalls == 1) return firstProbe.future;
        return Future<bool>.value(true);
      },
    );
    addTearDown(store.dispose);

    await store.load();
    await store.load();
    await Future<void>.delayed(Duration.zero);
    expect(store.availabilityOf('camera-1'), isTrue);

    firstProbe.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(store.availabilityOf('camera-1'), isTrue);
  });

  test('游客或未认证状态不请求仓储且清空敏感列表', () async {
    var guest = false;
    final authNotifier = ValueNotifier<int>(0);
    final repo = _FakeVideoRepository(canManage: true);
    final store = VideoResourcesStore(
      repository: repo,
      isGuestProvider: () => guest,
      authListenable: authNotifier,
      availabilityChecker: (_) async => true,
    );
    addTearDown(() {
      store.dispose();
      authNotifier.dispose();
    });

    await store.load();
    expect(store.resources, hasLength(1));
    expect(store.canManage, isTrue);

    guest = true;
    authNotifier.value++;
    await Future<void>.delayed(Duration.zero);

    expect(store.isAuthenticated, isFalse);
    expect(store.resources, isEmpty);
    expect(store.canManage, isFalse);
    expect(repo.fetchCount, 1);
  });

  test('画中画耗电提示通过 pip_hint_shown_v1 持久化且只触发一次', () async {
    final repo = _FakeVideoRepository();
    final firstStore = VideoResourcesStore(
      repository: repo,
      availabilityChecker: (_) async => true,
    );
    await firstStore.loadPipHintShown();
    expect(firstStore.pipHintShown, isFalse);
    expect(firstStore.consumePipHintIfNeeded(), isTrue);
    expect(firstStore.consumePipHintIfNeeded(), isFalse);
    await Future<void>.delayed(Duration.zero);
    firstStore.dispose();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(VideoResourcesStore.pipHintKey), isTrue);

    final secondStore = VideoResourcesStore(
      repository: repo,
      availabilityChecker: (_) async => true,
    );
    await secondStore.loadPipHintShown();
    expect(secondStore.pipHintShown, isTrue);
    expect(secondStore.consumePipHintIfNeeded(), isFalse);
    secondStore.dispose();
  });
}
