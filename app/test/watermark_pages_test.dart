import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/camera_page.dart';
import 'package:watchdog/pages/media_gallery_page.dart';
import 'package:watchdog/pages/media_review_page.dart';
import 'package:watchdog/pages/watermark_settings_page.dart';
import 'package:watchdog/services/local_asr_service.dart';
import 'package:watchdog/services/local_media_store.dart';
import 'package:watchdog/services/watermark_settings.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

/// 水印相机相关页面的组件测试：设置、核对、资料库与相机入口。
///
/// 约定与现有 widget 测试一致：mock 平台通道、避免真实网络/数据库，
/// 媒体库通过 [LocalMediaStore.overrideInstance] 注入内存实现。

LocalMedia _media({
  String id = 'media-1',
  String incidentId = 'incident-1',
  String kind = 'photo',
  String path = '/tmp/watchdog-test/none.jpg',
  int durationMs = 0,
  String address = '',
  String weather = '',
  String transcript = '',
  List<LocalAsrSegment> segments = const [],
  List<String> frames = const [],
  String observationId = '',
}) {
  return LocalMedia(
    id: id,
    incidentId: incidentId,
    kind: kind,
    path: path,
    durationMs: durationMs,
    capturedAt: DateTime(2026, 10, 18, 8, 39).millisecondsSinceEpoch,
    lat: null,
    lon: null,
    address: address,
    weather: weather,
    transcript: transcript,
    segments: segments,
    frames: frames,
    observationId: observationId,
  );
}

/// 内存版媒体库：记录删除、草稿与清理调用，方便断言交互确实生效。
class _FakeMediaStore extends LocalMediaStore {
  _FakeMediaStore(this.items) : super.forTesting();

  List<LocalMedia> items;
  final List<String> deletedIds = [];
  final Map<String, String> drafts = {};
  final Map<String, String> observationIds = {};
  int expiredCount = 0;
  int purgeCalls = 0;

  @override
  Future<List<LocalMedia>> listUnlinked() async => const [];

  @override
  Future<List<LocalMedia>> listForIncident(String incidentId) async =>
      items.where((item) => item.incidentId == incidentId).toList();

  @override
  Future<void> deleteById(String id) async {
    deletedIds.add(id);
    items = items.where((item) => item.id != id).toList();
  }

  @override
  Future<void> updateDerived({
    required String id,
    String? transcript,
    List<LocalAsrSegment>? segments,
    List<String>? frames,
    String? observationId,
  }) async {
    if (transcript != null) drafts[id] = transcript;
    if (observationId != null && observationId.isNotEmpty) {
      observationIds[id] = observationId;
    }
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
    return const [];
  }
}

/// 只记录写入请求的 API 客户端，避免组件测试发真实网络请求。
class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'http://127.0.0.1', incidentId: 'incident-1');

  final List<String> transcripts = [];
  bool fail = false;

  @override
  Future<void> createIncidentObservation({
    required String transcript,
    required String sourceType,
    required int capturedAt,
    String mediaRef = '',
    Map<String, Object?> structured = const {},
  }) async {
    if (fail) throw Exception('网络不可用');
    transcripts.add(transcript);
  }
}

Incident _incident({String id = 'incident-1', String? title}) {
  return Incident(
    id: id,
    number: '2026-10-18-08-39',
    title: title,
    status: 'active',
    createdAt: 1,
    lastActivityAt: 2,
  );
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(MaterialApp(theme: buildAppTheme(), home: page));
  await tester.pumpAndSettle();
}

