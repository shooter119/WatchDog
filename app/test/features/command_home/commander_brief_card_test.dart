import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/command_home/ui/widgets/commander_brief_card.dart';
import 'package:watchdog/services/tactical_brief_engine.dart';

Widget _wrap(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: w!,
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  group('CommanderBriefCard', () {
    testWidgets('无在场人员时展示待命态与查看看板引导', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(CommanderBriefCard(summary: AirSafetySummary.idle())),
      );

      expect(find.byKey(const Key('command-glance-card')), findsOneWidget);
      expect(find.text('现场监控'), findsOneWidget);
      expect(find.text('暂无在场人员'), findsOneWidget);
      expect(find.text('查看看板'), findsOneWidget);
    });

    testWidgets('展示在场人数、最短板等宽数字余量与战术进展', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const CommanderBriefCard(
            summary: AirSafetySummary(
              activeCount: 2,
              shortestName: '张三',
              shortestRemainingMin: 14,
              level: AirSafetyLevel.normal,
            ),
            tacticalProgress: '东门水枪出水内攻推进',
          ),
        ),
      );

      expect(find.text('2 人进入火场'), findsOneWidget);
      expect(find.text('余14分钟 (张三)'), findsOneWidget);
      final remainingText = tester.widget<Text>(find.text('余14分钟 (张三)'));
      expect(
        remainingText.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(find.text('东门水枪出水内攻推进'), findsOneWidget);
    });

    testWidgets('极危空呼与险情情报通过工厂构造展示告警胶囊与警示图标', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          CommanderBriefCard.fromIntelligence(
            summary: const AirSafetySummary(
              activeCount: 3,
              shortestName: '王五',
              shortestRemainingMin: 4,
              level: AirSafetyLevel.critical,
            ),
            intelligence: const TacticalIntelligenceSummary(
              hazards: <String>['二楼承重墙出现开裂坍塌风险'],
            ),
          ),
          brightness: Brightness.dark,
        ),
      );

      expect(find.text('3 人进入火场'), findsOneWidget);
      expect(find.text('告警'), findsOneWidget);
      expect(find.text('余4分钟 (王五)'), findsOneWidget);
      expect(find.text('二楼承重墙出现开裂坍塌风险'), findsOneWidget);
      expect(find.byIcon(DsIcons.warning), findsOneWidget);
    });

    testWidgets('点击卡片触发 onTap 跳看板回调', (WidgetTester tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          CommanderBriefCard(
            summary: AirSafetySummary.idle(),
            onTap: () => tapped = true,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('command-glance-card')));
      expect(tapped, isTrue);
    });

    testWidgets('360dp 宽屏与 240dp 窄宽 + 130% 大字号下零溢出', (WidgetTester tester) async {
      const summary = AirSafetySummary(
        activeCount: 2,
        shortestName: '李四',
        shortestRemainingMin: 9,
        level: AirSafetyLevel.warning,
      );

      await tester.pumpWidget(
        _wrap(
          const Center(
            child: SizedBox(
              width: 328,
              child: CommanderBriefCard(
                summary: summary,
                tacticalProgress: '南侧阵地持续排烟降温作业',
              ),
            ),
          ),
          textScale: 1.3,
        ),
      );
      await tester.pump();
      expect(find.text('2 人进入火场'), findsOneWidget);
      expect(find.text('余9分钟 (李四)'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _wrap(
          const SizedBox(
            width: 240,
            child: CommanderBriefCard(summary: summary),
          ),
          textScale: 1.3,
        ),
      );
      await tester.pump();
      expect(find.text('2 人进入火场'), findsOneWidget);
      expect(find.text('余9分钟 (李四)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
