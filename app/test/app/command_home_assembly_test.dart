import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/app/shell/command_app_shell.dart';
import 'package:watchdog/app/shell/shell_keys.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/command_home/ui/command_home_page.dart';
import 'package:watchdog/features/command_home/ui/sheets/connection_detail_sheet.dart';
import 'package:watchdog/features/command_home/ui/sheets/tactical_brief_command_sheet.dart';
import 'package:watchdog/features/command_home/ui/widgets/commander_brief_card.dart';
import 'package:watchdog/features/hazmat/ui/hazmat_page.dart';
import 'package:watchdog/features/incident/ui/incident_details_screen.dart';
import 'package:watchdog/features/incident/ui/widgets/incident_situation_card.dart';
import 'package:watchdog/features/key_sites/ui/key_sites_page.dart';
import 'package:watchdog/features/map/ui/route_traffic_page.dart';
import 'package:watchdog/features/map/ui/scene_map_page.dart';
import 'package:watchdog/features/notes/ui/notes_timeline_screen.dart';
import 'package:watchdog/features/video/ui/video_playback_surface.dart';
import 'package:watchdog/features/video/ui/video_resources_page.dart';
import 'package:watchdog/features/water_sources/ui/water_sources_page.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/models/video_resources.dart';
import 'package:watchdog/services/system_pip.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/services/video_playback_session.dart';
import 'package:watchdog/state/app_controller.dart';

class _AssemblyFakeController extends AppController {
  _AssemblyFakeController({
    bool guest = false,
    Incident? incident,
    List<Entry> initialEntries = const <Entry>[],
    List<Note> initialNotes = const <Note>[],
    List<IncidentForce> initialForces = const <IncidentForce>[],
  }) : _guest = guest {
    currentIncident = incident;
    entries = List<Entry>.of(initialEntries);
    notes = List<Note>.of(initialNotes);
    forces = List<IncidentForce>.of(initialForces);
  }

  final bool _guest;
  int requestIncidentSelectionCalls = 0;
  int leaveUnitCalls = 0;

  @override
  bool get needsAuthentication => false;

  @override
  bool get needsIncidentSelection => false;

  @override
  bool get isGuest => _guest;

  @override
  bool get requiresIncident => !_guest && currentIncident == null;

  @override
  Future<void> init() async {}

  @override
  Future<void> checkUpdateSilently() async {}

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<void> refreshNow() async {}

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => const <ChatMessage>[];

  @override
  void requestIncidentSelection() {
    requestIncidentSelectionCalls++;
  }

  @override
  Future<void> leaveUnit() async {
    leaveUnitCalls++;
  }

  @override
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final created = Note(
      id: 'n-${notes.length + 1}',
      text: text,
      category: category ?? NoteCategory.fromText(text),
      author: '张三',
      createdAt: now,
      updatedAt: now,
    );
    notes = <Note>[created, ...notes];
    notifyListeners();
    return created;
  }
}

Incident _sampleIncident() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return Incident(
    id: 'inc-assembly-1',
    number: '20261122-001',
    title: '示例路厂房火灾',
    status: 'active',
    createdAt: now - 600000,
    lastActivityAt: now,
    info: const <String, dynamic>{
      'location': '示例市示例路88号',
      'original_category': '二级火灾扑救',
      'disaster_category': 'fire',
    },
  );
}

Entry _sampleActiveEntry() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return Entry(
    id: 'entry-1',
    name: '张三',
    pressureMpa: 22.0,
    durationMin: 25,
    entryAt: now - 300000,
    exitAt: now + 12 * 60000,
    source: 'voice',
  );
}

Note _sampleNote() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return Note(
    id: 'note-1',
    text: '北侧二楼已出一支水枪堵截火势',
    category: NoteCategory.deploy,
    author: '李四',
    createdAt: now - 60000,
    updatedAt: now - 60000,
  );
}

