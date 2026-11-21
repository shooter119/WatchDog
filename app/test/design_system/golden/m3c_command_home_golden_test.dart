@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/command_home/ui/command_home_page.dart';
import 'package:watchdog/features/command_home/ui/widgets/field_tools_grid_section.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/data/models/incident_force.dart';
import 'package:watchdog/features/incident/ui/widgets/incident_situation_card.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/features/notes/state/notes_store.dart';
import 'package:watchdog/features/notes/ui/notes_timeline_screen.dart';
import 'package:watchdog/features/notes/ui/widgets/note_preview_section.dart';
import 'package:watchdog/services/tactical_brief_engine.dart';

final DateTime _fixedNow = DateTime(2026, 5, 14, 14, 30, 0);
final int _fixedNowMs = _fixedNow.millisecondsSinceEpoch;

Incident _goldenIncident() => Incident(
  id: 'inc-golden-1',
  number: '2026-05-14-01',
  title: '示例商业综合体二层餐饮起火',
  info: const <String, dynamic>{
    'location': '示例县示范大道88号',
    'original_category': '二级火灾扑救',
    'incident_status': '到场',
  },
  status: 'active',
  createdAt: _fixedNowMs - 25 * 60000,
  lastActivityAt: _fixedNowMs,
);

List<IncidentForce> _goldenForces() => const <IncidentForce>[
  IncidentForce(
    id: 'f1',
    incidentId: 'inc-golden-1',
    stationName: '示例路站',
    vehicleCount: 3,
    personnelCount: 15,
    createdAt: 1,
    updatedAt: 1,
    version: 1,
  ),
  IncidentForce(
    id: 'f2',
    incidentId: 'inc-golden-1',
    stationName: '和平路站',
    vehicleCount: 2,
    personnelCount: 10,
    createdAt: 1,
    updatedAt: 1,
    version: 1,
  ),
];

List<Note> _goldenNotes() => <Note>[
  Note(
    id: 'n1',
    text: '二层东侧厨房油烟道明火较大，注意防轰燃',
    category: NoteCategory.abnormal,
    author: '张三',
    createdAt: _fixedNowMs - 2 * 60000,
    updatedAt: _fixedNowMs - 2 * 60000,
  ),
  Note(
    id: 'n2',
    text: '一号水枪阵地已出水压制火势蔓延',
    category: NoteCategory.water,
    author: '李四',
    createdAt: _fixedNowMs - 5 * 60000,
    updatedAt: _fixedNowMs - 5 * 60000,
  ),
  Note(
    id: 'n3',
    text: '内攻搜救组疏散二层全部群众，无人被困',
    category: NoteCategory.rescue,
    author: '王五',
    createdAt: _fixedNowMs - 11 * 60000,
    updatedAt: _fixedNowMs - 11 * 60000,
  ),
];

Future<void> _pumpGolden(
  WidgetTester tester, {
  required Brightness brightness,
  required GlobalKey captureKey,
  required Widget child,
}) async {
  const surfaceSize = Size(390, 844);
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(key: captureKey, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3c CommandHome active ($themeTag)', (
      WidgetTester tester,
    ) async {
      final captureKey = GlobalKey();
      final notes = _goldenNotes();

      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: CommandHomePage(
          hasIncident: true,
          incidentCardSlot: IncidentSituationCard(
            incident: _goldenIncident(),
            forces: _goldenForces(),
            hasActiveEntries: true,
            highestRiskStatus: DsStatus.alarm,
            highestRiskLabel: '最高风险 · 告警',
            initialExpanded: false,
            now: _fixedNow,
          ),
          airSafetySummary: const AirSafetySummary(
            activeCount: 4,
            shortestName: '赵六',
            shortestRemainingMin: 4,
            level: AirSafetyLevel.critical,
          ),
          tacticalProgress: '二层东侧厨房油烟道明火较大，注意防轰燃',
          hasCriticalHazards: true,
          onOpenMonitor: () {},
          tools: FieldToolsGridSection.buildDefaultTools(
            onKeySites: () {},
            onHazmat: () {},
            onCamera: () {},
            onLocationShare: () {},
            onVideoResources: () {},
            onRouteTraffic: () {},
            onTacticalBrief: () {},
            onSceneMap: () {},
            onWaterSources: () {},
          ),
          notesPreviewSlot: NotePreviewSection(
            notes: notes,
            maxItems: 3,
            onSeeAll: () {},
            now: _fixedNow,
          ),
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3c_command_home_active_$themeTag.png'),
      );
    });

    testWidgets('M3c CommandHome empty ($themeTag)', (
      WidgetTester tester,
    ) async {
      final captureKey = GlobalKey();

      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: CommandHomePage(
          hasIncident: false,
          onChooseIncident: () {},
          tools: FieldToolsGridSection.buildDefaultTools(
            onKeySites: () {},
            onHazmat: () {},
            onCamera: () {},
            onLocationShare: () {},
            onVideoResources: () {},
            onRouteTraffic: () {},
            onTacticalBrief: () {},
            onSceneMap: () {},
            onWaterSources: () {},
          ),
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3c_command_home_empty_$themeTag.png'),
      );
    });

    testWidgets('M3c NotesTimelineScreen ($themeTag)', (
      WidgetTester tester,
    ) async {
      final store = NotesStore(initialNotes: _goldenNotes());
      addTearDown(store.dispose);
      final captureKey = GlobalKey();

      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: NotesTimelineScreen(
          store: store,
          onOpenTacticalBrief: () {},
          now: _fixedNow,
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3c_notes_timeline_$themeTag.png'),
      );
    });
  }
}
