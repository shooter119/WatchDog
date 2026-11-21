import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/roster/data/models/firefighter.dart';
import 'package:watchdog/features/roster/data/models/hotword.dart';
import 'package:watchdog/features/roster/ui/archived_incident_cards.dart';
import 'package:watchdog/features/roster/ui/archived_incident_detail_page.dart';
import 'package:watchdog/features/roster/ui/archived_incidents_page.dart';
import 'package:watchdog/features/roster/ui/roster_batch_import_sheet.dart';
import 'package:watchdog/features/roster/ui/roster_page.dart';

class _FakeRosterGateway extends ChangeNotifier implements RosterPageGateway {
  _FakeRosterGateway({
    List<Firefighter> firefighters = const <Firefighter>[],
    List<Hotword> hotwords = const <Hotword>[],
    this.canReviewMembers = false,
    this.pendingMemberCount = 0,
  }) : _firefighters = <Firefighter>[...firefighters],
       _hotwords = <Hotword>[...hotwords];

  final List<Firefighter> _firefighters;
  final List<Hotword> _hotwords;
  @override
  bool canReviewMembers;
  @override
  int pendingMemberCount;
  String? failName;

  @override
  Listenable get changes => this;
  @override
  List<Firefighter> get firefighters => List<Firefighter>.unmodifiable(_firefighters);
  @override
  List<Hotword> get hotwords => List<Hotword>.unmodifiable(_hotwords);

  @override
  Future<void> loadRoster() async {
    notifyListeners();
  }

  @override
  Future<void> refreshPendingMembersCount() async {
    notifyListeners();
  }

  @override
  Future<bool> addFirefighter(String name) async {
    if (name == failName) throw StateError('模拟写入失败');
    if (_firefighters.any((item) => item.name == name)) return false;
    _firefighters.add(
      Firefighter(id: 'f-${_firefighters.length + 1}', name: name),
    );
    return true;
  }

  @override
  Future<void> removeFirefighter(String id) async {
    _firefighters.removeWhere((item) => item.id == id);
  }

  @override
  Future<void> addHotword(String word) async {
    if (_hotwords.any((item) => item.word == word)) return;
    _hotwords.add(Hotword(id: 'h-${_hotwords.length + 1}', word: word));
  }

  @override
  Future<void> removeHotword(String id) async {
    _hotwords.removeWhere((item) => item.id == id);
  }
}

class _FakeArchivedGateway implements ArchivedIncidentsGateway {
  _FakeArchivedGateway({
    List<ArchivedIncidentView> incidents = const <ArchivedIncidentView>[],
    this.events = const <ArchivedIncidentEventView>[],
    this.forces = const <ArchivedIncidentForceView>[],
  }) : _incidents = <ArchivedIncidentView>[...incidents];

  final List<ArchivedIncidentView> _incidents;
  final List<ArchivedIncidentEventView> events;
  final List<ArchivedIncidentForceView> forces;

  @override
  Future<List<ArchivedIncidentView>> fetchArchivedIncidents() async =>
      <ArchivedIncidentView>[..._incidents];

  @override
  Future<ArchivedIncidentView> renameIncident(
    ArchivedIncidentView incident,
    String title,
  ) async {
    final index = _incidents.indexWhere((item) => item.id == incident.id);
    final updated = incident.copyWithTitle(title);
    if (index >= 0) _incidents[index] = updated;
    return updated;
  }

  @override
  Future<List<ArchivedIncidentEventView>> fetchTimeline(
    String incidentId,
  ) async => events;

  @override
  Future<List<ArchivedIncidentForceView>> fetchForces(
    String incidentId,
  ) async => forces;
}

