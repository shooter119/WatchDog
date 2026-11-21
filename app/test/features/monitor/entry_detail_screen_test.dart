import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/data/monitor_repository.dart';
import 'package:watchdog/features/monitor/state/alert_clock_store.dart';
import 'package:watchdog/features/monitor/state/monitor_store.dart';
import 'package:watchdog/features/monitor/ui/entry_detail_screen.dart';
import 'package:watchdog/services/alarm_service.dart';
import 'package:watchdog/services/tts_service.dart';

class _SilentAlarm extends AlarmService {
  @override
  Future<void> stopAlarm() async {}
}

class _RecordingTts extends TtsService {
  final List<String> spoken = <String>[];

  @override
  void speak(String text) {
    spoken.add(text);
  }
}

const int _baseNow = 1700000000000;

Entry _entry({
  required String id,
  required String name,
  required int remainingMin,
  double pressureMpa = 20,
  double? consumptionActualLpm,
  String? rawText = '张三，20兆帕',
}) => Entry(
  id: id,
  name: name,
  pressureMpa: pressureMpa,
  durationMin: 40,
  entryAt: _baseNow - 10 * 60000,
  exitAt: _baseNow + remainingMin * 60000,
  source: 'voice',
  rawText: rawText,
  consumptionActualLpm: consumptionActualLpm,
);

({
  MonitorStore monitor,
  AlertClockStore clock,
  _RecordingTts tts,
  List<String> exitedIds,
  List<String> actionLogs,
})
_buildEnv(List<Entry> entries) {
  final exitedIds = <String>[];
  final actionLogs = <String>[];
  final tts = _RecordingTts();
  final transport = ApiHttpTransport(
    ApiConfig(baseUrl: 'https://example.test', incidentId: 'inc-1'),
    clientFactory: () => MockClient((req) async {
      final segs = req.url.pathSegments;
      exitedIds.add(segs[segs.length - 2]);
      return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
    }),
  );
  final repo = MonitorRepository(transport);
  final monitor = MonitorStore(
    nowMs: () => _baseNow,
    initialEntries: entries,
    repositoryProvider: () => repo,
    incidentIdProvider: () => 'inc-1',
    memberIdProvider: () async => 'm1',
    onAddActionLog: ({
      required List<String> names,
      required String action,
      required String category,
      String? opId,
    }) async {
      actionLogs.add('${names.join(",")}:$action:$category');
    },
  );
  final clock = AlertClockStore(
    alarm: _SilentAlarm(),
    tts: tts,
    entriesProvider: () => monitor.entries,
    calcConfigProvider: () => monitor.calcConfig,
    nowMs: () => _baseNow,
  );
  return (
    monitor: monitor,
    clock: clock,
    tts: tts,
    exitedIds: exitedIds,
    actionLogs: actionLogs,
  );
}

