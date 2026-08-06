import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/board_page.dart';
import 'package:watchdog/pages/entry_detail_page.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/pages/notes_page.dart';
import 'package:watchdog/pages/op_log_page.dart';
import 'package:watchdog/pages/same_name_dialog.dart';
import 'package:watchdog/pages/settings_page.dart';
import 'package:watchdog/pages/stats_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/op_log_service.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

import 'package:watchdog/main.dart' show WatchDogApp;
import 'package:watchdog/pages/report_pressure_sheet.dart';

/// 测试专用 Controller：拦截网络调用，本地模拟数据
class _FakeController extends AppController {
  _FakeController({
    List<Entry> entries = const [],
    List<Firefighter> firefighters = const [],
    List<Note> notes = const [],
  }) : super() {
    this.entries = entries;
    this.firefighters = firefighters;
    this.notes = notes;
  }
  final exited = <String>[];
  final reported = <double>[];

  @override
  void startSync() {} // 测试环境不启动轮询定时器（否则每秒刷新导致 pumpAndSettle 无法收敛）

  @override
  Future<void> markExited(String id, {String? opId}) async {
    exited.add(id);
    entries = entries
        .map((e) => e.id == id ? _exitedCopy(e) : e)
        .toList();
    notifyListeners();
  }

  @override
  Future<Entry> updatePressure({required String id, required double pressureMpa, String? opId}) async {
    reported.add(pressureMpa);
    return entries.firstWhere((e) => e.id == id);
  }

  @override
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = Note(
      id: 'n-${notes.length}',
      text: text,
      category: category ?? NoteCategory.fromText(text),
      createdAt: now,
      updatedAt: now,
    );
    notes = [note, ...notes];
    notifyListeners();
    return note;
  }

  @override
  Future<Note> updateNote(String id, {String? text, String? category}) async {
    final old = notes.firstWhere((n) => n.id == id);
    final updated = Note(
      id: id,
      text: text ?? old.text,
      category: category ?? old.category,
      createdAt: old.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    notes = notes.map((n) => n.id == id ? updated : n).toList();
    notifyListeners();
    return updated;
  }

  @override
  Future<void> deleteNote(String id) async {
    notes = notes.where((n) => n.id != id).toList();
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
  double? consumptionActualLpm,
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
    consumptionActualLpm: consumptionActualLpm,
  );
}

/// 测试专用 ApiClient：固定返回 张伟+李娜 的转写/解析结果
class _FakeApi extends ApiClient {
  _FakeApi({
    this.multiPressure = true,
    this.rounds = const [],
    this.exitOnCall = 0,
    this.exitAllOnCall = 0,
    this.noteOnCall = 0,
    this.transcribeText,
  }) : super(baseUrl: 'http://test', sceneCode: 'test');
  final bool multiPressure;

  /// 第 2、3... 次解析时返回的追加轮次（分批录入测试用）
  final List<List<ParsePerson>> rounds;

  /// 第 N 次解析返回出场指令（1 起算，0 表示不触发）
  final int exitOnCall;

  /// 第 N 次解析返回全员离场指令（people 为空，1 起算，0 表示不触发）
  final int exitAllOnCall;

  /// 第 N 次解析返回 unknown（非报数内容，1 起算，0 表示不触发）
  final int noteOnCall;

  /// 自定义转写文本（默认 张伟+李娜）
  final String? transcribeText;
  final created = <String>[];
  int _parseCalls = 0;

  @override
  Future<String> transcribe(Uint8List audioBytes, {String? opId}) async =>
      transcribeText ?? '张伟20兆帕，李娜22兆帕';

  @override
  Future<ParseResult> parse(String text, {String? opId}) async {
    final i = _parseCalls++;
    if (noteOnCall > 0 && i + 1 == noteOnCall) {
      return ParseResult(action: 'unknown', people: []);
    }
    if (exitAllOnCall > 0 && i + 1 == exitAllOnCall) {
      return ParseResult(action: 'exit', people: []);
    }
    if (exitOnCall > 0 && i + 1 == exitOnCall) {
      return ParseResult(action: 'exit', people: [ParsePerson(name: '张伟')]);
    }
    if (i >= 1 && i - 1 < rounds.length) {
      return ParseResult(action: 'enter', people: rounds[i - 1]);
    }
    return ParseResult(
      action: 'enter',
      people: [
        ParsePerson(name: '张伟', pressureMpa: multiPressure ? 20 : null),
        ParsePerson(name: '李娜', pressureMpa: multiPressure ? 22 : null),
      ],
    );
  }