/// 在保留视口尺寸的前提下放大字号，用于验证大字号不溢出。
Future<void> _pumpPageScaled(
  WidgetTester tester,
  Widget page, {
  double scale = 2.0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: page,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 设置页的预览卡占满默认 800×600 视口，ListView 会懒加载、下方的输入框
/// 与开关不会被构建。放大逻辑视口让整页可见，避免测试里滚动。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 让 SnackBar 的自动关闭计时器走完，避免测试结束时报遗留计时器。
Future<void> _settleSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    LocalMediaStore.overrideInstance = null;
    debugDefaultTargetPlatformOverride = null;
  });

  group('水印相机设置页', () {
    testWidgets('加载后显示三个输入框、五个显示开关与空抬头占位', (tester) async {
      _useTallViewport(tester);
      await _pumpPage(tester, const WatermarkSettingsPage());

      expect(find.text('水印相机'), findsOneWidget);
      expect(find.text('效果预览'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.text('单位抬头'), findsOneWidget);
      expect(find.text('拍摄单位'), findsOneWidget);
      expect(find.text('拍摄人'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNWidgets(5));
      expect(find.text('单位抬头（未填写）'), findsOneWidget);

      // 默认五项全开：预览包含时间、天气、地点与经纬度。
      expect(find.text('拍摄\r\n时间'), findsOneWidget);
      expect(find.text('晴 21℃ 东南风2级 湿度87%'), findsOneWidget);
      expect(find.text('衢州市 · 某某有限公司'), findsOneWidget);
      expect(find.text('东经 118°22′'), findsOneWidget);
      expect(find.text('北纬 29°0′'), findsOneWidget);
    });

    testWidgets('修改文本后预览同步更新，关闭开关后对应字段消失', (tester) async {
      _useTallViewport(tester);
      await _pumpPage(tester, const WatermarkSettingsPage());

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '浙江总队测试支队');
      await tester.enterText(fields.at(1), '通信保障分队');
      await tester.enterText(fields.at(2), '张三');
      await tester.pump();

      expect(find.text('单位抬头（未填写）'), findsNothing);
      expect(find.text('拍摄单位：通信保障分队'), findsOneWidget);
      expect(find.text('拍摄人'), findsNWidgets(2)); // 输入框标签 + 预览
      expect(find.text('张三'), findsNWidgets(2)); // 输入框 + 预览

      // 关闭「天气」与「拍摄时间」，预览中的对应行应立即移除。
      await tester.tap(find.widgetWithText(SwitchListTile, '拍摄时间'));
      await tester.tap(find.widgetWithText(SwitchListTile, '天气'));
      await tester.pump();

      expect(find.text('拍摄\r\n时间'), findsNothing);
      expect(find.text('晴 21℃ 东南风2级 湿度87%'), findsNothing);
      // 其他字段保持可见。
      expect(find.text('衢州市 · 某某有限公司'), findsOneWidget);
    });

    testWidgets('点保存写入 SharedPreferences 并弹出提示', (tester) async {
      _useTallViewport(tester);
      await _pumpPage(tester, const WatermarkSettingsPage());

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '测试支队');
      await tester.enterText(fields.at(1), '测试分队');
      await tester.enterText(fields.at(2), '李四');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('水印设置已保存，下次拍摄生效'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('watermark_settings_v1');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['unitTitle'], '测试支队');
      expect(decoded['department'], '测试分队');
      expect(decoded['actorName'], '李四');

      final reloaded = await WatermarkSettings.load();
      expect(reloaded.unitTitle, '测试支队');
      expect(reloaded.department, '测试分队');
      expect(reloaded.actorName, '李四');

      // 让 SnackBar 自动关闭，避免遗留计时器。
      await _settleSnackBar(tester);
    });
  });

  group('现场记录核对页', () {
    testWidgets('有转写文本时编辑框显示内容，并说明文件与文字的保存范围', (tester) async {
      final controller = AppController();
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(
          controller: controller,
          media: _media(transcript: '现场明火已扑灭，正在清理余火'),
        ),
      );

      expect(find.text('核对现场记录'), findsOneWidget);
      expect(find.text('现场口述（请核对后再使用）'), findsOneWidget);
      expect(find.text('现场明火已扑灭，正在清理余火'), findsOneWidget);
      expect(find.text('照片'), findsOneWidget);
      expect(find.text('原始文件只保存在本机；只有你核对后的文字会上传'), findsOneWidget);
      expect(find.text('文件只保存在本机，不会自动上传'), findsNothing);
    });

    testWidgets('长按分段时间戳会删除并给出撤销，chip 触控高度不小于 48dp', (tester) async {
      _useTallViewport(tester);
      final controller = AppController();
      addTearDown(controller.dispose);
      const segment = LocalAsrSegment(
        text: '现场有明火',
        startMs: 1000,
        endMs: 2000,
      );

      await _pumpPage(
        tester,
        MediaReviewPage(
          controller: controller,
          media: _media(
            transcript: '现场有明火 需要支援',
            segments: const [segment],
          ),
        ),
      );

      final chip = find.text('00:01  现场有明火');
      await tester.ensureVisible(chip);
      expect(
        tester.getSize(find.byKey(const Key('segment-chip-1000'))).height,
        greaterThanOrEqualTo(48),
      );

      await tester.longPress(chip);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '需要支援');
      expect(find.text('需要支援'), findsOneWidget);
      expect(find.text('已删除该片段'), findsOneWidget);

      // 撤销后原文恢复。
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(field.controller!.text, '现场有明火 需要支援');

      await _settleSnackBar(tester);
    });

    testWidgets('没有转写内容时主按钮为「仅保存」，不出现写入警情', (tester) async {
      final store = _FakeMediaStore([]);
      LocalMediaStore.overrideInstance = store;
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(controller: controller, media: _media()),
      );

      expect(find.text('仅保存'), findsOneWidget);
      expect(find.text('核对无误，写入警情'), findsNothing);
      expect(find.textContaining('写入警情'), findsNothing);

      await tester.tap(find.text('仅保存'));
      await tester.pumpAndSettle();
      expect(find.text('已保存在本机，可稍后在「现场资料」里补写口述'), findsOneWidget);

      await _settleSnackBar(tester);
    });

    testWidgets('有文字后按钮切换为写入语义', (tester) async {
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(controller: controller, media: _media()),
      );

      await tester.enterText(find.byType(TextField), '现场已设置警戒');
      await tester.pump();

      expect(find.text('核对无误，写入警情'), findsOneWidget);
      expect(find.text('仅保存'), findsNothing);
    });

    testWidgets('编辑内容在防抖后实时保存为本机草稿', (tester) async {
      final store = _FakeMediaStore([]);
      LocalMediaStore.overrideInstance = store;
      final controller = AppController();
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(controller: controller, media: _media()),
      );

      await tester.enterText(find.byType(TextField), '手动补写的口述内容');
      await tester.pump(const Duration(milliseconds: 500));

      expect(store.drafts['media-1'], '手动补写的口述内容');
    });

    testWidgets('写入前弹出确认对话框，写明目标警情与辅助问答引用', (tester) async {
      final store = _FakeMediaStore([]);
      LocalMediaStore.overrideInstance = store;
      final api = _FakeApi();
      final controller = AppController()
        ..currentIncident = _incident(title: '某小区地下车库火警')
        ..api = api;
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(
          controller: controller,
          media: _media(transcript: '现场已设置警戒'),
        ),
      );

      await tester.tap(find.text('核对无误，写入警情'));
      await tester.pumpAndSettle();

      expect(find.text('写入警情？'), findsOneWidget);
      expect(find.textContaining('某小区地下车库火警'), findsOneWidget);
      expect(find.textContaining('写入后辅助问答会引用这段口述'), findsOneWidget);

      // 取消不会提交。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.transcripts, isEmpty);

      // 确认后提交一次，按钮变为「已写入」且不可重复点击。
      await tester.tap(find.text('核对无误，写入警情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认写入'));
      await tester.pumpAndSettle();

      expect(api.transcripts, ['现场已设置警戒']);
      expect(store.observationIds['media-1'], 'media-1');
      expect(find.text('已写入'), findsOneWidget);
      final writtenButton = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('已写入'),
          matching: find.byWidgetPredicate((widget) => widget is FilledButton),
        ),
      );
      expect(writtenButton.onPressed, isNull);

      await _settleSnackBar(tester);
    });

    testWidgets('写入失败时文字仍保存为本机草稿', (tester) async {
      final store = _FakeMediaStore([]);
      LocalMediaStore.overrideInstance = store;
      final api = _FakeApi()..fail = true;
      final controller = AppController()
        ..currentIncident = _incident()
        ..api = api;
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(
          controller: controller,
          media: _media(transcript: '现场已设置警戒'),
        ),
      );

      await tester.enterText(find.byType(TextField), '现场已设置警戒，等待支援');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('核对无误，写入警情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认写入'));
      await tester.pumpAndSettle();

      expect(find.textContaining('写入失败'), findsOneWidget);
      expect(store.drafts['media-1'], '现场已设置警戒，等待支援');
      expect(find.text('已写入'), findsNothing);

      await _settleSnackBar(tester);
    });

    testWidgets('api 为空时提示文字已保存为本机草稿', (tester) async {
      final store = _FakeMediaStore([]);
      LocalMediaStore.overrideInstance = store;
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(
          controller: controller,
          media: _media(transcript: '现场已设置警戒'),
        ),
      );

      await tester.enterText(find.byType(TextField), '现场已设置警戒，等待支援');
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.api, isNull);
      await tester.tap(find.text('核对无误，写入警情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认写入'));
      await tester.pumpAndSettle();

      expect(
        find.text('未连接服务器，口述文字已保存在本机草稿，联网后可再写入'),
        findsOneWidget,
      );
      expect(store.drafts['media-1'], '现场已设置警戒，等待支援');

      await _settleSnackBar(tester);
    });

    testWidgets('frames 非空时渲染关键画面缩略图', (tester) async {
      _useTallViewport(tester);
      final controller = AppController();
      addTearDown(controller.dispose);

      await _pumpPage(
        tester,
        MediaReviewPage(
          controller: controller,
          media: _media(kind: 'video', durationMs: 8000, frames: const [
            '/tmp/watchdog-test/frame-1.jpg',
          ]),
        ),
      );

      expect(find.text('视频 8s'), findsOneWidget);
      expect(find.text('关键画面'), findsOneWidget);
      expect(find.text('播放视频'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('deriving 标志为真时显示处理进度与取消入口，完成后回到编辑框', (tester) async {
      final controller = AppController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: MediaReviewPage(
            controller: controller,
            media: _media(),
            deriving: true,
          ),
        ),
      );

      expect(find.text('正在处理…'), findsOneWidget);
      expect(find.text('识别在本机完成，不上传音频'), findsOneWidget);
      expect(find.text('取消识别'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('正在处理…'), findsNothing);
      expect(find.text('现场口述（请核对后再使用）'), findsOneWidget);
    });

    testWidgets('大字号下核对页不溢出', (tester) async {
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPageScaled(
        tester,
        MediaReviewPage(
          controller: controller,
          media: _media(
            kind: 'video',
            durationMs: 8000,
            transcript: '现场明火已扑灭，正在清理余火，无人员被困',
            segments: const [
              LocalAsrSegment(text: '现场明火已扑灭', startMs: 1000, endMs: 2000),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('视频 8s'), findsOneWidget);
    });
  });

  group('现场资料页', () {
    testWidgets('按 LocalMedia 渲染照片/录像标题、转写摘要与已写入状态', (tester) async {
      final store = _FakeMediaStore([
        _media(
          id: 'photo-1',
          transcript: '现场明火已控制',
          observationId: 'photo-1',
        ),
        _media(id: 'video-1', kind: 'video', durationMs: 12000),
      ]);
      LocalMediaStore.overrideInstance = store;

      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPage(tester, MediaGalleryPage(controller: controller));

      expect(find.text('现场资料'), findsOneWidget);
      expect(find.text('照片'), findsOneWidget);
      expect(find.text('录像 12s'), findsOneWidget);
      expect(find.text('现场明火已控制'), findsOneWidget);
      expect(find.text('未识别到口述内容'), findsOneWidget);
      expect(find.text('已写入警情'), findsOneWidget);
    });

    testWidgets('有警情但列表为空时提示还没有拍摄', (tester) async {
      LocalMediaStore.overrideInstance = _FakeMediaStore([]);
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPage(tester, MediaGalleryPage(controller: controller));

      expect(find.text('还没有拍摄现场照片或录像'), findsOneWidget);
      expect(find.text('在首页警情卡点「水印相机」拍摄，文件会保存在这台设备上'), findsOneWidget);
    });

    testWidgets('没有当前警情时提示先加入警情', (tester) async {
      LocalMediaStore.overrideInstance = _FakeMediaStore([]);
      final guest = AppController();
      addTearDown(guest.dispose);

      await _pumpPage(tester, MediaGalleryPage(controller: guest));

      expect(find.text('还没有当前警情'), findsOneWidget);
      expect(find.text('先加入或新建警情，拍摄的现场资料会归到当前警情下'), findsOneWidget);
      expect(find.text('还没有拍摄现场照片或录像'), findsNothing);
    });

    testWidgets('菜单删除需要二次确认，取消不会删除', (tester) async {
      final store = _FakeMediaStore([_media(id: 'photo-1')]);
      LocalMediaStore.overrideInstance = store;
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPage(tester, MediaGalleryPage(controller: controller));

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.text('删除这条现场资料？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.deletedIds, isEmpty);
      expect(find.text('照片'), findsOneWidget);

      // 再次打开菜单并确认删除。
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(store.deletedIds, ['photo-1']);
      expect(find.text('照片'), findsNothing);
      expect(find.text('还没有拍摄现场照片或录像'), findsOneWidget);
    });

    testWidgets('清理过期文件前二次确认并显示将删除数量', (tester) async {
      final store = _FakeMediaStore([_media(id: 'photo-1')])..expiredCount = 3;
      LocalMediaStore.overrideInstance = store;
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPage(tester, MediaGalleryPage(controller: controller));

      await tester.tap(find.byIcon(Icons.cleaning_services_outlined));
      await tester.pumpAndSettle();

      expect(find.text('清理过期文件？'), findsOneWidget);
      expect(find.textContaining('将删除 3 个超过 30 天的媒体文件'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.purgeCalls, 0);

      await tester.tap(find.byIcon(Icons.cleaning_services_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清理'));
      await tester.pumpAndSettle();

      expect(store.purgeCalls, 1);
      await _settleSnackBar(tester);
    });

    testWidgets('大字号下资料页不溢出', (tester) async {
      final store = _FakeMediaStore([
        _media(
          id: 'photo-1',
          transcript: '现场明火已控制，正在清理余火',
          observationId: 'photo-1',
        ),
        _media(id: 'video-1', kind: 'video', durationMs: 12000),
      ]);
      LocalMediaStore.overrideInstance = store;
      final controller = AppController()..currentIncident = _incident();
      addTearDown(controller.dispose);

      await _pumpPageScaled(tester, MediaGalleryPage(controller: controller));

      expect(tester.takeException(), isNull);
      expect(find.text('现场资料'), findsOneWidget);
    });
  });

  group('相机页', () {
    const eventChannel = MethodChannel('watchdog/camera_events');
    const cameraChannel = MethodChannel('watchdog/camera');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, (call) async => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cameraChannel, null);
    });

    testWidgets('非 Android 平台显示不支持提示', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final controller = AppController();
      addTearDown(controller.dispose);

      await _pumpPage(tester, CameraPage(controller: controller));

      expect(find.text('当前平台暂不支持水印相机'), findsOneWidget);

      // 测试框架会在测试体结束时检查调试变量必须已复原。
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('相机权限被拒时显示授权引导页', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cameraChannel, (call) async {
            if (call.method == 'requestPermissions') return false;
            return null;
          });
      final controller = AppController();
      addTearDown(controller.dispose);

      await _pumpPage(tester, CameraPage(controller: controller));

      expect(find.text('需要相机权限才能拍摄现场资料'), findsOneWidget);
      expect(find.text('拍摄内容只保存在本机，不会自动上传'), findsOneWidget);
      expect(find.text('重新授权'), findsOneWidget);

      // 重新授权仍被拒绝时停留在引导页。
      await tester.tap(find.text('重新授权'));
      await tester.pumpAndSettle();
      expect(find.text('需要相机权限才能拍摄现场资料'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