void main() {
  group('EntryDetailScreen 人员详情页', () {
    testWidgets('展示 32dp 倒计时、气瓶参数网格、转写文案与 ≥56dp 出场按钮', (tester) async {
      final env = _buildEnv(<Entry>[
        _entry(id: 'e-1', name: '张伟', remainingMin: 30, pressureMpa: 20),
      ]);
      addTearDown(env.monitor.dispose);
      addTearDown(env.clock.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: EntryDetailScreen(
            monitorStore: env.monitor,
            alertClockStore: env.clock,
            entryId: 'e-1',
            nowMs: () => _baseNow,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('张伟'), findsWidgets);
      expect(find.text('30:00'), findsOneWidget);
      expect(find.text('20.0 MPa'), findsNWidgets(2));
      expect(find.text('40 分钟上限'), findsOneWidget);
      expect(find.text('原始语音转写'), findsOneWidget);
      expect(find.text('张三，20兆帕'), findsOneWidget);

      final exitBtn = find.byKey(const Key('entry-detail-exit-btn'));
      expect(exitBtn, findsOneWidget);
      expect(tester.getSize(exitBtn).height, greaterThanOrEqualTo(56.0));
    });

    testWidgets('320dp @ 200% 与 360dp @ 130% 字号下信息网格自动单列零溢出', (tester) async {
      final env = _buildEnv(<Entry>[
        _entry(
          id: 'e-1',
          name: '张伟',
          remainingMin: 30,
          pressureMpa: 20,
          consumptionActualLpm: 40.8,
        ),
      ]);
      addTearDown(env.monitor.dispose);
      addTearDown(env.clock.dispose);

      for (final (size, scale) in <(Size, double)>[
        (const Size(360, 780), 1.3),
        (const Size(320, 720), 2.0),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: size,
              devicePixelRatio: 1.0,
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: MaterialApp(
              theme: buildCommandTheme(Brightness.light),
              home: EntryDetailScreen(
                monitorStore: env.monitor,
                alertClockStore: env.clock,
                entryId: 'e-1',
                nowMs: () => _baseNow,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('实测消耗率'), findsOneWidget);
        expect(find.text('40.8 L/min'), findsOneWidget);
      }
    });

    testWidgets('确认出火场弹出 CommandSheet 二次确认，确认后登记离场、写日志、播报并返回', (tester) async {
      final env = _buildEnv(<Entry>[
        _entry(id: 'e-lina', name: '李娜', remainingMin: 30),
      ]);
      addTearDown(env.monitor.dispose);
      addTearDown(env.clock.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => EntryDetailScreen(
                        monitorStore: env.monitor,
                        alertClockStore: env.clock,
                        entryId: 'e-lina',
                        nowMs: () => _baseNow,
                      ),
                    ),
                  ),
                  child: const Text('打开详情'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('entry-detail-exit-btn')));
      await tester.pumpAndSettle();

      expect(find.byType(CommandSheet), findsOneWidget);
      expect(find.text('确认「李娜」已出火场？'), findsOneWidget);
      await tester.tap(find.text('确认出火场'));
      await tester.pumpAndSettle();

      expect(env.exitedIds, <String>['e-lina']);
      expect(env.actionLogs, <String>['李娜:出场:withdraw']);
      expect(env.tts.spoken, <String>['李娜 已登记出火场']);
      expect(find.text('打开详情'), findsOneWidget);
    });

    testWidgets('取消二次确认不执行出场', (tester) async {
      final env = _buildEnv(<Entry>[
        _entry(id: 'e-wq', name: '王强', remainingMin: 30),
      ]);
      addTearDown(env.monitor.dispose);
      addTearDown(env.clock.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: EntryDetailScreen(
            monitorStore: env.monitor,
            alertClockStore: env.clock,
            entryId: 'e-wq',
            nowMs: () => _baseNow,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('entry-detail-exit-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(env.exitedIds, isEmpty);
      expect(env.tts.spoken, isEmpty);
      expect(find.byKey(const Key('entry-detail-exit-btn')), findsOneWidget);
    });

    testWidgets('告警人员展示告警 StatusPill 与倒计时', (tester) async {
      final env = _buildEnv(<Entry>[
        _entry(id: 'e-zl', name: '赵磊', remainingMin: 3),
      ]);
      addTearDown(env.monitor.dispose);
      addTearDown(env.clock.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: EntryDetailScreen(
            monitorStore: env.monitor,
            alertClockStore: env.clock,
            entryId: 'e-zl',
            nowMs: () => _baseNow,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('告警'), findsOneWidget);
      expect(find.text('03:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('记录不存在展示失效占位与返回看板按钮', (tester) async {
      final env = _buildEnv(const <Entry>[]);
      addTearDown(env.monitor.dispose);
      addTearDown(env.clock.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: EntryDetailScreen(
            monitorStore: env.monitor,
            alertClockStore: env.clock,
            entryId: 'missing',
            nowMs: () => _baseNow,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('该记录已不存在'), findsOneWidget);
      expect(find.text('返回看板'), findsOneWidget);
    });
  });
}