  @override
  Future<Entry> createEntry({
    required String name,
    required double pressureMpa,
    String source = 'voice',
    String? rawText,
    bool force = false,
    double? volumeL,
    double? consumptionLpm,
    String? opId,
  }) async {
    created.add(name);
    final now = DateTime.now().millisecondsSinceEpoch;
    return Entry(
      id: 'e-$name',
      name: name,
      pressureMpa: pressureMpa,
      durationMin: ((volumeL ?? 6.8) * pressureMpa * 10 / 40).round(),
      entryAt: now,
      exitAt: now + ((volumeL ?? 6.8) * pressureMpa * 10 / 40 * 60000).round(),
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
  // 测试环境无 Android 原生响应：mock 屏幕常亮通道，避免保存链路挂起/遗留定时器
  const screenChannel = MethodChannel('watchdog/screen');
  TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
      .setMockMethodCallHandler(screenChannel, (call) async => null);

  group('同名已在场确认弹窗', () {
    testWidgets('弹窗说明并支持合并 / 另建记录 / 取消', (tester) async {
      final existing = _entry(name: '张伟', remainingMin: 20);
      SameNameChoice? result;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
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
        theme: buildAppTheme(),
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

    testWidgets('有危险人员时显示高优先级提示条', (tester) async {
      await _pumpBoard(tester, [
        _entry(name: '张伟', remainingMin: 30),
        _entry(name: '李娜', remainingMin: 8),
        _entry(name: '王强', remainingMin: 3),
      ]);
      expect(
        find.textContaining('2 人需要关注 · 最早到期'),
        findsOneWidget,
      );
    });

    testWidgets('无危险人员时不显示提示条', (tester) async {
      await _pumpBoard(tester, [_entry(name: '张伟', remainingMin: 30)]);
      expect(find.textContaining('人需要关注'), findsNothing);
    });

    testWidgets('危险等级排序：报警在前、注意在后、同等级按剩余时间升序', (tester) async {
      await _pumpBoard(tester, [
        _entry(name: '安全甲', remainingMin: 40),
        _entry(name: '注意乙', remainingMin: 9),
        _entry(name: '注意丙', remainingMin: 7),
        _entry(name: '报警丁', remainingMin: 4),
      ]);
      // 报警丁(alarm) → 注意丙(warn, 7min) → 注意乙(warn, 9min)：危险等级优先，同级按剩余时间升序
      final yNames = [for (final n in ['报警丁', '注意丙', '注意乙']) tester.getTopLeft(find.text(n)).dy];
      expect(yNames[0] < yNames[1], isTrue);
      expect(yNames[1] < yNames[2], isTrue);
      // 安全卡片排在最后（列表外需滚动可见）
      await tester.scrollUntilVisible(find.text('安全甲'), 120);
      expect(find.text('安全甲'), findsOneWidget);
    });
  });

  group('更新压力（动态耗气率）', () {
    testWidgets('卡片只保留姓名/状态/倒计时/更新压力，次级信息移出', (tester) async {
      final c = _FakeController(entries: [
        _entry(name: '张伟', remainingMin: 20, pressureMpa: 20, consumptionActualLpm: 40.8),
      ]);
      await _pumpBoard(tester, c.entries);
      expect(find.text('更新压力'), findsOneWidget);
      expect(find.text('张伟'), findsOneWidget);
      expect(find.text('剩余时间'), findsOneWidget);
      expect(find.text('持续时长'), findsOneWidget);
      // 次级信息不再出现在卡片首层
      expect(find.textContaining('实测'), findsNothing);
      expect(find.textContaining('MPa'), findsNothing);
      expect(find.textContaining('分钟上限'), findsNothing);
      expect(find.textContaining('已进场'), findsNothing);
      // 状态徽章与更新压力按钮等高对齐
      final badgeH = tester.getSize(find.byType(StatusBadge)).height;
      final btnH = tester
          .getSize(find.ancestor(of: find.text('更新压力'), matching: find.byType(Material)).first)
          .height;
      expect(badgeH, btnH);
      expect(btnH, 44.0);
    });

    testWidgets('ReportPressureSheet 档位 3MPa 步进、禁用高于当前压力、点选提交', (tester) async {
      final c = _FakeController(entries: [_entry(name: '李娜', remainingMin: 20, pressureMpa: 20)]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ReportPressureSheet(controller: c, entry: c.entries.first),
        ),
      ));
      // 档位齐全：30 到 6，每档差 3
      for (final lv in [30, 27, 24, 21, 18, 15, 12, 9, 6]) {
        expect(find.text('$lv'), findsOneWidget, reason: '档位 $lv 应存在');
      }
      // 未选中时确认按钮禁用态文案
      expect(find.text('选择压力档位'), findsOneWidget);
      // 点选禁用档位（30 > 当前 20）无效
      await tester.tap(find.text('30'));
      await tester.pump();
      expect(find.text('选择压力档位'), findsOneWidget);
      // 点选 15 后确认提交
      await tester.tap(find.text('15'));
      await tester.pump();
      expect(find.text('确认更新 15 MPa'), findsOneWidget);
      await tester.tap(find.text('确认更新 15 MPa'));
      await tester.pumpAndSettle();
      expect(c.reported, [15.0]);
    });

    testWidgets('手动输入压力值可直接提交，与档位互斥', (tester) async {
      final c = _FakeController(entries: [_entry(name: '李娜', remainingMin: 20, pressureMpa: 20)]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ReportPressureSheet(controller: c, entry: c.entries.first),
        ),
      ));
      // 输入 13.5 → 提交按钮启用并显示该值
      await tester.enterText(find.byType(TextField), '13.5');
      await tester.pump();
      expect(find.text('确认更新 13.5 MPa'), findsOneWidget);
      // 档位互斥：手动输入后点档位 9，文本框被清空、档位生效
      await tester.tap(find.text('9'));
      await tester.pump();
      expect(find.text('确认更新 9 MPa'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      await tester.tap(find.text('确认更新 9 MPa'));
      await tester.pumpAndSettle();
      expect(c.reported, [9.0]);
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
    testWidgets('渲染各分区，无保存按钮', (tester) async {
      final c = _FakeController();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: SettingsPage(controller: c)),
      ));
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      expect(find.text('服务端'), findsOneWidget);
      expect(find.text('计算参数'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('屏幕常亮'), 200, scrollable: list);
      expect(find.text('提醒方式'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('名单与热词'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('操作日志'), 200, scrollable: list);
      expect(find.text('保存设置'), findsNothing);
    });

    testWidgets('修改文本框后失焦即自动保存', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = _FakeController();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: SettingsPage(controller: c)),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '消耗率'), '55');
      // 模拟失焦（真实设备点击空白处/收起键盘）
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(await Settings.consumptionLpm, 55);
    });

    testWidgets('切换开关立即保存', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = _FakeController();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: SettingsPage(controller: c)),
      ));
      await tester.pumpAndSettle();
      // 最后一个开关 = 屏幕常亮（SwitchListTile 无 onTap，需直接点 Switch）
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('屏幕常亮'), 200, scrollable: list);
      await tester.pump();
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(await Settings.keepScreenOn, isFalse);
    });

    testWidgets('操作日志入口可进入日志页', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = _FakeController();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: SettingsPage(controller: c)),
      ));
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('操作日志'), 200, scrollable: list);
      await tester.tap(find.text('语音录入全流程记录'));
      await tester.pumpAndSettle();
      expect(find.byType(OpLogPage), findsOneWidget);
      expect(find.text('同步到服务器'), findsOneWidget);
    });
  });

  group('OpLogPage 操作日志', () {
    testWidgets('按操作分组展示步骤，可展开查看与切换同步开关', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final svc = OpLogService.instance;
      await svc.init();
      await svc.setSyncEnabled(true);
      await svc.clearLocal();
      svc.record('op-test-1', 'record_start', '开始录音');
      svc.record('op-test-1', 'transcribe_ok', '转写成功', data: {'text': '张伟，20兆帕'});
      svc.record('op-test-1', 'op_end', '本次操作结束', data: {'outcome': 'enter_ok'});
      svc.record('op-test-2', 'record_start', '开始录音');
      svc.record('op-test-2', 'transcribe_err', '转写失败: 服务器错误', level: 'error');
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: OpLogPage(controller: _FakeController()),
      ));
      await tester.pumpAndSettle();

      // 最新操作在前；步骤默认折叠（元素存在但不可命中）
      expect(find.text('转写失败: 服务器错误'), findsWidgets);
      expect(find.text('进场登记完成'), findsOneWidget);
      expect(find.text('同步到服务器'), findsOneWidget);
      expect(find.text('transcribe_err').hitTestable(), findsNothing);

      // 展开第一组（最新 op-test-2）查看步骤
      await tester.tap(find.text('转写失败: 服务器错误').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('transcribe_err').hitTestable(), findsOneWidget);
      expect(find.text('record_start').hitTestable(), findsOneWidget);

      // 展开 op-test-1 查看数据
      await tester.tap(find.text('进场登记完成'));
      await tester.pumpAndSettle();
      expect(find.text('text: 张伟，20兆帕').hitTestable(), findsOneWidget);

      // 关闭同步开关
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(svc.syncEnabled, isFalse);
      expect(find.text('已关闭，仅保存在本机'), findsOneWidget);
    });
  });

  group('HomePage 多人一次性确认', () {
    testWidgets('识别多人后平铺全部人员，一次确认全部进场', (tester) async {
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

      // 多人名单卡片：两人编辑器全部可见 + 一个总确认按钮
      expect(find.text('确认名单（2 人）：请下滑核对后一次性确认'), findsOneWidget);
      expect(find.text('1.张伟'), findsNothing); // 序号徽标为圆圈数字，无文字前缀
      expect(find.text('全部确认进入火场（2 人）'), findsOneWidget);
      expect(find.text('可用时间 34 分钟'), findsWidgets);
      expect(find.text('容量'), findsWidgets);

      // 点一次确认 → 两人全部提交（按钮在滚动卡片底部，先滚到可见）
      final confirmBtn = find.text('全部确认进入火场（2 人）');
      await tester.ensureVisible(confirmBtn);
      await tester.pump();
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();
      expect(api.created, ['张伟', '李娜']);
      expect(find.text('全部确认进入火场（2 人）'), findsNothing);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });

    testWidgets('缺压力时一次列出全部错误，补充后可一次性通过', (tester) async {
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

      final confirmBtn = find.text('全部确认进入火场（2 人）');
      await tester.ensureVisible(confirmBtn);
      await tester.pump();
      await tester.tap(confirmBtn);
      await tester.pump();
      // 两人的缺压力错误同时列出
      expect(find.textContaining('「张伟」缺少气瓶压力'), findsOneWidget);
      expect(find.textContaining('「李娜」缺少气瓶压力'), findsOneWidget);
      expect(api.created, isEmpty);
      expect(confirmBtn, findsOneWidget);

      // 依次补填两个压力输入框后再次确认
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '20');
      await tester.enterText(fields.at(3), '22');
      await tester.pump();
      expect(find.textContaining('缺少气瓶压力'), findsNothing);
      await tester.ensureVisible(confirmBtn);
      await tester.pump();
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();
      expect(api.created, ['张伟', '李娜']);
    });

    testWidgets('逐行移除人员后回到单人确认；全部移除回到初始', (tester) async {
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

      // 移除第 1 人（张伟）
      await tester.tap(find.text('移除该人员').first);
      await tester.pump();
      // 剩 1 人时回到单人确认卡片
      expect(find.text('确认进入火场，开始倒计时'), findsOneWidget);
      expect(find.text('全部确认进入火场（2 人）'), findsNothing);

      await tester.tap(find.text('确认进入火场，开始倒计时'));
      await tester.pumpAndSettle();
      expect(api.created, ['李娜']);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });

    testWidgets('再次录音保留已录入人员并去重追加，可统一确认', (tester) async {
      final api = _FakeApi(rounds: [
        [ParsePerson(name: '张伟', pressureMpa: 15), ParsePerson(name: '王强', pressureMpa: 24)],
      ]);
      final c = _FakeController()..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();
      expect(find.text('确认名单（2 人）：请下滑核对后一次性确认'), findsOneWidget);

      // 第二轮：张伟同名更正压力（15），王强追加 → 名单共 3 人
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();
      expect(find.text('确认名单（3 人）：请下滑核对后一次性确认'), findsOneWidget);
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(1)).controller!.text, '15.0');

      // 一次确认全部进场
      final confirmBtn = find.text('全部确认进入火场（3 人）');
      await tester.ensureVisible(confirmBtn);
      await tester.pump();
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();
      expect(api.created, ['张伟', '李娜', '王强']);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });

    testWidgets('出场指令不清空待确认名单，可从空闲态回到确认页', (tester) async {
      final api = _FakeApi(exitOnCall: 2);
      final c = _FakeController()..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      // 第一轮：张伟+李娜 待确认
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();
      expect(find.text('确认名单（2 人）：请下滑核对后一次性确认'), findsOneWidget);
      // 第二轮说出场指令（张伟不在场 → 提示未找到，不销毁名单）
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();
      expect(find.textContaining('未找到在场人员'), findsOneWidget);
      await tester.tap(find.text('返回确认'));
      await tester.pump();
      expect(find.text('确认名单（2 人）：请下滑核对后一次性确认'), findsOneWidget);
    });

    testWidgets('非名单内姓名姓名栏留空并提示手动补全', (tester) async {
      final api = _FakeApi();
      final c = _FakeController(firefighters: [Firefighter(id: '1', name: '张伟')])..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();

      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(0)).controller!.text, '张伟'); // 名单内姓名保留
      expect(tester.widget<TextField>(fields.at(3)).controller!.text, ''); // 李娜不在名单 → 姓名栏空白
      expect(find.textContaining('「李娜」不在名单内'), findsOneWidget);

      // 手动补全姓名后可正常确认
      await tester.enterText(fields.at(3), '李娜');
      await tester.pump();
      final confirmBtn = find.text('全部确认进入火场（2 人）');
      await tester.ensureVisible(confirmBtn);
      await tester.pump();
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();
      expect(api.created, ['张伟', '李娜']);
    });

    testWidgets('全员离场指令需弹框确认，确认后全部登记离场', (tester) async {
      final api = _FakeApi(exitAllOnCall: 1);
      final c = _FakeController(entries: [
        _entry(name: '张伟', remainingMin: 20),
        _entry(name: '李娜', remainingMin: 10),
      ])
        ..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      // finishRecording 内部会等待弹框确认，故不 await（由后续点击弹框按钮完成）
      unawaited(state.finishRecording());
      await tester.pumpAndSettle();
      expect(find.text('全员离场确认'), findsOneWidget);
      expect(find.textContaining('当前在场 2 人'), findsOneWidget);
      await tester.tap(find.text('确认全员离场'));
      await tester.pumpAndSettle();
      expect(c.exited, ['e-张伟', 'e-李娜']);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });

    testWidgets('取消全员离场不登记出场', (tester) async {
      final api = _FakeApi(exitAllOnCall: 1);
      final c = _FakeController(entries: [_entry(name: '张伟', remainingMin: 20)])..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      unawaited(state.finishRecording());
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.exited, isEmpty);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });

    testWidgets('语音提到钢瓶容积时录入页容积字段随之更新', (tester) async {
      final api = _FakeApi(transcribeText: '张伟20兆帕，李娜22兆帕，钢瓶9升');
      final c = _FakeController()..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();
      final fields = find.byType(TextField);
      // 每人 3 个输入框：姓名/压力/容积
      expect(tester.widget<TextField>(fields.at(2)).controller!.text, '9.0');
      expect(tester.widget<TextField>(fields.at(5)).controller!.text, '9.0');
    });

    testWidgets('非报数语音（unknown）自动记入火场日志并回到空闲态', (tester) async {
      final api = _FakeApi(noteOnCall: 1);
      final c = _FakeController()..api = api;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: HomePage(controller: c, audioService: _FakeAudio())),
      ));
      final state = tester.state<HomePageState>(find.byType(HomePage));
      await state.beginRecording();
      await state.finishRecording();
      await tester.pump();
      // 自动记入日志，分类按关键词识别（无关键词 → 其他）
      expect(c.notes.single.text, '张伟20兆帕，李娜22兆帕');
      expect(c.notes.single.category, NoteCategory.other);
      // 提示 + 回到空闲态
      expect(find.text('已记入火场日志'), findsOneWidget);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });

    testWidgets('确认页「转为日志记录」兜底按钮生效', (tester) async {
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
      // 确认页出现"转为日志记录"按钮
      final saveAsNote = find.text('转为日志记录');
      await tester.ensureVisible(saveAsNote);
      await tester.pump();
      await tester.tap(saveAsNote);
      await tester.pumpAndSettle();
      expect(c.notes.single.text, '张伟20兆帕，李娜22兆帕');
      expect(c.notes.single.category, NoteCategory.other);
      // 名单未提交（api.created 为空）且回到空闲态
      expect(api.created, isEmpty);
      expect(find.text('按住下方按钮说话'), findsOneWidget);
    });
  });

  group('NotesPage 火场日志', () {
    testWidgets('时间线渲染分类标签与内容，分类筛选生效', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final c = _FakeController(notes: [
        Note(id: 'n1', text: '北侧出水正常', category: NoteCategory.water, createdAt: now - 3600000, updatedAt: now - 3600000),
        Note(id: 'n2', text: '二楼发现被困人员', category: NoteCategory.rescue, createdAt: now - 1800000, updatedAt: now - 1800000),
      ]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: NotesPage(controller: c)),
      ));
      await tester.pump();
      expect(find.text('火场日志'), findsOneWidget);
      expect(find.text('北侧出水正常'), findsOneWidget);
      expect(find.text('二楼发现被困人员'), findsOneWidget);
      // 分类 chips：出水 + 搜救
      expect(find.text('出水'), findsWidgets);
      expect(find.text('搜救'), findsWidgets);
      // 筛选"搜救"后只显示搜救条目
      await tester.tap(find.widgetWithText(FilterChip, '搜救'));
      await tester.pump();
      expect(find.text('北侧出水正常'), findsNothing);
      expect(find.text('二楼发现被困人员'), findsOneWidget);
    });

    testWidgets('写日志弹窗：输入内容+选分类后保存', (tester) async {
      final c = _FakeController();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: AnimatedBuilder(
          animation: c,
          builder: (context, _) => Scaffold(body: NotesPage(controller: c)),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('写日志'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '水带铺设完成');
      await tester.tap(find.widgetWithText(ChoiceChip, '出水'));
      await tester.pump();
      await tester.tap(find.text('保存到日志'));
      await tester.pumpAndSettle();
      expect(c.notes.single.text, '水带铺设完成');
      expect(c.notes.single.category, NoteCategory.water);
      expect(find.text('水带铺设完成'), findsOneWidget);
    });

    testWidgets('点击条目编辑文本并保存修改', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final c = _FakeController(notes: [
        Note(id: 'n1', text: '一楼火势较大', category: NoteCategory.other, createdAt: now, updatedAt: now),
      ]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: NotesPage(controller: c)),
      ));
      await tester.pump();
      await tester.tap(find.text('一楼火势较大'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '一楼火势已控制');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(c.notes.single.text, '一楼火势已控制');
    });

    testWidgets('编辑弹窗内删除条目需确认', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final c = _FakeController(notes: [
        Note(id: 'n1', text: '测试删除', category: NoteCategory.other, createdAt: now, updatedAt: now),
      ]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: NotesPage(controller: c)),
      ));
      await tester.pump();
      await tester.tap(find.text('测试删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除这条日志'));
      await tester.pumpAndSettle();
      // 二次确认对话框
      expect(find.text('删除日志'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(c.notes, isEmpty);
    });
  });

  group('StatsPage 数据统计', () {
    testWidgets('汇总卡片与每人排行：次数/总时长/平均时长', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final e1 = Entry(
        id: 'e1', name: '张伟', pressureMpa: 20, durationMin: 34,
        entryAt: now - 100 * 60000, exitAt: now - 20 * 60000, exitedAt: now - 20 * 60000,
        source: 'voice',
      ); // 张伟第 1 次：80 分钟
      final e2 = Entry(
        id: 'e2', name: '张伟', pressureMpa: 20, durationMin: 34,
        entryAt: now - 10 * 60000, exitAt: now - 5 * 60000, exitedAt: now - 5 * 60000,
        source: 'voice',
      ); // 张伟第 2 次：5 分钟
      final e3 = Entry(
        id: 'e3', name: '李娜', pressureMpa: 20, durationMin: 34,
        entryAt: now - 60 * 60000, exitAt: now + 40 * 60000, exitedAt: null,
        source: 'voice',
      ); // 李娜 1 次在场：累计 60 分钟
      final c = _FakeController(entries: [e1, e2, e3]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: StatsPage(controller: c)),
      ));
      await tester.pump();
      expect(find.text('数据统计'), findsOneWidget);
      // 汇总：当前在场 1 人（李娜）、3 人次、累计 145 分钟
      expect(find.text('1 人'), findsOneWidget);
      expect(find.text('3 人次'), findsOneWidget);
      expect(find.text('2 小时 25 分'), findsOneWidget);
      // 排行按次数降序：张伟(2) 在前
      expect(find.text('张伟'), findsOneWidget);
      expect(find.text('2 次 · 1 小时 25 分'), findsOneWidget);
      expect(find.text('平均 42 分钟'), findsOneWidget);
      expect(find.text('李娜'), findsOneWidget);
      expect(find.text('1 次 · 1 小时'), findsOneWidget);
      // 切换按时长排序：李娜(60) 仍少于 张伟(85)，顺序不变
      await tester.tap(find.text('按次数'));
      await tester.pump();
      expect(find.text('按总时长'), findsOneWidget);
      // 人员筛选
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('张伟').last);
      await tester.pumpAndSettle();
      expect(find.text('2 人次'), findsOneWidget);
      expect(find.text('李娜'), findsNothing);
    });

    testWidgets('无记录时显示空态', (tester) async {
      final c = _FakeController();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: StatsPage(controller: c)),
      ));
      await tester.pump();
      expect(find.text('所选范围内暂无进出记录'), findsOneWidget);
    });

    testWidgets('窄屏（411dp）筛选行不溢出', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final e = Entry(
        id: 'e1', name: '张伟', pressureMpa: 20, durationMin: 34,
        entryAt: DateTime.now().millisecondsSinceEpoch - 30 * 60000,
        exitAt: DateTime.now().millisecondsSinceEpoch + 30 * 60000,
        exitedAt: null, source: 'voice',
      );
      final c = _FakeController(entries: [e]);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: StatsPage(controller: c)),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('全部人员'), findsOneWidget);
    });
  });

  group('main.dart 导航', () {
    testWidgets('默认进入看板，底部五个入口对称存在', (tester) async {
      await tester.pumpWidget(const WatchDogApp());
      await tester.pump();
      expect(find.text('火场安全管控看板'), findsOneWidget);
      expect(find.text('日志'), findsOneWidget);
      expect(find.text('看板'), findsOneWidget);
      expect(find.text('数据'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(find.byType(VoiceButton), findsOneWidget);
    });

    testWidgets('点击日志/数据/设置可切换页面', (tester) async {
      await tester.pumpWidget(const WatchDogApp());
      await tester.pump();
      await tester.tap(find.text('日志'));
      await tester.pumpAndSettle();
      expect(find.text('火场日志'), findsOneWidget);
      await tester.tap(find.text('数据'));
      await tester.pumpAndSettle();
      expect(find.text('数据统计'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('服务端'), findsOneWidget);
      expect(find.text('计算参数'), findsOneWidget);
    });
  });
}
