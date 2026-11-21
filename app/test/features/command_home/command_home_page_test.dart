import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/command_home/ui/command_home_page.dart';
import 'package:watchdog/features/command_home/ui/widgets/field_tools_grid_section.dart';
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
        disableAnimations: true,
      ),
      child: w!,
    ),
    home: child,
  );
}

void main() {
  group('CommandHomePage', () {
    testWidgets('无警情时展示无警情引导卡，同时 9 个现场工具仍全部可用', (
      WidgetTester tester,
    ) async {
      var chooseCalls = 0;
      final tappedTools = <String>[];

      final tools = FieldToolsGridSection.buildDefaultTools(
        onKeySites: () => tappedTools.add('重点单位'),
        onHazmat: () => tappedTools.add('危化速查'),
        onCamera: () => tappedTools.add('水印相机'),
        onLocationShare: () => tappedTools.add('定位分享'),
        onVideoResources: () => tappedTools.add('视频资源'),
        onRouteTraffic: () => tappedTools.add('路况查询'),
        onTacticalBrief: () => tappedTools.add('警情上报'),
        onSceneMap: () => tappedTools.add('现场地图'),
        onWaterSources: () => tappedTools.add('周边水源'),
      );

      await tester.pumpWidget(
        _wrap(
          CommandHomePage(
            hasIncident: false,
            onChooseIncident: () => chooseCalls++,
            tools: tools,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-home-page')), findsOneWidget);
      expect(find.byKey(const Key('command-no-incident-card')), findsOneWidget);
      expect(find.byKey(const Key('command-incident-card')), findsNothing);
      expect(find.byKey(const Key('command-tools-grid')), findsOneWidget);
      expect(find.byType(ToolGrid), findsWidgets);

      await tester.tap(find.byKey(const Key('choose-incident-from-home')));
      await tester.pump();
      expect(chooseCalls, 1);

      for (final keyId in const <String>[
        '重点单位',
        '危化速查',
        '水印相机',
        '定位分享',
        '视频资源',
        '路况查询',
        '警情上报',
        '现场地图',
        '周边水源',
      ]) {
        final finder = find.byKey(Key('tool-$keyId'));
        await tester.ensureVisible(finder);
        await tester.pump();
        expect(finder, findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('tool-警情上报')));
      await tester.tap(find.byKey(const Key('tool-周边水源')));
      await tester.pump();
      expect(tappedTools, <String>['警情上报', '周边水源']);
    });

    testWidgets('有警情且存在在场人员时展示态势卡、3 秒态势卡与日志预览插槽', (
      WidgetTester tester,
    ) async {
      var openedMonitor = 0;
      var tappedConnection = 0;

      await tester.pumpWidget(
        _wrap(
          CommandHomePage(
            hasIncident: true,
            incidentCardSlot: const SurfaceCard(
              child: Text('示例路住宅火灾态势卡'),
            ),
            airSafetySummary: const AirSafetySummary(
              activeCount: 2,
              shortestName: '张三',
              shortestRemainingMin: 12,
              level: AirSafetyLevel.normal,
            ),
            tacticalProgress: '一号水枪出水控制火势',
            onOpenMonitor: () => openedMonitor++,
            onConnectionTap: () => tappedConnection++,
            tools: FieldToolsGridSection.buildDefaultTools(),
            notesPreviewSlot: const SizedBox(
              key: Key('command-notes-preview'),
              child: Text('最近火场日志预览'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-incident-card')), findsOneWidget);
      expect(find.byKey(const Key('command-no-incident-card')), findsNothing);
      expect(find.byKey(const Key('command-glance-card')), findsOneWidget);
      expect(find.byKey(const Key('command-notes-preview')), findsOneWidget);
      expect(find.text('示例路住宅火灾态势卡'), findsOneWidget);
      expect(find.text('2 人进入火场'), findsOneWidget);

      await tester.tap(find.byKey(const Key('command-glance-card')));
      await tester.pump();
      expect(openedMonitor, 1);

      await tester.tap(find.byType(ConnectionPill));
      await tester.pump();
      expect(tappedConnection, 1);
    });

    testWidgets('无在场人员时不占位渲染 3 秒态势卡', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          CommandHomePage(
            hasIncident: true,
            incidentCardSlot: const SurfaceCard(child: Text('待命警情')),
            airSafetySummary: AirSafetySummary.idle(),
            tools: FieldToolsGridSection.buildDefaultTools(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-glance-card')), findsNothing);
    });

    testWidgets('离线态展示离线告警横幅与待补传计数', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          CommandHomePage(
            hasIncident: false,
            isOffline: true,
            connectionState: DsConnectionState.offline,
            pendingSyncCount: 2,
            tools: FieldToolsGridSection.buildDefaultTools(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('离线 · 待补传 2'), findsOneWidget);
      expect(find.textContaining('当前处于离线状态'), findsOneWidget);
    });

    testWidgets('360dp @ 130% 大字号（昼白与暗曜）零溢出', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _wrap(
            CommandHomePage(
              hasIncident: true,
              incidentCardSlot: const SurfaceCard(
                child: Text('示例县示例工业园区厂房火灾扑救'),
              ),
              airSafetySummary: const AirSafetySummary(
                activeCount: 4,
                shortestName: '赵六',
                shortestRemainingMin: 5,
                level: AirSafetyLevel.critical,
              ),
              tacticalProgress: '东侧仓库出现局部坍塌险情',
              hasCriticalHazards: true,
              connectionState: DsConnectionState.offline,
              pendingSyncCount: 3,
              isOffline: true,
              tools: FieldToolsGridSection.buildDefaultTools(),
              notesPreviewSlot: const SurfaceCard(
                key: Key('command-notes-preview'),
                child: Text('火场日志预览'),
              ),
              bottomClearance: 72,
            ),
            brightness: brightness,
            textScale: 1.3,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  });
}
