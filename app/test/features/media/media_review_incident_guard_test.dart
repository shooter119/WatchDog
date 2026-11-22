import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/media/state/media_gateway.dart';
import 'package:watchdog/features/media/ui/media_review_page.dart';
import 'package:watchdog/services/local_asr_service.dart';
import 'package:watchdog/services/local_media_store.dart';
import 'package:watchdog/services/media_share_service.dart';

class _MemoryStore extends LocalMediaStore {
  _MemoryStore() : super.forTesting();

  final Map<String, String> drafts = {};
  final List<String> linked = [];
  final List<String> deletedIds = [];
  void Function(String id)? onDelete;

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
    onDelete?.call(id);
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

LocalMedia _sampleMedia({
  String id = 'media-guard',
  String incidentId = 'incident-1',
  String kind = 'photo',
  String path = '/tmp/watchdog-test/none.jpg',
  String sourcePath = '/tmp/watchdog-test/SRC_IMG_1.jpg',
  int durationMs = 0,
  String transcript = '',
  List<LocalAsrSegment> segments = const [],
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
    segments: segments,
    frames: frames,
    observationId: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('watchdog/media');
  late _MemoryStore store;
  late List<MethodCall> mediaCalls;
  late List<ShareParams> shareCalls;
  late List<String> submittedTranscripts;
  late MediaIncidentRef? currentIncident;
  late bool apiAvailable;
  late bool submitFails;

  MediaGateway buildGateway({
    MediaDeriveCallback? deriveMedia,
    MediaNoteSyncCallback? enqueueMediaNoteUpload,
  }) {
    return MediaGateway(
      readCurrentIncident: () => currentIncident,
      isObservationApiAvailable: () => apiAvailable,
      enqueueMediaNoteUpload: enqueueMediaNoteUpload,
      createIncidentObservation: ({
        required String incidentId,
        required String transcript,
        required String sourceType,
        required int capturedAt,
        required String mediaRef,
      }) async {
        if (submitFails) throw Exception('network error');
        submittedTranscripts.add(transcript);
      },
      deriveMedia: deriveMedia,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _MemoryStore();
    LocalMediaStore.overrideInstance = store;
    mediaCalls = [];
    shareCalls = [];
    submittedTranscripts = [];
    currentIncident = null;
    apiAvailable = true;
    submitFails = false;
    MediaShareService.overrideShare = (params) async {
      shareCalls.add(params);
      return const ShareResult('', ShareResultStatus.dismissed);
    };
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

  tearDown(() {
    MediaShareService.overrideShare = null;
    LocalMediaStore.overrideInstance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void joinIncident({String title = '测试警情'}) {
    currentIncident = MediaIncidentRef(
      id: 'incident-1',
      number: '2026-001',
      title: title,
    );
  }

  Future<List<Object?>> openReview(
    WidgetTester tester, {
    LocalMedia? media,
    bool deriving = false,
    MediaDeriveCallback? deriveMedia,
    MediaNoteSyncCallback? enqueueMediaNoteUpload,
    double textScale = 1.0,
    Brightness brightness = Brightness.light,
  }) async {
    final results = <Object?>[];
    final target = media ?? _sampleMedia();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<MediaReviewOutcome>(
                    MaterialPageRoute<MediaReviewOutcome>(
                      builder: (_) => MediaReviewPage(
                        gateway: buildGateway(
                          deriveMedia: deriveMedia,
                          enqueueMediaNoteUpload: enqueueMediaNoteUpload,
                        ),
                        media: target,
                        deriving: deriving,
                      ),
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
    if (deriving) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    } else {
      await tester.pumpAndSettle();
    }
    return results;
  }

  Future<void> expectSavedAndPopped(
    WidgetTester tester,
    List<Object?> results, {
    MediaReviewOutcome expected = MediaReviewOutcome.saved,
  }) async {
    expect(results, [expected]);
    expect(find.byType(MediaReviewPage), findsNothing);
    expect(store.deletedIds, contains('media-guard'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('无当前警情且有转写：仅保存成对导出，不调用写警情 API', (tester) async {
    final results = await openReview(
      tester,
      media: _sampleMedia(transcript: '原始转写'),
    );
    await tester.enterText(find.byType(TextField), '核对后的口述');
    await tester.pump();
    expect(find.text('保存并分享'), findsOneWidget);
    expect(find.text('仅保存'), findsOneWidget);
    expect(find.text('核对无误，写入警情'), findsNothing);

    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);

    expect(find.text('写入警情？'), findsNothing);
    expect(submittedTranscripts, isEmpty);
    expect(store.linked, isEmpty);
    expect(
      mediaCalls.where((c) => c.method == 'savePairToGallery'),
      hasLength(1),
    );
    await expectSavedAndPopped(tester, results);
  });

  testWidgets('无当前警情且无文本：保存完成导出相册并返回，不写警情', (tester) async {
    final results = await openReview(tester, media: _sampleMedia());
    expect(find.text('核对无误，写入警情'), findsNothing);
    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);
    expect(submittedTranscripts, isEmpty);
    expect(store.linked, isEmpty);
    await expectSavedAndPopped(tester, results);
  });

  testWidgets('有当前警情且有文本：确认写入前零调用，确认后只提交一次', (tester) async {
    joinIncident(title: '示例小区地下车库火警');
    final results = await openReview(
      tester,
      media: _sampleMedia(transcript: '现场已设置警戒'),
    );
    expect(find.text('核对无误，写入警情'), findsOneWidget);
    await _tapIncidentSubmit(tester);
    expect(find.text('写入警情？'), findsOneWidget);
    expect(find.textContaining('示例小区地下车库火警'), findsOneWidget);
    expect(submittedTranscripts, isEmpty);

    await tester.tap(find.text('确认写入'));
    await tester.pumpAndSettle();

    expect(submittedTranscripts, ['现场已设置警戒']);
    expect(store.linked, ['media-guard']);
    expect(mediaCalls, isEmpty);
    expect(results, isEmpty);
    expect(find.byType(MediaReviewPage), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('写入确认期间当前警情清空：再次检查并阻止 API 调用', (tester) async {
    joinIncident();
    final results = await openReview(
      tester,
      media: _sampleMedia(transcript: '现场已设置警戒'),
    );
    await _tapIncidentSubmit(tester);
    currentIncident = null;
    await tester.tap(find.text('确认写入'));
    await tester.pumpAndSettle();

    expect(submittedTranscripts, isEmpty);
    expect(store.linked, isEmpty);
    expect(mediaCalls, isEmpty);
    expect(results, isEmpty);
    expect(find.byType(MediaReviewPage), findsOneWidget);
    expect(find.text('还没有关联警情，先加入或新建警情才能写入'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('有当前警情且有文本：点击仅保存自动写入警情并导出相册', (tester) async {
    joinIncident();
    final results = await openReview(
      tester,
      media: _sampleMedia(transcript: '现场已完成搜救，无人员被困'),
    );
    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);

    expect(submittedTranscripts, ['现场已完成搜救，无人员被困']);
    expect(store.linked, ['media-guard']);
    await expectSavedAndPopped(tester, results);
  });

  testWidgets('已手动写入警情后点击仅保存：不重复调用写警情接口', (tester) async {
    joinIncident();
    final results = await openReview(
      tester,
      media: _sampleMedia(transcript: '现场明火已灭'),
    );
    await _tapIncidentSubmit(tester);
    await tester.tap(find.text('确认写入'));
    await tester.pumpAndSettle();
    expect(submittedTranscripts, ['现场明火已灭']);

    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);

    expect(submittedTranscripts, ['现场明火已灭']);
    await expectSavedAndPopped(tester, results);
  });

  testWidgets('编辑内容在 400ms 防抖后自动落盘本机草稿，离线写入提示保留草稿', (tester) async {
    joinIncident();
    apiAvailable = false;
    await openReview(tester, media: _sampleMedia(transcript: '初始'));
    await tester.enterText(find.byType(TextField), '现场已设置警戒，等待支援');
    await tester.pump(const Duration(milliseconds: 500));
    expect(store.drafts['media-guard'], '现场已设置警戒，等待支援');

    await _tapIncidentSubmit(tester);
    await tester.tap(find.text('确认写入'));
    await tester.pumpAndSettle();
    expect(find.text('未连接服务器，口述文字已保存在本机草稿，联网后可再写入'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('保存并分享严格先成对保存再仅分享带水印版，关闭分享后清理工作副本', (tester) async {
    joinIncident();
    final operations = <String>[];
    final shareClosed = Completer<void>();
    store.onDelete = (_) => operations.add('delete');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          mediaCalls.add(call);
          if (call.method == 'savePairToGallery') {
            operations.add('pair');
            return const [
              'content://media/video/wm',
              'content://media/video/src',
            ];
          }
          return null;
        });
    MediaShareService.overrideShare = (params) async {
      operations.add('share');
      shareCalls.add(params);
      await shareClosed.future;
      return const ShareResult('', ShareResultStatus.dismissed);
    };

    final results = await openReview(
      tester,
      media: _sampleMedia(
        kind: 'video',
        durationMs: 8000,
        path: '/tmp/watchdog-test/VID_1_WM.mp4',
        sourcePath: '/tmp/watchdog-test/SRC_VID_1.mp4',
      ),
    );
    await tester.tap(find.text('保存并分享'));
    await _pumpAsyncAction(tester);

    expect(operations, ['pair', 'share']);
    expect(store.deletedIds, isEmpty);
    expect(find.byType(MediaReviewPage), findsOneWidget);

    shareClosed.complete();
    await _pumpAsyncAction(tester);

    expect(operations, ['pair', 'share', 'delete']);
    expect(shareCalls.single.files!.single.path, '/tmp/watchdog-test/VID_1_WM.mp4');
    await expectSavedAndPopped(
      tester,
      results,
      expected: MediaReviewOutcome.shared,
    );
  });

  testWidgets('长按分段时间戳删除并可撤销，旧资料无母版降级为单份保存', (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const seg = LocalAsrSegment(text: '现场有明火', startMs: 1000, endMs: 2000);
    final results = await openReview(
      tester,
      media: _sampleMedia(
        sourcePath: '',
        transcript: '现场有明火 需要支援',
        segments: const [seg],
      ),
    );
    expect(find.textContaining('旧资料没有无水印母版'), findsOneWidget);

    final chip = find.text('00:01  现场有明火');
    await tester.ensureVisible(chip);
    expect(
      tester.getSize(find.byKey(const Key('segment-chip-1000'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.longPress(chip);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '需要支援');

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '现场有明火 需要支援',
    );

    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);
    expect(mediaCalls.where((c) => c.method == 'saveToGallery'), hasLength(1));
    await expectSavedAndPopped(
      tester,
      results,
      expected: MediaReviewOutcome.savedWatermarkedOnly,
    );
  });

  testWidgets('视频离线 ASR 派生支持阶段进度、取消与重试恢复', (tester) async {
    var attempts = 0;
    final firstRun = Completer<LocalMedia>();
    await openReview(
      tester,
      media: _sampleMedia(kind: 'video', durationMs: 6000),
      deriving: true,
      deriveMedia: (
        media, {
        onProgress,
        onError,
        isCancelled,
      }) async {
        attempts++;
        if (attempts == 1) {
          onProgress?.call('正在本地识别口述内容');
          return firstRun.future;
        }
        onError?.call('语音识别失败，请检查网络或本地模型后重试，也可手动补写口述');
        return media;
      },
    );
    expect(find.text('正在本地识别口述内容'), findsOneWidget);
    expect(find.text('取消识别'), findsOneWidget);

    await tester.ensureVisible(find.text('取消识别'));
    await tester.pump();
    await tester.tap(find.text('取消识别'));
    await tester.pumpAndSettle();
    expect(find.text('现场口述（请核对后再使用）'), findsOneWidget);
    firstRun.complete(_sampleMedia(kind: 'video', transcript: '已取消的结果'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('360dp @ 130% 字号核对页（${brightness.name}）零溢出且主操作 >= 56dp', (
      tester,
    ) async {
      joinIncident();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await openReview(
        tester,
        textScale: 1.3,
        brightness: brightness,
        media: _sampleMedia(
          kind: 'video',
          durationMs: 8000,
          transcript: '现场明火已扑灭，正在清理余火，无人员被困',
          segments: const [
            LocalAsrSegment(text: '现场明火已扑灭', startMs: 1000, endMs: 2000),
          ],
          frames: const ['/tmp/watchdog-test/frame-1.jpg'],
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('review-save-share'))).height,
        greaterThanOrEqualTo(56),
      );
      expect(
        tester.getSize(find.byKey(const Key('review-save-only'))).height,
        greaterThanOrEqualTo(56),
      );
    });
  }

  testWidgets('已选警情点击仅保存（照片）将带水印照片入队火场日志并弹出非阻塞提示', (tester) async {
    joinIncident();
    final enqueued = <Map<String, Object?>>[];
    final results = await openReview(
      tester,
      media: _sampleMedia(
        kind: 'photo',
        path: '/tmp/watchdog-test/PHOTO_WM.jpg',
        sourcePath: '/tmp/watchdog-test/PHOTO_SRC.jpg',
        transcript: '',
      ),
      enqueueMediaNoteUpload: ({
        required String kind,
        required String filePath,
        String thumbPath = '',
        required String transcript,
        required int durationMs,
        required int capturedAt,
        String address = '',
        String weather = '',
        required String localMediaId,
        bool syncObservation = false,
      }) async {
        enqueued.add(<String, Object?>{
          'kind': kind,
          'filePath': filePath,
          'transcript': transcript,
          'syncObservation': syncObservation,
          'localMediaId': localMediaId,
        });
        return MediaNoteSyncOutcome.enqueued;
      },
    );

    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);

    expect(enqueued, hasLength(1));
    expect(enqueued.single['kind'], 'photo');
    expect(enqueued.single['filePath'], '/tmp/watchdog-test/PHOTO_WM.jpg');
    expect(enqueued.single['transcript'], '');
    expect(enqueued.single['syncObservation'], isFalse);
    expect(submittedTranscripts, isEmpty);
    await tester.pump();
    expect(find.text('已保存到相册，正在后台同步至火场日志'), findsOneWidget);
    await expectSavedAndPopped(tester, results);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('已选警情点击保存并分享（带口述视频）先成对保存再入队视频与转写文本后打开系统分享', (tester) async {
    joinIncident();
    final events = <String>[];
    final enqueued = <Map<String, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          mediaCalls.add(call);
          if (call.method == 'savePairToGallery') {
            events.add('pair');
            return const [
              'content://media/video/wm',
              'content://media/video/src',
            ];
          }
          return null;
        });
    MediaShareService.overrideShare = (params) async {
      events.add('share');
      shareCalls.add(params);
      return const ShareResult('', ShareResultStatus.dismissed);
    };

    final results = await openReview(
      tester,
      media: _sampleMedia(
        kind: 'video',
        durationMs: 12000,
        path: '/tmp/watchdog-test/VID_SHARE_WM.mp4',
        sourcePath: '/tmp/watchdog-test/VID_SHARE_SRC.mp4',
        transcript: '二楼东北角浓烟封门，请求破拆支援',
      ),
      enqueueMediaNoteUpload: ({
        required String kind,
        required String filePath,
        String thumbPath = '',
        required String transcript,
        required int durationMs,
        required int capturedAt,
        String address = '',
        String weather = '',
        required String localMediaId,
        bool syncObservation = false,
      }) async {
        events.add('enqueue');
        enqueued.add(<String, Object?>{
          'kind': kind,
          'filePath': filePath,
          'transcript': transcript,
          'durationMs': durationMs,
          'syncObservation': syncObservation,
        });
        return MediaNoteSyncOutcome.enqueued;
      },
    );

    await tester.tap(find.text('保存并分享'));
    await _pumpAsyncAction(tester);

    expect(events, const ['pair', 'enqueue', 'share']);
    expect(enqueued.single['kind'], 'video');
    expect(enqueued.single['transcript'], '二楼东北角浓烟封门，请求破拆支援');
    expect(enqueued.single['durationMs'], 12000);
    expect(enqueued.single['syncObservation'], isTrue);
    expect(shareCalls.single.files!.single.path, '/tmp/watchdog-test/VID_SHARE_WM.mp4');
    await tester.pump();
    expect(find.text('已保存到相册，正在后台同步至火场日志'), findsOneWidget);
    await expectSavedAndPopped(
      tester,
      results,
      expected: MediaReviewOutcome.shared,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('游客或未选警情点击保存不阻塞相册导出并给出跳过日志提示', (tester) async {
    final results = await openReview(
      tester,
      enqueueMediaNoteUpload: ({
        required String kind,
        required String filePath,
        String thumbPath = '',
        required String transcript,
        required int durationMs,
        required int capturedAt,
        String address = '',
        String weather = '',
        required String localMediaId,
        bool syncObservation = false,
      }) async => MediaNoteSyncOutcome.skippedGuest,
    );

    await tester.tap(find.text('仅保存'));
    await _pumpAsyncAction(tester);

    await tester.pump();
    expect(find.text('已保存到相册（游客模式不上传至火场日志）'), findsOneWidget);
    await expectSavedAndPopped(tester, results);
    await tester.pump(const Duration(seconds: 5));
  });
}
