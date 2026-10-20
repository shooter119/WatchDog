import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/media_review_page.dart';
import 'package:watchdog/services/local_asr_service.dart';
import 'package:watchdog/services/local_media_store.dart';
import 'package:watchdog/state/app_controller.dart';

// 人工 e2e：
// 1. 进入游客演练模式，在首页展开当前警情卡，点「退出当前警情」→弹窗「确认退出」。
//    保持本次会话，不重新进入游客模式（会自动带 guest-drill-incident）。
// 2. 点首页右下「水印相机」，确认「未关联警情」提示；允许相机权限。
// 3. 选「拍照」并点快门，照片保存后自动进入核对页。
// 4. 不输入口述，点「仅保存」；应先把带水印版与无水印版成对写入系统相册，
//    再回相机；确认相册有两份，且 App「现场资料」不再保留这次拍摄。
// 5. 再拍一张，核对页口述框输入「现场已设置警戒」（或录像口述后停止，
//    等待本机转写），确认底栏只有「保存并分享」和「仅保存」，写警情入口只在
//    口述卡内。点「仅保存」后本机工作副本移除；结合请求日志检查无写入请求。
// 6. 有警情对照：重进游客模式恢复演练警情，或登录后加入真实警情，
//    拍摄并补写口述，确认「核对无误，写入警情」，
//    点击先弹「写入警情？」；确认后只新增一次记录并留在核对页，不会自动导出相册。
// 7. 再点「保存并分享」，确认相册先出现两份文件，随后系统分享菜单只收到带水印版；
//    关闭分享菜单后回相机。
//
// 代码核查：media_review_page.dart 的 _savePair 负责成对导出，成功后调用
// MediaCaptureService.removeLocalCopy 清理本机记录和文件；_saveAndShare 只在
// 分享菜单关闭后清理。_confirmAndSubmit 与 _submit 独立处理警情写入，并在读取
// API 前再次检查当前警情 ID。

class _RecordingApi extends ApiClient {
  _RecordingApi()
    : super(baseUrl: 'http://127.0.0.1', incidentId: 'incident-1');

  final List<String> transcripts = [];

  @override
  Future<void> createIncidentObservation({
    required String transcript,
    required String sourceType,
    required int capturedAt,
    String mediaRef = '',
    Map<String, Object?> structured = const {},
  }) async {
    transcripts.add(transcript);
  }
}

class _MemoryStore extends LocalMediaStore {
  _MemoryStore() : super.forTesting();

  final Map<String, String> drafts = {};
  final List<String> linked = [];
  final List<String> deletedIds = [];

  @override
  Future<void> updateDerived({
    required String id,
    String? transcript,
    List<LocalAsrSegment>? segments,
    List<String>? frames,
    String? observationId,
    String? sourcePath,
  }) async {
    if (transcript != null) drafts[id] = transcript;
    if (observationId != null) linked.add(observationId);
  }

  @override
  Future<void> deleteById(String id) async {
    deletedIds.add(id);
  }
}