CommandAppShell _buildAssemblyShell(
  _AssemblyFakeController controller, {
  VideoPlaybackSession? videoPlayback,
}) {
  return CommandAppShell(
    controller: controller,
    videoPlayback: videoPlayback,
    enableStartupSideEffects: false,
    monitorTabBuilder: (_) => const Center(
      child: Text('现场监控桩页', key: Key('assembly-monitor-stub')),
    ),
    copilotTabBuilder: (_) => const Center(
      child: Text('智能辅助桩页', key: Key('assembly-copilot-stub')),
    ),
    mineTabBuilder: (_) => const Center(
      child: Text('我的桩页', key: Key('assembly-mine-stub')),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    ThemeController.instance.resetForTest();
    SystemPip.resetForTesting();
  });

  tearDown(() {
    SystemPip.resetForTesting();
  });

  group('CommandHomeAssembly 指挥台与工具域外壳接线测试', () {
    testWidgets('Tab 0 渲染 CommandHomePage、态势卡、3秒态势卡跳 Tab 1 及打开日志全量时间线', (
      tester,
    ) async {
      final controller = _AssemblyFakeController(
        incident: _sampleIncident(),
        initialEntries: <Entry>[_sampleActiveEntry()],
        initialNotes: <Note>[_sampleNote()],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildAssemblyShell(controller));
      await tester.pumpAndSettle();

      expect(find.byType(CommandHomePage), findsOneWidget);
      expect(find.byType(IncidentSituationCard), findsOneWidget);
      expect(find.byType(CommanderBriefCard), findsOneWidget);
      expect(find.text('示例路厂房火灾'), findsOneWidget);
      expect(find.text('1 人进入火场'), findsOneWidget);

      // 点击 3 秒态势卡跳 Tab 1（现场监控）
      await tester.tap(find.byKey(const Key('command-glance-card')));
      await tester.pumpAndSettle();
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);

      // 切回 Tab 0 并打开火场日志全量时间线
      await tester.tap(find.byKey(ShellKeys.tabCommand));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('command-home-scroll')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('command-notes-see-all-btn')));
      await tester.pumpAndSettle();

      expect(find.byType(NotesTimelineScreen), findsOneWidget);
      expect(find.text('北侧二楼已出一支水枪堵截火势'), findsOneWidget);
    });

    testWidgets('无警情但已认证时展示 9 项无锁现场工具并可正常调度警情上报/危化/重点单位/视频资源', (
      tester,
    ) async {
      final controller = _AssemblyFakeController(guest: false);
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildAssemblyShell(controller));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-no-incident-card')), findsOneWidget);
      for (final toolId in const <String>[
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
        expect(find.byKey(Key('tool-$toolId')), findsOneWidget);
        expect(find.byKey(Key('ds-tool-lock-$toolId')), findsNothing);
      }

      // 1. 警情上报 -> TacticalBriefCommandSheet
      await tester.tap(find.byKey(const Key('tool-警情上报')));
      await tester.pumpAndSettle();
      expect(find.byType(TacticalBriefCommandSheet), findsOneWidget);
      Navigator.of(tester.element(find.byType(TacticalBriefCommandSheet))).pop();
      await tester.pumpAndSettle();

      // 2. 危化速查 -> DS v3.0 HazmatPage
      await tester.tap(find.byKey(const Key('tool-危化速查')));
      await tester.pumpAndSettle();
      expect(find.byType(HazmatPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(HazmatPage))).pop();
      await tester.pumpAndSettle();

      // 3. 重点单位库 -> DS v3.0 KeySitesPage
      await tester.tap(find.byKey(const Key('tool-重点单位')));
      await tester.pumpAndSettle();
      expect(find.byType(KeySitesPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(KeySitesPage))).pop();
      await tester.pumpAndSettle();

      // 4. 视频资源 -> DS v3.0 VideoResourcesPage
      await tester.tap(find.byKey(const Key('tool-视频资源')));
      await tester.pumpAndSettle();
      expect(find.byType(VideoResourcesPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(VideoResourcesPage))).pop();
      await tester.pumpAndSettle();

      // 5. 点击「选择或新建警情」触发 requestIncidentSelection
      await tester.tap(find.byKey(const Key('choose-incident-from-home')));
      await tester.pumpAndSettle();
      expect(controller.requestIncidentSelectionCalls, 1);
    });

    testWidgets('游客模式现场工具实行六锁三开门禁：6项加锁拦截并引导认证，3项开放直达', (
      tester,
    ) async {
      final controller = _AssemblyFakeController(guest: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildAssemblyShell(controller));
      await tester.pumpAndSettle();

      const lockedTools = <String>[
        '重点单位',
        '视频资源',
        '路况查询',
        '警情上报',
        '现场地图',
        '周边水源',
      ];
      const openTools = <String>[
        '危化速查',
        '水印相机',
        '定位分享',
      ];

      for (final toolId in lockedTools) {
        expect(
          find.byKey(Key('tool-$toolId')),
          findsOneWidget,
          reason: '锁定工具 $toolId 应在宫格中保留展示',
        );
        expect(
          find.byKey(Key('ds-tool-lock-$toolId')),
          findsOneWidget,
          reason: '游客模式下 $toolId 应展示锁定角标',
        );
      }
      for (final toolId in openTools) {
        expect(find.byKey(Key('tool-$toolId')), findsOneWidget);
        expect(
          find.byKey(Key('ds-tool-lock-$toolId')),
          findsNothing,
          reason: '游客开放工具 $toolId 不应展示锁定角标',
        );
      }

      // 逐一验证 6 项锁定工具均被统一门禁拦截且点击「暂不认证」不触发导航
      for (final toolId in lockedTools) {
        await tester.ensureVisible(find.byKey(Key('tool-$toolId')));
        await tester.tap(find.byKey(Key('tool-$toolId')));
        await tester.pumpAndSettle();

        expect(
          find.text('需要转为正式队员'),
          findsOneWidget,
          reason: '点击 $toolId 应弹出认证引导抽屉',
        );
        expect(find.byType(KeySitesPage), findsNothing);
        expect(find.byType(VideoResourcesPage), findsNothing);
        expect(find.byType(RouteTrafficPage), findsNothing);
        expect(find.byType(TacticalBriefCommandSheet), findsNothing);
        expect(find.byType(SceneMapPage), findsNothing);
        expect(find.byType(WaterSourcesPage), findsNothing);

        await tester.tap(find.byKey(const Key('guest-tool-gate-cancel-btn')));
        await tester.pumpAndSettle();
        expect(find.text('需要转为正式队员'), findsNothing);
        expect(controller.leaveUnitCalls, 0);
      }

      // 验证点击「去完成认证」调用 controller.leaveUnit() 返回认证流程
      await tester.tap(find.byKey(const Key('tool-重点单位')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('guest-tool-gate-auth-btn')));
      await tester.pumpAndSettle();
      expect(controller.leaveUnitCalls, 1);
      expect(find.byType(KeySitesPage), findsNothing);

      // 验证开放工具可正常进入（危化速查 -> HazmatPage）
      await tester.tap(find.byKey(const Key('tool-危化速查')));
      await tester.pumpAndSettle();
      expect(find.text('需要转为正式队员'), findsNothing);
      expect(find.byType(HazmatPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(HazmatPage))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('展开态势卡可进入 DS v3.0 IncidentDetailsScreen 且点击连接状态弹出 ConnectionDetailSheet', (
      tester,
    ) async {
      final controller = _AssemblyFakeController(incident: _sampleIncident());
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildAssemblyShell(controller));
      await tester.pumpAndSettle();

      // 打开连接与同步状态抽屉
      await tester.tap(find.byType(ConnectionPill).first);
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionDetailSheet), findsOneWidget);
      Navigator.of(tester.element(find.byType(ConnectionDetailSheet))).pop();
      await tester.pumpAndSettle();

      // 展开态势卡 -> 打开 DS v3.0 警情详情页
      await tester.tap(find.byKey(const Key('toggle-incident-card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-incident-details')));
      await tester.pumpAndSettle();
      expect(find.byType(IncidentDetailsScreen), findsOneWidget);
    });

    testWidgets('悬浮视频窗默认挂载 DS v3.0 FloatingVideoOverlay，360dp @ 130% 昼白/暗曜零溢出', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final controller = _AssemblyFakeController(
        incident: _sampleIncident(),
        initialEntries: <Entry>[_sampleActiveEntry()],
        initialNotes: <Note>[_sampleNote()],
      );
      final video = VideoPlaybackSession.forTesting(
        resource: const VideoResource(
          id: 'cam-1',
          name: '示例监控通道',
          streamUrl: 'https://video.example.test/cam1.flv',
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(video.dispose);

      await tester.pumpWidget(
        _buildAssemblyShell(controller, videoPlayback: video),
      );
      await tester.pumpAndSettle();

      video.enterFloating();
      await tester.pumpAndSettle();
      expect(find.byType(FloatingVideoOverlay), findsOneWidget);
      expect(tester.takeException(), isNull);

      ThemeController.instance.select(AppThemePreference.night);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
