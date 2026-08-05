import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/board_page.dart';
import 'package:watchdog/pages/entry_detail_page.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/pages/same_name_dialog.dart';
import 'package:watchdog/pages/settings_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

import 'package:watchdog/main.dart' show WatchDogApp;

/// 测试专用 Controller：拦截网络调用，本地模拟数据
class _FakeController extends AppController {
  _FakeController({List<Entry> entries = const []}) : super() {
    this.entries = entries;
  }
  final exited = <String>[];

  @override
  Future<void> markExited(String id) async {
    exited.add(id);
    entries = entries
        .map((e) => e.id == id ? _exitedCopy(e) : e)
        .toList();
    notifyListeners();
  }

  static Entry _exitedCopy(Entry e) => Entry(
        id: e.id,
        name: e.name,
        pressureMpa: e.pressureMpa,
        durationMin: e.durationMin,
        entryAt: e.entryAt,
        exitAt: e.exitAt,
        exitedAt: DateTime.now().millisecondsSinceEpoch,
        source: e.source,
        rawText: e.rawText,
      );
}

Entry _entry({
  required String name,
  required int remainingMin,
  double pressureMpa = 20,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final duration = 40;
  final remainingMs = remainingMin * 60000;
  return Entry(
    id: 'e-$name',
    name: name,
    pressureMpa: pressureMpa,
    durationMin: duration,
    entryAt: now - (duration * 60 - remainingMin) * 60000,
    exitAt: now + remainingMs,
    source: 'voice',
    rawText: '张三，20兆帕',
  );
}

/// 测试专用 ApiClient：固定返回 张伟+李娜 的转写/解析结果
class _FakeApi extends ApiClient {
  _FakeApi({this.multiPressure = true}) : super(baseUrl: 'http://test', sceneCode: 'test');
  final bool multiPressure;
  final created = <String>[];

  @override
  Future<String> transcribe(Uint8List audioBytes) async => '张伟20兆帕，李娜22兆帕';

  @override
  Future<ParseResult> parse(String text) async => ParseResult(
        action: 'enter',
        people: [
          ParsePerson(name: '张伟', pressureMpa: multiPressure ? 20 : null),
          ParsePerson(name: '李娜', pressureMpa: multiPressure ? 22 : null),
        ],
      );

  @override
  Future<Entry> createEntry({
    required String name,
    required double pressureMpa,
    String source = 'voice',
    String? rawText,
    bool force = false,
  }) async {
    created.add(name);
    final now = DateTime.now().millisecondsSinceEpoch;
    return Entry(
      id: 'e-$name',
      name: name,
      pressureMpa: pressureMpa,
      durationMin: (6.8 * pressureMpa * 10 / 40).round(),
      entryAt: now,
      exitAt: now + (6.8 * pressureMpa * 10 / 40 * 60000).round(),
      source: source,
      rawText: rawText,
    );
  }
}

/// 测试专用 AudioService：无真实录音
class _FakeAudio extends AudioService {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {}

  @override
  Stream<double> amplitudeStream() => const Stream.empty();

  @override
  Future<Uint8List> stop() async => Uint8List(0);

  @override
  Future<void> dispose() async {}
}

Future<void> _pumpBoard(WidgetTester tester, List<Entry> entries) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: BoardPage(controller: _FakeController(entries: entries), onGoVoice: () {}),
    ),
  ));
  await tester.pump();
}