Future<void> _pumpAsyncAction(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _tapIncidentSubmit(WidgetTester tester) async {
  final submit = find.text('核对无误，写入警情');
  final scrollable = find
      .descendant(
        of: find.byType(ListView).first,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(submit, 160, scrollable: scrollable);
  await tester.drag(scrollable, const Offset(0, -120));
  await tester.pumpAndSettle();
  expect(submit.hitTestable(), findsOneWidget);
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('watchdog/media');
  late _RecordingApi api;
  late _MemoryStore store;
  late AppController controller;
  late List<MethodCall> mediaCalls;
  final audioChannels = <String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global/events'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers'),
          (call) async {
            if (call.method == 'create') {
              final id = (call.arguments as Map)['playerId'];
              final name = 'xyz.luan/audioplayers/events/$id';
              audioChannels.add(name);
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(
                    MethodChannel(name),
                    (_) async => null,
                  );
            }
            return null;
          },
        );
    api = _RecordingApi();
    store = _MemoryStore();
    LocalMediaStore.overrideInstance = store;
    // 即使没有当前警情也保留可用 API，避免 api == null 掩盖警情保护失效。
    controller = AppController()..api = api;
    mediaCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          mediaCalls.add(call);
          if (call.method == 'savePairToGallery') {
            return const [
              'content://media/test/watermarked',
              'content://media/test/source',
            ];
          }
          if (call.method == 'saveToGallery') {
            return 'content://media/test/1';
          }
          return null;
        });
  });

  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    for (final name in ['xyz.luan/audioplayers', ...audioChannels]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    audioChannels.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global/events'),
          null,
        );
    LocalMediaStore.overrideInstance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void joinIncident() {
    controller.currentIncident = Incident(
      id: 'incident-1',
      number: '测试警情',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 2,
    );
  }

  Future<List<Object?>> open(WidgetTester tester, String transcript) async {
    final results = <Object?>[];
    final media = LocalMedia(
      id: 'media-guard',
      // 故意保留旧警情关联，保证不能用媒体上的 incidentId 绕过当前警情检查。
      incidentId: 'incident-1',
      kind: 'photo',
      path: '/tmp/watchdog-test/none.jpg',
      sourcePath: '/tmp/watchdog-test/SRC_IMG_1.jpg',
      durationMs: 0,
      capturedAt: 1,
      lat: null,
      lon: null,
      address: '',
      weather: '',
      transcript: transcript,
      segments: const [],
      frames: const [],
      observationId: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<MediaReviewOutcome>(
                    MaterialPageRoute<MediaReviewOutcome>(
                      builder: (_) =>
                          MediaReviewPage(controller: controller, media: media),
                    ),
                  ),
                );
              },
              child: const Text('打开核对页'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开核对页'));
    await tester.pumpAndSettle();
    return results;
  }

  Future<void> finish(WidgetTester tester, List<Object?> results) async {
    expect(results, [MediaReviewOutcome.saved]);
    expect(find.byType(MediaReviewPage), findsNothing);
    expect(
      mediaCalls.where((c) => c.method == 'savePairToGallery'),
      hasLength(1),
    );
    expect(store.deletedIds, contains('media-guard'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('无当前警情且有转写：仅保存成对导出，不调用写警情 API', (tester) async {
    final results = await open(tester, '原始转写');
    expect(controller.currentIncident, isNull);
    await tester.enterText(find.byType(TextField), '核对后的口述');
    await tester.pump();
    expect(find.text('保存并分享'), findsOneWidget);
    expect(find.text('仅保存'), findsOneWidget);
    expect(find.text('核对无误，写入警情'), findsNothing);
    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);
    expect(find.text('写入警情？'), findsNothing);
    expect(api.transcripts, isEmpty);
    expect(store.linked, isEmpty);
    expect(store.deletedIds, contains('media-guard'));
    await finish(tester, results);
  });

  testWidgets('无当前警情且无文本：保存完成导出相册并返回，不写警情', (tester) async {
    final results = await open(tester, '');
    expect(find.text('保存并分享'), findsOneWidget);
    expect(find.text('仅保存'), findsOneWidget);
    expect(find.text('核对无误，写入警情'), findsNothing);
    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);
    expect(api.transcripts, isEmpty);
    expect(store.linked, isEmpty);
    await finish(tester, results);
  });

  testWidgets('有当前警情且有文本：确认写入前零调用，确认后只提交一次', (tester) async {
    joinIncident();
    final results = await open(tester, '现场已设置警戒');
    expect(find.text('核对无误，写入警情'), findsOneWidget);
    expect(find.text('保存并分享'), findsOneWidget);
    expect(find.text('仅保存'), findsOneWidget);
    await _tapIncidentSubmit(tester);
    expect(find.text('写入警情？'), findsOneWidget);
    expect(api.transcripts, isEmpty);
    await tester.tap(find.text('确认写入'));
    await tester.pumpAndSettle();
    expect(api.transcripts, ['现场已设置警戒']);
    expect(store.linked, ['media-guard']);
    expect(mediaCalls, isEmpty);
    expect(results, isEmpty);
    expect(find.byType(MediaReviewPage), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('写入确认期间当前警情清空：再次检查并阻止 API 调用', (tester) async {
    joinIncident();
    final results = await open(tester, '现场已设置警戒');
    await _tapIncidentSubmit(tester);
    controller.currentIncident = null;
    await tester.tap(find.text('确认写入'));
    await tester.pumpAndSettle();
    expect(api.transcripts, isEmpty);
    expect(store.linked, isEmpty);
    expect(mediaCalls, isEmpty);
    expect(results, isEmpty);
    expect(find.byType(MediaReviewPage), findsOneWidget);
    expect(find.text('还没有关联警情，先加入或新建警情才能写入'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