Widget _wrapDs(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? appChild) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: appChild!,
    ),
    home: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('批量粘贴姓名提取支持 Excel 首列、去空格与职务词过滤', () {
    const sample = '张 伟\t战斗员\n站长\n李娜 大队长\n王强\n装 备 技 师\n赵敏';
    expect(
      extractNamesFromPaste(sample),
      equals(<String>['张伟', '李娜', '王强', '赵敏']),
    );
  });

  testWidgets('名单与热词页支持双 Tab、新增、内置项保护、入队审批入口与 CommandSheet 删除二次确认', (
    WidgetTester tester,
  ) async {
    final gateway = _FakeRosterGateway(
      firefighters: <Firefighter>[
        Firefighter(id: 'f-1', name: '张伟'),
        Firefighter(id: 'f-builtin', name: '内置示例', source: 'builtin'),
      ],
      hotwords: <Hotword>[Hotword(id: 'h-1', word: '空气呼吸器')],
      canReviewMembers: true,
      pendingMemberCount: 3,
    );
    addTearDown(gateway.dispose);
    var reviewOpened = 0;

    await tester.pumpWidget(
      _wrapDs(
        RosterPage(
          gateway: gateway,
          onOpenMemberReview: (_) async => reviewOpened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('本名单只用于提升语音识别准确率，不授予登录权限；成员能否登录由『设置 → 入队审批』批准决定。'),
      findsOneWidget,
    );
    expect(find.text('张伟'), findsOneWidget);
    expect(find.text('入队审批 (3)'), findsOneWidget);

    await tester.tap(find.text('入队审批 (3)'));
    await tester.pumpAndSettle();
    expect(reviewOpened, 1);

    await tester.enterText(find.byType(TextField), '李娜');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('李娜'), findsOneWidget);

    // 内置项无删除按钮，可删除项共 2 枚（张伟、李娜）
    expect(find.byTooltip('删除'), findsNWidgets(2));
    await tester.tap(find.byTooltip('删除').first);
    await tester.pumpAndSettle();
    expect(find.text('删除「张伟」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(CommandButton, '删除'));
    await tester.pumpAndSettle();
    expect(gateway.firefighters.map((f) => f.name), isNot(contains('张伟')));
    expect(find.text('张伟'), findsNothing);

    // 切换至专业术语 Tab 并新增术语
    await tester.tap(find.text('专业术语'));
    await tester.pumpAndSettle();
    expect(find.text('空气呼吸器'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '正压式');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('正压式'), findsOneWidget);
  });

  testWidgets('名单批量导入面板支持去重与失败计数汇总', (WidgetTester tester) async {
    final gateway = _FakeRosterGateway(
      firefighters: <Firefighter>[Firefighter(id: 'f-1', name: '张伟')],
    )..failName = '王强';
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_wrapDs(RosterPage(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('批量导入'));
    await tester.pumpAndSettle();
    expect(find.text('批量导入姓名'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '张伟\n李娜\n李娜\n王强');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('导入完成：新增 1 人，跳过重复 2 个，失败 1 个（可重试）'), findsOneWidget);
    expect(find.text('李娜'), findsOneWidget);
  });

  testWidgets('归档警情页支持档案展示、修改名称与进入复盘详情', (WidgetTester tester) async {
    const archived = ArchivedIncidentView(
      id: 'archived-1',
      number: '2026-001',
      title: '旧警情名称',
      createdAt: 1700000000000,
      lastActivityAt: 1700000100000,
      archivedAt: 1700000200000,
      autoArchived: true,
      unresolvedActiveCount: 2,
      forceStationCount: 2,
      vehicleCount: 3,
      personnelCount: 12,
    );
    final gateway = _FakeArchivedGateway(
      incidents: const <ArchivedIncidentView>[archived],
      forces: const <ArchivedIncidentForceView>[
        ArchivedIncidentForceView(
          stationName: '示例路站',
          vehicleLabel: '2 车',
          personnelLabel: '8 人',
        ),
      ],
      events: const <ArchivedIncidentEventView>[
        ArchivedIncidentEventView(
          type: 'entry',
          text: '张伟进场',
          occurredAt: 1700000050000,
          actorName: '指挥员甲',
          source: 'offline',
          revisionOf: 'ev-0',
        ),
      ],
    );
    var detailOpened = 0;

    await tester.pumpWidget(
      _wrapDs(
        ArchivedIncidentsPage(
          gateway: gateway,
          onOpenDetails: (_, __) async => detailOpened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('旧警情名称'), findsOneWidget);
    expect(find.text('份档案'), findsOneWidget);
    expect(find.text('自动归档'), findsOneWidget);

    await tester.tap(find.byTooltip('修改名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '更新后的警情名称');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('更新后的警情名称'), findsOneWidget);
    expect(find.text('旧警情名称'), findsNothing);

    await tester.tap(find.text('更新后的警情名称'));
    await tester.pumpAndSettle();

    expect(find.text('火场复盘'), findsOneWidget);
    expect(find.text('归档时有 2 名人员未确认离场'), findsOneWidget);
    expect(find.text('示例路站'), findsOneWidget);
    expect(find.text('张伟进场'), findsOneWidget);
    expect(find.text('离线补传'), findsOneWidget);
    expect(find.text('修订记录'), findsOneWidget);

    await tester.tap(find.text('警情资料与导入记录'));
    await tester.pumpAndSettle();
    expect(detailOpened, 1);
  });

  testWidgets('360dp 窄屏与 130% 字号下昼白/暗曜双主题零溢出（名单/归档/复盘）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const longIncident = ArchivedIncidentView(
      id: 'arc-long',
      number: '2026-示例园区-099',
      title: '示例化工园区北侧危化品装卸区夜间联合处置演练归档记录',
      createdAt: 1700000000000,
      lastActivityAt: 1700000300000,
      archivedAt: 1700000600000,
      autoArchived: true,
      unresolvedActiveCount: 3,
      forceStationCount: 4,
      vehicleCount: 9,
      personnelCount: 36,
      unknownVehicleStationCount: 1,
      unknownPersonnelStationCount: 1,
    );

    for (final brightness in const <Brightness>[
      Brightness.light,
      Brightness.dark,
    ]) {
      final rosterGateway = _FakeRosterGateway(
        firefighters: <Firefighter>[
          Firefighter(id: 'f-1', name: '张伟'),
          Firefighter(id: 'f-2', name: '示例超长姓名队员测试'),
        ],
        canReviewMembers: true,
        pendingMemberCount: 5,
      );
      await tester.pumpWidget(
        _wrapDs(
          RosterPage(gateway: rosterGateway, isOffline: true),
          brightness: brightness,
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final archiveGateway = _FakeArchivedGateway(
        incidents: const <ArchivedIncidentView>[longIncident],
        forces: const <ArchivedIncidentForceView>[
          ArchivedIncidentForceView(
            stationName: '示例高新区特勤一站',
            vehicleLabel: '4 车',
            personnelLabel: '18 人',
          ),
        ],
        events: const <ArchivedIncidentEventView>[
          ArchivedIncidentEventView(
            type: 'pressure',
            text: '张伟报压 18.5 MPa，剩余约 24 分钟',
            occurredAt: 1700000200000,
            actorName: '安全员乙',
          ),
        ],
      );
      await tester.pumpWidget(
        _wrapDs(
          ArchivedIncidentsPage(gateway: archiveGateway, isOffline: true),
          brightness: brightness,
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _wrapDs(
          ArchivedIncidentDetailPage(
            incident: longIncident,
            gateway: archiveGateway,
            onOpenDetails: (_, __) async {},
            isOffline: true,
          ),
          brightness: brightness,
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      rosterGateway.dispose();
    }
  });
}
