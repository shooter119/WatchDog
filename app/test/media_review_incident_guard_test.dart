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
// 4. 不输入口述，确认主按钮「保存并完成」；点击后应回相机且本机有资料。
// 5. 再拍一张，核对页口述框输入「现场已设置警戒」（或录像口述后停止，
//    等待本机转写），确认仍为「保存并完成」。点击不弹写入确认，返回相机；
//    在「现场资料」重开该条，确认口述草稿保留；结合请求日志检查无写入请求。
//    游客状态无远端记录仅是辅助观察，零 API 调用由下方 fake 断言证明。
// 6. 有警情对照：重进游客模式恢复演练警情，或登录后加入真实警情，
//    拍摄并补写口述，确认「核对无误，写入警情」，
//    点击先弹「写入警情？」；联网真实警情仅「确认写入」后新增一次记录并回相机。
//
// 代码核查：media_review_page.dart 的 _actionBar 在无警情时选择本地完成分支；
// _confirmAndSubmit 检查 _hasIncident，_submit 在读取 API 前再次检查当前警情 ID。
// currentIncident == null 时不会走到 createIncidentObservation，含确认弹窗期间退出。

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

  @override
  Future<void> updateDerived({
    required String id,
    String? transcript,
    List<LocalAsrSegment>? segments,
    List<String>? frames,
    String? observationId,
  }) async {
    if (transcript != null) drafts[id] = transcript;
    if (observationId != null) linked.add(observationId);
  }
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
          return 'content://media/test/1';
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
                  await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
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
    expect(results, [true]);
    expect(find.byType(MediaReviewPage), findsNothing);
    expect(mediaCalls.where((c) => c.method == 'saveToGallery'), hasLength(1));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('无当前警情且有转写：保存完成只存草稿，不调用写警情 API', (tester) async {
    final results = await open(tester, '原始转写');
    expect(controller.currentIncident, isNull);
    await tester.enterText(find.byType(TextField), '核对后的口述');
    await tester.pump();
    expect(find.text('保存并完成'), findsOneWidget);
    expect(find.text('核对无误，写入警情'), findsNothing);
    await tester.tap(find.text('保存并完成'));
    await tester.pumpAndSettle();
    expect(find.text('写入警情？'), findsNothing);
    expect(api.transcripts, isEmpty);
    expect(store.linked, isEmpty);
    expect(store.drafts['media-guard'], '核对后的口述');
    await finish(tester, results);
  });

  testWidgets('无当前警情且无文本：保存完成导出相册并返回，不写警情', (tester) async {
    final results = await open(tester, '');
    expect(find.text('保存并完成'), findsOneWidget);
    expect(find.text('核对无误，写入警情'), findsNothing);
    await tester.tap(find.text('保存并完成'));
    await tester.pumpAndSettle();
    expect(api.transcripts, isEmpty);
    expect(store.linked, isEmpty);
    await finish(tester, results);
  });

  testWidgets('有当前警情且有文本：确认写入前零调用，确认后只提交一次', (tester) async {
    joinIncident();
    final results = await open(tester, '现场已设置警戒');
    expect(find.text('核对无误，写入警情'), findsOneWidget);
    expect(find.text('保存并完成'), findsNothing);
    await tester.tap(find.text('核对无误，写入警情'));
    await tester.pumpAndSettle();
    expect(find.text('写入警情？'), findsOneWidget);
    expect(api.transcripts, isEmpty);
    await tester.tap(find.text('确认写入'));
    await tester.pumpAndSettle();
    expect(api.transcripts, ['现场已设置警戒']);
    expect(store.linked, ['media-guard']);
    await finish(tester, results);
  });

  testWidgets('写入确认期间当前警情清空：再次检查并阻止 API 调用', (tester) async {
    joinIncident();
    final results = await open(tester, '现场已设置警戒');
    await tester.tap(find.text('核对无误，写入警情'));
    await tester.pumpAndSettle();
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
