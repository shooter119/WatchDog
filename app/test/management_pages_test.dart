import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/archived_incidents_page.dart';
import 'package:watchdog/pages/roster_page.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

class _ManagementApi extends ApiClient {
  _ManagementApi({
    List<Firefighter> firefighters = const [],
    List<Hotword> hotwords = const [],
    List<Incident> archived = const [],
  }) : firefighters = [...firefighters],
       hotwords = [...hotwords],
       archived = [...archived],
       super(baseUrl: 'http://test', incidentId: 'incident-for-test');

  final List<Firefighter> firefighters;
  final List<Hotword> hotwords;
  final List<Incident> archived;

  @override
  Future<List<Firefighter>> fetchFirefighters() async => [...firefighters];

  @override
  Future<bool> addFirefighter(String name) async {
    if (firefighters.any((item) => item.name == name)) return false;
    firefighters.add(
      Firefighter(id: 'firefighter-${firefighters.length}', name: name),
    );
    return true;
  }

  @override
  Future<void> removeFirefighter(String id) async {
    firefighters.removeWhere((item) => item.id == id);
  }

  @override
  Future<List<Hotword>> fetchHotwords() async => [...hotwords];

  @override
  Future<void> addHotword(String word) async {
    if (hotwords.any((item) => item.word == word)) return;
    hotwords.add(Hotword(id: 'hotword-${hotwords.length}', word: word));
  }

  @override
  Future<void> removeHotword(String id) async {
    hotwords.removeWhere((item) => item.id == id);
  }

  @override
  Future<List<Incident>> fetchIncidents({String? status}) async => [
    ...archived,
  ];

  @override
  Future<Incident> updateIncidentTitle(
    String id,
    String? title, {
    required int expectedVersion,
  }) async {
    final index = archived.indexWhere((item) => item.id == id);
    final old = archived[index];
    final updated = Incident(
      id: old.id,
      number: old.number,
      title: title,
      suggestedTitle: old.suggestedTitle,
      status: old.status,
      createdAt: old.createdAt,
      lastActivityAt: old.lastActivityAt,
      archivedAt: old.archivedAt,
      archivedBy: old.archivedBy,
      autoArchived: old.autoArchived,
      unresolvedActiveCount: old.unresolvedActiveCount,
      version: old.version + 1,
      forceStationCount: old.forceStationCount,
      vehicleCount: old.vehicleCount,
      personnelCount: old.personnelCount,
    );
    archived[index] = updated;
    return updated;
  }
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(MaterialApp(theme: buildAppTheme(), home: page));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('名单管理页加载、添加与删除确认均走管理接口', (tester) async {
    final api = _ManagementApi(
      firefighters: [Firefighter(id: 'f-1', name: '张伟')],
      hotwords: [Hotword(id: 'h-1', word: '空气呼吸器')],
    );
    final controller = AppController()
      ..api = api
      ..firefighters = [...api.firefighters]
      ..hotwords = [...api.hotwords];
    addTearDown(controller.dispose);

    await _pumpPage(tester, RosterPage(controller: controller));
    await controller.loadRoster();
    await tester.pump();
    expect(find.text('张伟'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '李娜');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await controller.loadRoster();
    await tester.pump();
    expect(find.text('李娜'), findsOneWidget);

    await tester.tap(find.byTooltip('删除').first);
    await tester.pumpAndSettle();
    expect(find.text('删除「张伟」？'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(api.firefighters.map((item) => item.name), isNot(contains('张伟')));
    expect(
      controller.firefighters.map((item) => item.name),
      isNot(contains('张伟')),
    );
    await controller.loadRoster();
    await tester.pump();
    expect(find.text('张伟'), findsNothing);
  });

  testWidgets('归档警情页展示档案并支持修改名称', (tester) async {
    final archived = Incident(
      id: 'archived-1',
      number: '2026-001',
      title: '旧警情名称',
      status: 'archived',
      createdAt: 1,
      lastActivityAt: 2,
      archivedAt: 3,
      forceStationCount: 1,
      vehicleCount: 2,
      personnelCount: 7,
    );
    final api = _ManagementApi(archived: [archived]);
    final controller = AppController()..api = api;
    addTearDown(controller.dispose);

    await _pumpPage(tester, ArchivedIncidentsPage(controller: controller));
    expect(find.text('旧警情名称'), findsOneWidget);
    expect(find.text('份档案'), findsOneWidget);

    await tester.tap(find.byTooltip('修改名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '更新后的警情名称');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('更新后的警情名称'), findsOneWidget);
    expect(find.text('旧警情名称'), findsNothing);
  });
}
