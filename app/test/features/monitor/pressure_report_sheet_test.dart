import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/data/monitor_repository.dart';
import 'package:watchdog/features/monitor/state/monitor_store.dart';
import 'package:watchdog/features/monitor/ui/sheets/pressure_report_sheet.dart';

const int _baseNow = 1700000000000;

Entry _entry({
  String id = 'e-1',
  String name = '李娜',
  double pressureMpa = 20.0,
}) => Entry(
  id: id,
  name: name,
  pressureMpa: pressureMpa,
  durationMin: 34,
  entryAt: _baseNow - 10 * 60000,
  exitAt: _baseNow + 20 * 60000,
  source: 'voice',
);

({MonitorStore store, List<double> reported, List<String> notes}) _createStore(
  Entry entry,
) {
  final reported = <double>[];
  final notes = <String>[];
  final transport = ApiHttpTransport(
    ApiConfig(baseUrl: 'https://example.test', incidentId: 'inc-1'),
    clientFactory: () => MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final p = (body['pressure_mpa'] as num).toDouble();
      reported.add(p);
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'id': entry.id,
            'version': entry.version + 1,
            'name': entry.name,
            'pressure_mpa': p,
            'duration_min': 20,
            'entry_at': entry.entryAt,
            'exit_at': _baseNow + 20 * 60000,
            'source': entry.source,
          }),
        ),
        200,
        headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  final repo = MonitorRepository(transport);
  final store = MonitorStore(
    nowMs: () => _baseNow,
    initialEntries: <Entry>[entry],
    repositoryProvider: () => repo,
    incidentIdProvider: () => 'inc-1',
    memberIdProvider: () async => 'm1',
    onAddNote: (String text, {required String category}) async {
      notes.add('$category:$text');
    },
  );
  return (store: store, reported: reported, notes: notes);
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required MonitorStore store,
  required Entry entry,
  Size surfaceSize = const Size(390, 844),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: PressureReportSheet(monitorStore: store, entry: entry),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('PressureReportSheet 快捷报压面板', () {
    testWidgets('展示 30→6MPa 共 9 档预设、禁用高于当前压力、点选并提交', (tester) async {
      final entry = _entry(pressureMpa: 20);
      final env = _createStore(entry);
      addTearDown(env.store.dispose);

      await _pumpSheet(tester, store: env.store, entry: entry);

      expect(find.textContaining('初始 20.0 MPa'), findsOneWidget);
      for (final lv in PressureReportSheet.levels) {
        expect(find.byKey(Key('pressure-sheet-level-$lv')), findsOneWidget);
      }
      expect(find.text('选择压力档位'), findsOneWidget);

      // 30 > 20 禁用，点选无效
      await tester.tap(find.byKey(const Key('pressure-sheet-level-30')));
      await tester.pump();
      expect(find.text('选择压力档位'), findsOneWidget);

      // 点选 15 启用提交
      await tester.tap(find.byKey(const Key('pressure-sheet-level-15')));
      await tester.pump();
      expect(find.text('确认更新 15 MPa'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pressure-sheet-submit-btn')));
      await tester.pumpAndSettle();

      expect(env.reported, <double>[15.0]);
      expect(env.notes, <String>['entry:李娜 更新气瓶压力为 15 MPa']);
    });

    testWidgets('手动输入 0<p<=40 与预设档位严格互斥', (tester) async {
      final entry = _entry(pressureMpa: 20);
      final env = _createStore(entry);
      addTearDown(env.store.dispose);

      await _pumpSheet(tester, store: env.store, entry: entry);

      final inputFinder = find.byKey(const Key('pressure-sheet-custom-input'));
      await tester.enterText(inputFinder, '13.5');
      await tester.pump();
      expect(find.text('确认更新 13.5 MPa'), findsOneWidget);

      // 切回预设档位 9，清空输入框
      await tester.tap(find.byKey(const Key('pressure-sheet-level-9')));
      await tester.pump();
      expect(find.text('确认更新 9 MPa'), findsOneWidget);
      expect(tester.widget<TextField>(inputFinder).controller!.text, isEmpty);

      await tester.tap(find.byKey(const Key('pressure-sheet-submit-btn')));
      await tester.pumpAndSettle();
      expect(env.reported, <double>[9.0]);
    });

    testWidgets('非法手动输入（0 或 >40）保持提交禁用', (tester) async {
      final entry = _entry(pressureMpa: 20);
      final env = _createStore(entry);
      addTearDown(env.store.dispose);

      await _pumpSheet(tester, store: env.store, entry: entry);

      final inputFinder = find.byKey(const Key('pressure-sheet-custom-input'));
      await tester.enterText(inputFinder, '0');
      await tester.pump();
      expect(find.text('选择压力档位'), findsOneWidget);

      await tester.enterText(inputFinder, '41');
      await tester.pump();
      expect(find.text('选择压力档位'), findsOneWidget);
    });

    testWidgets('提交高于当前压力弹 CommandSheet 二次确认，取消不提交，确认后提交并记日志', (tester) async {
      final entry = _entry(pressureMpa: 20);
      final env = _createStore(entry);
      addTearDown(env.store.dispose);

      await _pumpSheet(tester, store: env.store, entry: entry);

      await tester.enterText(
        find.byKey(const Key('pressure-sheet-custom-input')),
        '25',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('pressure-sheet-submit-btn')));
      await tester.pumpAndSettle();

      expect(find.text('压力调高确认'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(env.reported, isEmpty);

      await tester.tap(find.byKey(const Key('pressure-sheet-submit-btn')));
      await tester.pumpAndSettle();
      expect(find.text('压力调高确认'), findsOneWidget);
      await tester.tap(find.text('确认调高'));
      await tester.pumpAndSettle();

      expect(env.reported, <double>[25.0]);
      expect(env.notes.any((n) => n.contains('李娜 更新气瓶压力为 25 MPa')), isTrue);
    });

    testWidgets('预设按钮与主提交按钮触控高度均 ≥ 56dp', (tester) async {
      final entry = _entry(pressureMpa: 30);
      final env = _createStore(entry);
      addTearDown(env.store.dispose);

      await _pumpSheet(tester, store: env.store, entry: entry);

      expect(
        tester.getSize(find.byKey(const Key('pressure-sheet-level-18'))).height,
        greaterThanOrEqualTo(56.0),
      );
      expect(
        tester.getSize(find.byKey(const Key('pressure-sheet-submit-btn'))).height,
        greaterThanOrEqualTo(56.0),
      );
    });

    testWidgets('360dp @ 130% 字号与键盘弹起下零溢出', (tester) async {
      final entry = _entry(name: '消防救援一号班长', pressureMpa: 20);
      final env = _createStore(entry);
      addTearDown(env.store.dispose);

      await _pumpSheet(
        tester,
        store: env.store,
        entry: entry,
        surfaceSize: const Size(360, 780),
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
