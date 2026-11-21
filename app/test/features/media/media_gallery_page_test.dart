import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/media/state/media_gateway.dart';
import 'package:watchdog/features/media/ui/media_gallery_page.dart';
import 'package:watchdog/services/local_media_store.dart';
import 'package:watchdog/services/media_share_service.dart';

class _FakeMediaStore extends LocalMediaStore {
  _FakeMediaStore({
    List<LocalMedia> incidentItems = const [],
    List<LocalMedia> unlinkedItems = const [],
  }) : incidentItems = List<LocalMedia>.from(incidentItems),
       unlinkedItems = List<LocalMedia>.from(unlinkedItems),
       super.forTesting();

  final List<LocalMedia> incidentItems;
  final List<LocalMedia> unlinkedItems;
  final List<String> deletedIds = [];
  final List<(String, String)> attached = [];
  int expiredCount = 0;
  int purgeCalls = 0;

  @override
  Future<List<LocalMedia>> listForIncident(String incidentId) async =>
      List<LocalMedia>.unmodifiable(incidentItems);

  @override
  Future<List<LocalMedia>> listUnlinked() async =>
      List<LocalMedia>.unmodifiable(unlinkedItems);

  @override
  Future<void> attachToIncident(String id, String incidentId) async {
    attached.add((id, incidentId));
    final idx = unlinkedItems.indexWhere((e) => e.id == id);
    if (idx != -1) {
      final item = unlinkedItems.removeAt(idx);
      incidentItems.add(
        LocalMedia(
          id: item.id,
          incidentId: incidentId,
          kind: item.kind,
          path: item.path,
          sourcePath: item.sourcePath,
          durationMs: item.durationMs,
          capturedAt: item.capturedAt,
          lat: item.lat,
          lon: item.lon,
          address: item.address,
          weather: item.weather,
          transcript: item.transcript,
          segments: item.segments,
          frames: item.frames,
          observationId: item.observationId,
        ),
      );
    }
  }

  @override
  Future<void> deleteById(String id) async {
    deletedIds.add(id);
    incidentItems.removeWhere((e) => e.id == id);
    unlinkedItems.removeWhere((e) => e.id == id);
  }

  @override
  Future<int> countExpired({
    int days = LocalMediaStore.retentionDays,
    DateTime? now,
  }) async => expiredCount;

  @override
  Future<List<String>> purgeExpired({
    int days = LocalMediaStore.retentionDays,
    DateTime? now,
  }) async {
    purgeCalls++;
    final count = expiredCount;
    expiredCount = 0;
    return List.generate(count, (i) => '/tmp/watchdog-test/expired-$i.jpg');
  }
}

LocalMedia _media({
  required String id,
  String incidentId = 'incident-1',
  String kind = 'photo',
  String path = '/tmp/watchdog-test/wm.jpg',
  String sourcePath = '',
  int durationMs = 0,
  String transcript = '',
  String observationId = '',
  List<String> frames = const [],
}) {
  return LocalMedia(
    id: id,
    incidentId: incidentId,
    kind: kind,
    path: path,
    sourcePath: sourcePath,
    durationMs: durationMs,
    capturedAt: 1,
    lat: null,
    lon: null,
    address: '',
    weather: '',
    transcript: transcript,
    segments: const [],
    frames: frames,
    observationId: observationId,
  );
}

