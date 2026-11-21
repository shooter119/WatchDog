import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/state/monitor_store.dart';
import 'package:watchdog/features/monitor/ui/monitor_stats_screen.dart';

void main() {
  // 2026-05-14 15:00:00（周四），确保今天/本周/本月边界清晰确定
  final fixedNow = DateTime(2026, 5, 14, 15, 0).millisecondsSinceEpoch;

  group('MonitorStatsScreen 数据统计页', () {
    testWidgets('汇总卡片与每人排行（次数/总时长/平均时长）及按次数/时长排序切换', (tester) async {
      final e1 = Entry(
        id: 'e1',
        name: '张伟',
        pressureMpa: 20,
        durationMin: 34,
        entryAt: fixedNow - 100 * 60000,
        exitAt: fixedNow - 20 * 60000,
        exitedAt: fixedNow - 20 * 60000,
        source: 'voice',
      ); // 张伟第 1 次：80 分钟
      final e2 = Entry(
        id: 'e2',
        name: '张伟',
        pressureMpa: 20,
        durationMin: 34,
        entryAt: fixedNow - 10 * 60000,
        exitAt: fixedNow - 5 * 60000,
        exitedAt: fixedNow - 5 * 60000,
        source: 'voice',
      ); // 张伟第 2 次：5 分钟
      final e3 = Entry(
        id: 'e3',
        name: '李娜',
        pressureMpa: 20,
        durationMin: 34,
        entryAt: fixedNow - 90 * 60000,
        exitAt: fixedNow + 30 * 60000,
        exitedAt: null,
        source: 'voice',
      ); // 李娜 1 次在场：90 分钟（总时长 > 张伟 85 分钟）
      final store = MonitorStore(
        initialEntries: <Entry>[e1, e2, e3],
        nowMs: () => fixedNow,
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: MonitorStatsScreen(
            monitorStore: store,
            nowMs: () => fixedNow,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('数据统计'), findsOneWidget);
      await tester.tap(find.text('全部'));
      await tester.pump();

      // 汇总：当前在场 1 人、3 人次、累计 175 分钟 = 2 小时 55 分
      expect(find.text('1 人'), findsOneWidget);
      expect(find.text('3 人次'), findsOneWidget);
      expect(find.text('2 小时 55 分'), findsOneWidget);

      // 默认按次数降序：张伟(2) 在李娜(1) 之前
      expect(find.text('2 次 · 1 小时 25 分'), findsOneWidget);
      expect(find.text('平均 42 分钟'), findsOneWidget);
      expect(find.text('1 次 · 1 小时 30 分'), findsOneWidget);
      final zwYBefore = tester.getTopLeft(find.text('张伟')).dy;
      final lnYBefore = tester.getTopLeft(find.text('李娜')).dy;
      expect(zwYBefore, lessThan(lnYBefore));

      // 切换按总时长排序：李娜(90) 排在张伟(85) 之前
      await tester.tap(find.text('按次数'));
      await tester.pump();
      expect(find.text('时长排行'), findsOneWidget);
      expect(find.text('按总时长'), findsOneWidget);
      final zwYAfter = tester.getTopLeft(find.text('张伟')).dy;
      final lnYAfter = tester.getTopLeft(find.text('李娜')).dy;
      expect(lnYAfter, lessThan(zwYAfter));
    });

    testWidgets('今天 / 本周 / 本月 / 全部筛选正确过滤历史记录', (tester) async {
      final todayEntry = Entry(
        id: 't1',
        name: '今日员',
        pressureMpa: 20,
        durationMin: 30,
        entryAt: DateTime(2026, 5, 14, 10, 0).millisecondsSinceEpoch,
        exitAt: DateTime(2026, 5, 14, 10, 30).millisecondsSinceEpoch,
        exitedAt: DateTime(2026, 5, 14, 10, 20).millisecondsSinceEpoch,
        source: 'voice',
      );
      final weekEntry = Entry(
        id: 'w1',
        name: '本周员',
        pressureMpa: 20,
        durationMin: 30,
        entryAt: DateTime(2026, 5, 12, 10, 0).millisecondsSinceEpoch,
        exitAt: DateTime(2026, 5, 12, 10, 30).millisecondsSinceEpoch,
        exitedAt: DateTime(2026, 5, 12, 10, 20).millisecondsSinceEpoch,
        source: 'voice',
      );
      final monthEntry = Entry(
        id: 'm1',
        name: '本月员',
        pressureMpa: 20,
        durationMin: 30,
        entryAt: DateTime(2026, 5, 2, 10, 0).millisecondsSinceEpoch,
        exitAt: DateTime(2026, 5, 2, 10, 30).millisecondsSinceEpoch,
        exitedAt: DateTime(2026, 5, 2, 10, 20).millisecondsSinceEpoch,
        source: 'voice',
      );
      final olderEntry = Entry(
        id: 'o1',
        name: '上月员',
        pressureMpa: 20,
        durationMin: 30,
        entryAt: DateTime(2026, 4, 20, 10, 0).millisecondsSinceEpoch,
        exitAt: DateTime(2026, 4, 20, 10, 30).millisecondsSinceEpoch,
        exitedAt: DateTime(2026, 4, 20, 10, 20).millisecondsSinceEpoch,
        source: 'voice',
      );
      final store = MonitorStore(
        initialEntries: <Entry>[todayEntry, weekEntry, monthEntry, olderEntry],
        nowMs: () => fixedNow,
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: MonitorStatsScreen(monitorStore: store, nowMs: () => fixedNow),
        ),
      );
      await tester.pump();
      expect(find.text('1 人次'), findsOneWidget);

      await tester.tap(find.text('本周'));
      await tester.pump();
      expect(find.text('2 人次'), findsOneWidget);

      await tester.tap(find.text('本月'));
      await tester.pump();
      expect(find.text('3 人次'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pump();
      expect(find.text('4 人次'), findsOneWidget);
    });

    testWidgets('无记录时显示空状态占位', (tester) async {
      final store = MonitorStore(nowMs: () => fixedNow);
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: MonitorStatsScreen(monitorStore: store, nowMs: () => fixedNow),
        ),
      );
      await tester.pump();
      expect(find.text('所选范围内暂无进出记录'), findsOneWidget);
    });

    testWidgets('360dp @ 130% 与 320dp @ 200% 长名称大时长下零溢出且启用等宽数字', (tester) async {
      final store = MonitorStore(
        nowMs: () => fixedNow,
        initialEntries: <Entry>[
          Entry(
            id: 'long-stats',
            name: '消防救援一号班长',
            pressureMpa: 20,
            durationMin: 34,
            entryAt: fixedNow - 13 * 60 * 60000 - 60000,
            exitAt: fixedNow - 60000,
            exitedAt: fixedNow - 60000,
            source: 'voice',
          ),
        ],
      );
      addTearDown(store.dispose);

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
              home: MonitorStatsScreen(
                monitorStore: store,
                nowMs: () => fixedNow,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('全部'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('13 小时'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('消防救援一号班长'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        final metricText = tester.widget<Text>(find.text('1 次 · 13 小时'));
        expect(
          metricText.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
      }
    });
  });
}
