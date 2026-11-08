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
      expect(find.textContaining('张三'), findsOneWidget);
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
  });
}
