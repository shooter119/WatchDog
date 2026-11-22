import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/sync/sync_store.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/state/alert_clock_store.dart';
import 'package:watchdog/features/monitor/state/monitor_store.dart';
import 'package:watchdog/features/monitor/ui/entry_detail_screen.dart';
import 'package:watchdog/features/monitor/ui/monitor_page.dart';
import 'package:watchdog/features/monitor/ui/monitor_stats_screen.dart';
import 'package:watchdog/features/monitor/ui/sheets/pressure_report_sheet.dart';
import 'package:watchdog/services/alarm_service.dart';
import 'package:watchdog/services/tts_service.dart';

class _SilentAlarm extends AlarmService {
  @override
  Future<void> stopAlarm() async {}
}

class _SilentTts extends TtsService {
  @override
  void speak(String text) {}
}

const int _baseNow = 1700000000000;

Entry _entry({
  required String id,
  required String name,
  required int remainingMin,
  double pressureMpa = 20,
}) => Entry(
  id: id,
  name: name,
  pressureMpa: pressureMpa,
  durationMin: 34,
  entryAt: _baseNow - 10 * 60000,
  exitAt: _baseNow + remainingMin * 60000,
  source: 'voice',
  rawText: '$name，20兆帕',
);

Future<({MonitorStore monitor, AlertClockStore clock})> _pumpMonitorPage(
  WidgetTester tester, {
  List<Entry> entries = const <Entry>[],
  SyncStore? syncStore,
  bool soundEnabled = true,
  bool requiresIncident = false,
  VoidCallback? onGoVoice,
  int Function()? nowMs,
  double textScale = 1.0,
  Size surfaceSize = const Size(390, 844),
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final resolvedNow = nowMs ?? () => _baseNow;
  final monitor = MonitorStore(initialEntries: entries, nowMs: resolvedNow);
  final alarm = _SilentAlarm()..soundEnabled = soundEnabled;
  final clock = AlertClockStore(
    alarm: alarm,
    tts: _SilentTts(),
    entriesProvider: () => monitor.entries,
    calcConfigProvider: () => monitor.calcConfig,
    nowMs: resolvedNow,
  );
  addTearDown(monitor.dispose);
  addTearDown(clock.dispose);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: MaterialApp(
        theme: buildCommandTheme(brightness),
        home: Scaffold(
          body: MonitorPage(
            monitorStore: monitor,
            alertClockStore: clock,
            syncStore: syncStore,
            requiresIncident: requiresIncident,
            onGoVoice: onGoVoice,
            nowMs: resolvedNow,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (monitor: monitor, clock: clock);
}

void main() {
  group('MonitorPage 现场监控看板', () {
    testWidgets('统计在场人数 / 需关注 / 最早到期与 D6 分级胶囊', (tester) async {
      await _pumpMonitorPage(
        tester,
        entries: <Entry>[
          _entry(id: 'e1', name: '张伟', remainingMin: 30),
          _entry(id: 'e2', name: '李娜', remainingMin: 8),
          _entry(id: 'e3', name: '王强', remainingMin: 3),
        ],
      );

      expect(find.byKey(const Key('monitor-page')), findsOneWidget);
      expect(find.byKey(const Key('monitor-risk-bar')), findsOneWidget);
      expect(find.text('3'), findsWidgets);
      expect(find.text('2'), findsWidgets);
      expect(find.text('03:00'), findsWidgets);
      expect(find.text('超时 0'), findsOneWidget);
      expect(find.text('告警 1'), findsOneWidget);
      expect(find.text('注意 1'), findsOneWidget);
      expect(find.text('安全 1'), findsOneWidget);
    });

    testWidgets('空列表显示 -- 与 monitor-empty-state', (tester) async {
      await _pumpMonitorPage(tester, entries: const <Entry>[], onGoVoice: () {});

      expect(find.text('--'), findsOneWidget);
      expect(find.byKey(const Key('monitor-empty-state')), findsOneWidget);
      expect(find.text('暂无人员在场'), findsOneWidget);
      expect(find.text('去指挥台'), findsOneWidget);
    });

    testWidgets('有危险人员时显示 monitor-danger-banner，全安全时隐藏', (tester) async {
      await _pumpMonitorPage(
        tester,
        entries: <Entry>[
          _entry(id: 'e1', name: '张伟', remainingMin: 30),
          _entry(id: 'e2', name: '李娜', remainingMin: 8),
          _entry(id: 'e3', name: '王强', remainingMin: 3),
        ],
      );
      expect(find.byKey(const Key('monitor-danger-banner')), findsOneWidget);
      expect(find.text('2 人需要关注 · 最早到期 03:00'), findsOneWidget);

      await _pumpMonitorPage(
        tester,
        entries: <Entry>[_entry(id: 'e1', name: '张伟', remainingMin: 30)],
      );
      expect(find.byKey(const Key('monitor-danger-banner')), findsNothing);
    });

    testWidgets('报警音关闭时显示 monitor-sound-muted-banner', (tester) async {
      await _pumpMonitorPage(
        tester,
        entries: <Entry>[_entry(id: 'e1', name: '张伟', remainingMin: 30)],
        soundEnabled: false,
      );
      expect(find.byKey(const Key('monitor-sound-muted-banner')), findsOneWidget);
      expect(find.text('报警音已关闭'), findsOneWidget);
    });

    testWidgets('断线态显示离线横幅与重试按钮', (tester) async {
      var now = _baseNow;
      final sync = SyncStore(nowMs: () => now);
      addTearDown(sync.dispose);
      sync.applyConnectionState(SyncConnectionState.reconnecting);
      now += 35000;

      await _pumpMonitorPage(
        tester,
        entries: <Entry>[_entry(id: 'e1', name: '张伟', remainingMin: 30)],
        syncStore: sync,
      );
      expect(find.text('网络已中断，看板数据可能不是最新'), findsOneWidget);
    });

    testWidgets('危险等级排序：超时 > 告警 > 注意（剩余时间升序） > 安全', (tester) async {
      await _pumpMonitorPage(
        tester,
        entries: <Entry>[
          _entry(id: 's1', name: '安全甲', remainingMin: 40),
          _entry(id: 'w2', name: '注意乙', remainingMin: 9),
          _entry(id: 'w1', name: '注意甲', remainingMin: 7),
          _entry(id: 'a1', name: '告警丁', remainingMin: 4),
          _entry(id: 't1', name: '超时戊', remainingMin: -1),
        ],
      );

      final yTimeout = tester.getTopLeft(find.byKey(const Key('monitor-card-t1'))).dy;
      final yAlarm = tester.getTopLeft(find.byKey(const Key('monitor-card-a1'))).dy;
      expect(yTimeout, lessThan(yAlarm));

      await tester.scrollUntilVisible(find.byKey(const Key('monitor-card-w1')), 180);
      await tester.scrollUntilVisible(find.byKey(const Key('monitor-card-w2')), 180);
      final yWarn1 = tester.getTopLeft(find.byKey(const Key('monitor-card-w1'))).dy;
      final yWarn2 = tester.getTopLeft(find.byKey(const Key('monitor-card-w2'))).dy;
      expect(yWarn1, lessThan(yWarn2));

      await tester.scrollUntilVisible(find.byKey(const Key('monitor-card-s1')), 180);
      expect(find.byKey(const Key('monitor-card-s1')), findsOneWidget);
    });

    testWidgets('超时卡片显示已超时/+01:00 且主操作按钮高度 ≥ 56dp', (tester) async {
      await _pumpMonitorPage(
        tester,
        entries: <Entry>[_entry(id: 't1', name: '赵磊', remainingMin: -1)],
      );

      expect(find.byKey(const Key('monitor-card-t1')), findsOneWidget);
      expect(find.text('已超时'), findsWidgets);
      expect(find.text('+01:00'), findsOneWidget);
      final btnFinder = find.byKey(const Key('monitor-card-report-btn-t1'));
      expect(btnFinder, findsOneWidget);
      expect(tester.getSize(btnFinder).height, greaterThanOrEqualTo(56.0));
    });

    testWidgets('clockTick 递增时仅局部刷新倒计时数值', (tester) async {
      var now = _baseNow;
      final state = await _pumpMonitorPage(
        tester,
        entries: <Entry>[_entry(id: 'e1', name: '张伟', remainingMin: 20)],
        nowMs: () => now,
      );

      expect(find.text('20:00'), findsWidgets);
      now += 1000;
      state.clock.clockTick.value++;
      await tester.pump();
      expect(find.text('19:59'), findsWidgets);
    });

    testWidgets('点击统计按钮跳统计页，点击卡片跳详情，点击报压弹报压面板', (tester) async {
      await _pumpMonitorPage(
        tester,
        entries: <Entry>[_entry(id: 'e1', name: '张伟', remainingMin: 20)],
      );

      await tester.tap(find.byKey(const Key('monitor-stats-btn')));
      await tester.pumpAndSettle();
      expect(find.byType(MonitorStatsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('monitor-card-report-btn-e1')));
      await tester.pumpAndSettle();
      expect(find.byType(PressureReportSheet), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('张伟'));
      await tester.pumpAndSettle();
      expect(find.byType(EntryDetailScreen), findsOneWidget);
    });

    testWidgets('360dp @ 130% 字体缩放与 320dp @ 200% 字体缩放零溢出', (tester) async {
      await _pumpMonitorPage(
        tester,
        surfaceSize: const Size(360, 780),
        textScale: 1.3,
        entries: <Entry>[
          _entry(id: 't1', name: '消防救援一号班长', remainingMin: -2),
          _entry(id: 'a1', name: '李娜', remainingMin: 3),
        ],
      );
      expect(tester.takeException(), isNull);

      await _pumpMonitorPage(
        tester,
        surfaceSize: const Size(320, 720),
        textScale: 2.0,
        entries: <Entry>[
          _entry(id: 'e1', name: '消防救援一号班长', remainingMin: 20),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(find.text('消防救援一号班长'), findsOneWidget);
    });
  });
}