Future<void> _pumpAsyncAction(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mediaChannel = MethodChannel('watchdog/media');
  late List<MethodCall> mediaCalls;
  late List<ShareParams> shareCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mediaCalls = [];
    shareCalls = [];
    MediaShareService.overrideShare = (params) async {
      shareCalls.add(params);
      return const ShareResult('', ShareResultStatus.dismissed);
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaChannel, (call) async {
          mediaCalls.add(call);
          if (call.method == 'savePairToGallery') {
            return const ['content://media/wm', 'content://media/src'];
          }
          if (call.method == 'saveToGallery') {
            return 'content://media/single';
          }
          return null;
        });
  });

  tearDown(() {
    MediaShareService.overrideShare = null;
    LocalMediaStore.overrideInstance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaChannel, null);
  });

  Future<void> pumpGallery(
    WidgetTester tester, {
    MediaIncidentRef? incident,
    MediaDeriveCallback? deriveMedia,
    double scale = 1.0,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: MediaGalleryPage(
          gateway: MediaGateway(
            readCurrentIncident: () => incident,
            deriveMedia: deriveMedia,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const activeIncident = MediaIncidentRef(id: 'incident-1', title: '测试警情');

  testWidgets('支持当前警情与未关联筛选，并展示已写入/未关联状态胶囊', (tester) async {
    LocalMediaStore.overrideInstance = _FakeMediaStore(
      incidentItems: [
        _media(id: 'p1', transcript: '现场明火已控制', observationId: 'p1'),
      ],
      unlinkedItems: [
        _media(id: 'v1', incidentId: '', kind: 'video', durationMs: 12000),
      ],
    );

    await pumpGallery(tester, incident: activeIncident);

    expect(find.text('现场资料'), findsOneWidget);
    expect(find.text('照片'), findsOneWidget);
    expect(find.text('录像 12s'), findsOneWidget);
    expect(find.text('现场明火已控制'), findsOneWidget);
    expect(find.text('未识别到口述内容'), findsOneWidget);
    expect(find.text('已写入警情'), findsOneWidget);
    expect(find.text('未关联'), findsOneWidget);

    await tester.tap(find.byKey(const Key('media-filter-incident')));
    await tester.pumpAndSettle();
    expect(find.text('照片'), findsOneWidget);
    expect(find.text('录像 12s'), findsNothing);

    await tester.tap(find.byKey(const Key('media-filter-unlinked')));
    await tester.pumpAndSettle();
    expect(find.text('照片'), findsNothing);
    expect(find.text('录像 12s'), findsOneWidget);
  });

  testWidgets('空状态按是否有当前警情展示对应提示', (tester) async {
    LocalMediaStore.overrideInstance = _FakeMediaStore();
    await pumpGallery(tester, incident: activeIncident);
    expect(find.text('还没有拍摄现场照片或录像'), findsOneWidget);

    await pumpGallery(tester, incident: null);
    expect(find.text('还没有当前警情'), findsOneWidget);
  });

  testWidgets('删除与清理过期均通过 CommandSheet 二次确认，取消不执行，确认后删除', (tester) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('watchdog-gallery-delete-'),
    ))!;
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final wm = File('${dir.path}/WM.jpg')..writeAsBytesSync([1]);
    final src = File('${dir.path}/SRC.jpg')..writeAsBytesSync([2]);
    final store = _FakeMediaStore(
      incidentItems: [_media(id: 'p1', path: wm.path, sourcePath: src.path)],
    )..expiredCount = 3;
    LocalMediaStore.overrideInstance = store;

    await pumpGallery(tester, incident: activeIncident);

    // 1. 清理过期取消 -> 确认
    await tester.tap(find.byIcon(Icons.cleaning_services_outlined));
    await tester.pumpAndSettle();
    expect(find.text('清理过期文件？'), findsOneWidget);
    expect(find.textContaining('将删除 3 个超过 30 天的媒体文件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.purgeCalls, 0);

    await tester.tap(find.byIcon(Icons.cleaning_services_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理'));
    await tester.pumpAndSettle();
    expect(store.purgeCalls, 1);

    // 2. 删除单条取消 -> 确认
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条现场资料？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.deletedIds, isEmpty);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(CommandSheet),
        matching: find.text('删除'),
      ),
    );
    await tester.pumpAndSettle();
    await _pumpAsyncAction(tester);

    expect(store.deletedIds, ['p1']);
    expect(wm.existsSync(), isFalse);
    expect(src.existsSync(), isFalse);
  });

  testWidgets('菜单支持保存两份到相册、分享与视频重新识别口述', (tester) async {
    var derivedCalls = 0;
    final store = _FakeMediaStore(
      incidentItems: [
        _media(
          id: 'v1',
          kind: 'video',
          durationMs: 9000,
          path: '/tmp/watchdog-test/VID_1_WM.mp4',
          sourcePath: '/tmp/watchdog-test/SRC_VID_1.mp4',
        ),
      ],
    );
    LocalMediaStore.overrideInstance = store;

    await pumpGallery(
      tester,
      incident: activeIncident,
      deriveMedia: (media, {onProgress, onError, isCancelled}) async {
        derivedCalls++;
        return media.copyWith(transcript: '重新识别到的口述');
      },
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新识别口述'));
    await _pumpAsyncAction(tester);
    expect(derivedCalls, 1);
    expect(find.textContaining('识别完成'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();
    expect(shareCalls.single.files!.single.path, '/tmp/watchdog-test/VID_1_WM.mp4');

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存两份到手机相册'));
    await _pumpAsyncAction(tester);
    expect(mediaCalls.where((c) => c.method == 'savePairToGallery'), hasLength(1));
    expect(store.deletedIds, contains('v1'));
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('360dp @ 130% 字号资料页（${brightness.name}）零溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      LocalMediaStore.overrideInstance = _FakeMediaStore(
        incidentItems: [
          _media(id: 'p1', transcript: '现场明火已控制，正在清理余火', observationId: 'p1'),
        ],
        unlinkedItems: [
          _media(id: 'v1', incidentId: '', kind: 'video', durationMs: 15000),
        ],
      );

      await pumpGallery(
        tester,
        incident: activeIncident,
        scale: 1.3,
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('现场资料'), findsOneWidget);
    });
  }
}