void main() {
  group('同名已在场确认弹窗', () {
    testWidgets('弹窗说明并支持合并 / 另建记录 / 取消', (tester) async {
      final existing = _entry(name: '张伟', remainingMin: 20);
      SameNameChoice? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showSameNameDialog(ctx, existing: existing, pressureMpa: 15, durationMin: 26);
                },
                child: const Text('触发'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      expect(find.text('该人员已在火场内'), findsOneWidget);
      expect(find.textContaining('尚未出场'), findsOneWidget);

      await tester.tap(find.text('同一人，按新压力重新倒计时'));
      await tester.pumpAndSettle();
      expect(result, SameNameChoice.merge);
      expect(find.text('该人员已在火场内'), findsNothing);
    });

    testWidgets('另建记录与取消分支', (tester) async {
      final existing = _entry(name: '李娜', remainingMin: 10);
      final ctxKey = GlobalKey();
      SameNameChoice? result;
      Future<void> open() async {
        result = await showSameNameDialog(
          ctxKey.currentContext!,
          existing: existing,
          pressureMpa: 20,
          durationMin: 34,
        );
      }

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            key: ctxKey,
            builder: (ctx) => Center(child: ElevatedButton(onPressed: open, child: const Text('触发'))),
          ),
        ),
      ));
      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另有同名人员，另建记录'));
      await tester.pumpAndSettle();
      expect(result, SameNameChoice.force);

      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  group('CountdownText 格式', () {
    testWidgets('MM:SS 常规显示', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CountdownText(ms: 5 * 60000 + 34000)),
      ));
      expect(find.text('05:34'), findsOneWidget);
    });

    testWidgets('超过 60 分钟显示 H:MM:SS', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CountdownText(ms: 61 * 60000 + 7000)),
      ));
      expect(find.text('1:01:07'), findsOneWidget);
    });

    testWidgets('超时显示替代文案', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CountdownText(ms: -1000, timeoutText: '已超时')),
      ));
      expect(find.text('已超时'), findsOneWidget);
    });
  });

  group('BoardPage 概览横幅', () {
    testWidgets('统计在场人数 / 需关注 / 最早到期', (tester) async {
      await _pumpBoard(tester, [
        _entry(name: '张伟', remainingMin: 30),
        _entry(name: '李娜', remainingMin: 8),
        _entry(name: '王强', remainingMin: 3),
      ]);
      // 在场 3 人
      expect(find.text('3'), findsWidgets);
      // 需关注 = 注意1 + 报警1 = 2
      expect(find.text('2'), findsWidgets);
      // 最早到期约 03:00（时间流逝后 02:5X~03:00 波动）
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && RegExp(r'^0[23]:\d{2}$').hasMatch(w.data ?? ''),
        ),
        findsWidgets,
      );
    });

    testWidgets('最早到期为空时显示 --', (tester) async {
      await _pumpBoard(tester, []);
      expect(find.text('--'), findsOneWidget);
    });
  });

  group('EntryDetailPage 详情页', () {
    testWidgets('展示倒计时、气瓶信息与出场按钮', (tester) async {
      final c = _FakeController(entries: [_entry(name: '张伟', remainingMin: 30, pressureMpa: 20)]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: EntryDetailPage(controller: c, entryId: 'e-张伟'),
      ));
      await tester.pump();
      expect(find.text('张伟'), findsWidgets);
      expect(find.text('20.0 MPa'), findsNWidgets(2)); // 倒计时卡片 + 气瓶信息
      expect(find.text('40 分钟上限'), findsOneWidget);
      expect(find.textContaining('确认「张伟」已出火场'), findsOneWidget);
      expect(find.text('原始语音转写'), findsOneWidget);
      expect(find.text('张三，20兆帕'), findsOneWidget);
    });

    testWidgets('确认出火场需二次确认，确认后登记并返回', (tester) async {
      final c = _FakeController(entries: [_entry(name: '李娜', remainingMin: 30)]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => EntryDetailPage(controller: c, entryId: 'e-李娜'),
                  ),
                ),
                child: const Text('打开详情'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('确认「李娜」已出火场'));
      await tester.pumpAndSettle();
      // 二次确认对话框
      expect(find.text('确认「李娜」已出火场？'), findsOneWidget);
      await tester.tap(find.text('确认出火场'));
      await tester.pumpAndSettle();
      expect(c.exited, ['e-李娜']);
      // 登记完成后返回上一页
      expect(find.text('打开详情'), findsOneWidget);
    });

    testWidgets('取消二次确认不执行出场', (tester) async {
      final c = _FakeController(entries: [_entry(name: '王强', remainingMin: 30)]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: EntryDetailPage(controller: c, entryId: 'e-王强'),
      ));
      await tester.pump();
      await tester.tap(find.textContaining('确认「王强」已出火场'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.exited, isEmpty);
      expect(find.textContaining('确认「王强」已出火场'), findsOneWidget);
    });

    testWidgets('报警人员显示报警状态横幅与红色倒计时', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: EntryDetailPage(
          controller: _FakeController(entries: [_entry(name: '赵磊', remainingMin: 3)]),
          entryId: 'e-赵磊',
        ),
      ));
      await tester.pump();
      expect(find.text('报警'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && RegExp(r'^0[23]:[0-5][0-9]$').hasMatch(w.data ?? ''),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('记录不存在显示失效视图', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: EntryDetailPage(controller: _FakeController(), entryId: 'missing'),
      ));
      await tester.pump();
      expect(find.text('该记录已不存在'), findsOneWidget);
      expect(find.text('返回看板'), findsOneWidget);
    });
  });

  group('SettingsPage', () {
    testWidgets('渲染四个分区与保存按钮', (tester) async {
      final c = _FakeController();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: SettingsPage(controller: c)),
      ));
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      expect(find.text('服务端'), findsOneWidget);
      expect(find.text('计算参数'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('名单与热词'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('屏幕常亮'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('保存设置'), 200, scrollable: list);
      expect(find.text('提醒方式'), findsOneWidget);
    });
  });

  group('HomePage 多人逐人确认', () {
    testWidgets('识别多人后先显示第 1 人，确认后前进到第 2 人，全部确认后清空', (tester) async {
      final api = _FakeApi();
      final c = _FakeController()..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      // 模拟说话并松手 → 转写 + 解析
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();

      // 逐人确认卡片：第 1 / 2 人 + 姓名与压力已回填
      expect(find.text('逐人确认：第 1 / 2 人'), findsOneWidget);
      expect(find.text('1.张伟'), findsOneWidget);
      expect(find.text('2.李娜'), findsOneWidget);
      expect(find.text('确认「张伟」进入火场'), findsOneWidget);
      expect(find.text('可用时间 34 分钟（6.8L × 20.0 MPa ÷ 40.0L/min）'), findsOneWidget);

      // 确认第 1 人 → 前进到第 2 人
      await tester.tap(find.text('确认「张伟」进入火场'));
      await tester.pumpAndSettle();
      expect(find.text('逐人确认：第 2 / 2 人'), findsOneWidget);
      expect(find.text('确认「李娜」进入火场'), findsOneWidget);
      expect(api.created, ['张伟']);

      // 确认第 2 人 → 表单清空回到初始状态
      await tester.tap(find.text('确认「李娜」进入火场'));
      await tester.pumpAndSettle();
      expect(api.created, ['张伟', '李娜']);
      expect(find.text('逐人确认：第 2 / 2 人'), findsNothing);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });

    testWidgets('缺压力时内联报错不遮挡确认卡片，补充后可继续', (tester) async {
      final api = _FakeApi(multiPressure: false);
      final c = _FakeController()..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();

      expect(find.text('逐人确认：第 1 / 2 人'), findsOneWidget);
      await tester.tap(find.text('确认「张伟」进入火场'));
      await tester.pump();
      // 内联错误仍在确认卡片内，可编辑补填
      expect(find.text('「张伟」缺少气瓶压力'), findsOneWidget);
      expect(find.text('确认「张伟」进入火场'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '20');
      await tester.pump();
      expect(find.text('「张伟」缺少气瓶压力'), findsNothing);
    });

    testWidgets('移除当前人员后前进；全部移除回到初始', (tester) async {
      final api = _FakeApi();
      final c = _FakeController()..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();

      await tester.tap(find.text('移除该人员'));
      await tester.pump();
      // 剩 1 人时回到单人确认卡片
      expect(find.text('确认进入火场，开始倒计时'), findsOneWidget);
      expect(find.text('确认「李娜」进入火场'), findsNothing);

      await tester.tap(find.text('确认进入火场，开始倒计时'));
      await tester.pumpAndSettle();
      expect(api.created, ['李娜']);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });
  });

  group('main.dart 导航', () {
    testWidgets('默认进入看板，底部三入口存在', (tester) async {
      await tester.pumpWidget(const WatchDogApp());
      await tester.pump();
      expect(find.text('火场安全管控看板'), findsOneWidget);
      expect(find.text('看板'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(find.byType(VoiceButton), findsOneWidget);
    });

    testWidgets('点击设置可切换页面', (tester) async {
      await tester.pumpWidget(const WatchDogApp());
      await tester.pump();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('服务端'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('保存设置'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('保存设置'), findsOneWidget);
    });
  });
}
