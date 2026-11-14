import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/widgets/commander_glance_card.dart';

void main() {
  Widget buildTestableWidget(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: child,
      ),
    );
  }

  group('CommanderGlanceCard Tests', () {
    testWidgets('renders idle state when activeEntries is empty', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          const CommanderGlanceCard(activeEntries: []),
        ),
      );

      expect(find.text('现场监控'), findsOneWidget);
      expect(find.text('暂无在场人员'), findsOneWidget);
      expect(find.text('查看看板'), findsOneWidget);
    });

    testWidgets('renders active entries count and shortest remaining time', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = [
        Entry(
          id: '1',
          name: '张三',
          durationMin: 20,
          entryAt: now - 300000,
          exitAt: now + 840000, // 剩 14 分钟
          source: 'voice',
        ),
        Entry(
          id: '2',
          name: '李四',
          durationMin: 25,
          entryAt: now - 300000,
          exitAt: now + 1200000, // 剩 20 分钟
          source: 'voice',
        ),
      ];

      final notes = [
        const Note(
          id: 'n1',
          text: '东门水枪出水内攻推进',
          category: '出水',
          createdAt: 1000,
          updatedAt: 1000,
        ),
      ];

      await tester.pumpWidget(
        buildTestableWidget(
          CommanderGlanceCard(
            activeEntries: entries,
            notes: notes,
          ),
        ),
      );

      expect(find.text('2 人进入火场'), findsOneWidget);
      expect(find.text('余14分钟 (张三)'), findsOneWidget);
      final textWidget = tester.widget<Text>(find.text('余14分钟 (张三)'));
      expect(textWidget.style?.fontFeatures, contains(const FontFeature.tabularFigures()));
      expect(find.text('东门水枪出水内攻推进'), findsOneWidget);
    });

    testWidgets('triggers onTap callback when tapped', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        buildTestableWidget(
          CommanderGlanceCard(
            activeEntries: const [],
            onTap: () {
              tapped = true;
            },
          ),
        ),
      );

      await tester.tap(find.byType(CommanderGlanceCard));
      expect(tapped, isTrue);
    });

    testWidgets('390dp 标准宽度下人数标题完整显示不截断且窄屏大字号不溢出', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = [
        Entry(
          id: '1',
          name: '张三',
          durationMin: 40,
          entryAt: now - 360000,
          exitAt: now + 34 * 60000 - 10000,
          source: 'voice',
        ),
        Entry(
          id: '2',
          name: '李四',
          durationMin: 25,
          entryAt: now - 960000,
          exitAt: now + 9 * 60000 - 10000,
          source: 'voice',
        ),
      ];

      await tester.pumpWidget(
        buildTestableWidget(
          Center(
            child: SizedBox(
              width: 358,
              child: CommanderGlanceCard(activeEntries: entries),
            ),
          ),
        ),
      );
      await tester.pump();

      final countRect = tester.getRect(find.text('2 人进入火场'));
      final remainingRect = tester.getRect(find.text('余9分钟 (李四)'));
      expect(countRect.width, greaterThanOrEqualTo(95));
      expect(countRect.top, lessThan(remainingRect.bottom));
      expect(remainingRect.top, lessThan(countRect.bottom));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: SizedBox(
                  width: 240,
                  child: CommanderGlanceCard(activeEntries: entries),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('2 人进入火场'), findsOneWidget);
      expect(find.text('余9分钟 (李四)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
