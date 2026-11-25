import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/data/models/external_incident.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/data/models/incident_create_conflict_exception.dart';
import 'package:watchdog/features/incident/ui/incident_picker_page.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_basic_info_sheet.dart';

void main() {
  final fixedNow = DateTime(2026, 11, 7, 16, 0);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  final customIncident = Incident(
    id: 'custom-inc-1',
    number: '202611071001#警情',
    title: '南区综合演练现场',
    status: 'active',
    createdAt: DateTime(2026, 11, 7, 15, 30).millisecondsSinceEpoch,
    lastActivityAt: DateTime(2026, 11, 7, 15, 30).millisecondsSinceEpoch,
  );

  final claimedExternal = ExternalIncident(
    externalId: 'ext-claimed-1',
    incidentNumber: '2026110712345601',
    detachmentName: '示例市支队',
    brigadeName: '示例区大队',
    districtName: '示例区',
    incidentType: '火灾扑救',
    crimeAddress: '示例区文化街88号',
    registerTime: DateTime(2026, 11, 7, 15, 20).millisecondsSinceEpoch,
    claimed: true,
    claimedIncidentId: 'claimed-local-id',
  );

  final unclaimedExternal = ExternalIncident(
    externalId: 'ext-unclaimed-2',
    incidentNumber: '2026110712345602',
    detachmentName: '示例市支队',
    brigadeName: '示例县大队',
    districtName: '示例县',
    incidentType: '抢险救援',
    crimeAddress: '示例县示范广场',
    registerTime: DateTime(2026, 11, 7, 15, 45).millisecondsSinceEpoch,
    claimed: false,
  );

  Widget wrap(
    Widget child, {
    Brightness brightness = Brightness.light,
    double textScale = 1.0,
  }) {
    return MaterialApp(
      theme: buildCommandTheme(brightness),
      themeAnimationDuration: Duration.zero,
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

  testWidgets('混合列表统一展示【进入】按钮、独立【自建】/辖区标签及【处置中】提示', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Incident? selectedIncident;
    ExternalIncident? claimedIncident;
    bool createTriggered = false;
    bool refreshTriggered = false;
    bool enterWithoutTriggered = false;

    await tester.pumpWidget(
      wrap(
        IncidentPickerPage(
          activeIncidents: <Incident>[customIncident],
          externalIncidents: <ExternalIncident>[claimedExternal, unclaimedExternal],
          loading: false,
          now: fixedNow,
          onSelect: (inc) async => selectedIncident = inc,
          onCreate: () async => createTriggered = true,
          onClaimExternal: (ext) async => claimedIncident = ext,
          onRefreshExternal: ({bool forceRefresh = false}) async {
            refreshTriggered = true;
          },
          onEnterWithoutIncident: () => enterWithoutTriggered = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('进入'), findsNWidgets(3));
    expect(find.text('加入'), findsNothing);
    expect(find.text('待认领'), findsNothing);
    expect(find.text('自建'), findsOneWidget);
    expect(find.text('南区综合演练现场'), findsOneWidget);
    expect(find.text('处置中'), findsOneWidget);
    expect(find.text('示例区'), findsOneWidget);
    expect(find.text('示例区文化街88号'), findsOneWidget);
    expect(find.text('示例县示范广场'), findsOneWidget);
    expect(find.text('示例县'), findsOneWidget);
    expect(find.text('新建警情'), findsOneWidget);
    expect(find.text('直接进入 App'), findsOneWidget);

    await tester.tap(find.text('示例县示范广场'));
    await tester.pumpAndSettle();
    expect(claimedIncident?.externalId, 'ext-unclaimed-2');

    await tester.tap(find.text('南区综合演练现场'));
    await tester.pumpAndSettle();
    expect(selectedIncident?.id, 'custom-inc-1');

    await tester.tap(find.text('新建警情'));
    await tester.pumpAndSettle();
    expect(createTriggered, isTrue);

    await tester.tap(find.text('直接进入 App'));
    await tester.pumpAndSettle();
    expect(enterWithoutTriggered, isTrue);

    await tester.tap(find.byTooltip('刷新派警列表'));
    await tester.pumpAndSettle();
    expect(refreshTriggered, isTrue);
  });

  testWidgets('搜索框可实时过滤混合警情列表并支持一键清除恢复', (tester) async {
    await tester.pumpWidget(
      wrap(
        IncidentPickerPage(
          activeIncidents: <Incident>[customIncident],
          externalIncidents: <ExternalIncident>[claimedExternal, unclaimedExternal],
          loading: false,
          now: fixedNow,
          onSelect: (_) async {},
          onCreate: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '示范');
    await tester.pumpAndSettle();
    expect(find.text('南区综合演练现场'), findsNothing);
    expect(find.text('示例区文化街88号'), findsNothing);
    expect(find.text('示例县示范广场'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('南区综合演练现场'), findsOneWidget);
    expect(find.text('示例区文化街88号'), findsOneWidget);
    expect(find.text('示例县示范广场'), findsOneWidget);
  });

  testWidgets('按用户大队强隔离展示警情列表', (tester) async {
    await tester.pumpWidget(
      wrap(
        IncidentPickerPage(
          userUnitName: '示例县消防救援大队',
          activeIncidents: <Incident>[customIncident],
          externalIncidents: <ExternalIncident>[claimedExternal, unclaimedExternal],
          loading: false,
          now: fixedNow,
          onSelect: (_) async {},
          onCreate: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('南区综合演练现场'), findsOneWidget);
    expect(find.text('示例县示范广场'), findsOneWidget);
    expect(find.text('示例区文化街88号'), findsNothing);
  });

  testWidgets('优先突出事件主标题、三分类徽标与条件出动力量且搜索栏仅保留刷新按钮', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    var refreshCalled = false;
    final aiIncident = ExternalIncident(
      externalId: 'ext-ai-1',
      incidentNumber: '20261114001',
      detachmentName: '示例支队',
      brigadeName: '示例大队',
      squadronName: '示例路站',
      districtName: '示例县',
      incidentType: '抢险救援',
      eventSummary: '货车追尾驾驶室人员被困',
      disasterCategory: 'rescue',
      locationDisplay: '示例县建设大道66号',
      crimeAddress: '示例省示例市示例县建设大道66号',
      dispatchedForces: const <ExternalDispatchedForce>[
        ExternalDispatchedForce(stationName: '示例路站', vehicleCount: 2),
      ],
      factHighlights: const <String>['1人被困', '二级'],
      registerTime: fixedNow.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch,
    );
    final noForceIncident = ExternalIncident(
      externalId: 'ext-noforce-2',
      incidentNumber: '20261114002',
      detachmentName: '示例支队',
      brigadeName: '示例大队',
      districtName: '示例县',
      incidentType: '社会救助',
      eventSummary: '小区居民电梯困人救助',
      disasterCategory: 'aid',
      locationDisplay: '示例县幸福小区3栋',
      crimeAddress: '示例县幸福小区3栋',
      registerTime: fixedNow.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
    );

    await tester.pumpWidget(
      wrap(
        IncidentPickerPage(
          activeIncidents: const <Incident>[],
          externalIncidents: <ExternalIncident>[aiIncident, noForceIncident],
          loading: false,
          now: fixedNow,
          onSelect: (_) async {},
          onCreate: () async {},
          onRefreshExternal: ({bool forceRefresh = false}) async {
            refreshCalled = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('货车追尾驾驶室人员被困'), findsOneWidget);
    expect(find.text('小区居民电梯困人救助'), findsOneWidget);
    expect(find.byKey(const Key('ext-category-badge-ext_ext-ai-1-rescue')), findsOneWidget);
    expect(find.byKey(const Key('ext-category-badge-ext_ext-noforce-2-aid')), findsOneWidget);
    expect(find.text('示例县建设大道66号'), findsOneWidget);
    expect(find.text('示例路站 2车'), findsOneWidget);
    expect(find.text('1人被困'), findsOneWidget);
    expect(find.byKey(const Key('ext-forces-wrap-ext_ext-ai-1')), findsOneWidget);
    expect(find.byKey(const Key('ext-forces-wrap-ext_ext-noforce-2')), findsNothing);

    expect(find.byKey(const Key('external-reorganize-btn')), findsNothing);
    expect(find.byTooltip('AI重新整理警情'), findsNothing);
    final searchRow = find
        .ancestor(of: find.byType(TextField).first, matching: find.byType(Row))
        .first;
    expect(find.descendant(of: searchRow, matching: find.byType(IconButton)), findsOneWidget);
    final refreshBtn = find.byTooltip('刷新派警列表');
    expect(
      tester.getCenter(refreshBtn).dx,
      greaterThan(tester.getCenter(find.byType(TextField).first).dx),
    );
    await tester.tap(refreshBtn);
    await tester.pumpAndSettle();
    expect(refreshCalled, isTrue);
  });

  group('接警描述清洗、全文检索与跨区增援展示', () {
    test('ExternalIncident.effectiveEventTitle 清洗长段接警通报并保留常规短描述', () {
      const longDispatch = ExternalIncident(
        externalId: 'ext-clean-1',
        incidentNumber: '20261114101',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '抢险救援',
        crimeAddress: '示例省示例市示例县和平街9号',
        locationDisplay: '示例县和平街9号',
        incidentDescribe:
            '2026年11月13日22时45分，示例大队指挥中心接到群众报警称：位于示例省示例市示例县和平街9号发生两车追尾，驾驶员被困，无其他人员伤亡。接到报警后，示例路站出动2车（水罐车、抢险救援车）14人前往处置，官方状态: 出动',
        registerTime: 1786177140000,
      );
      expect(longDispatch.effectiveEventTitle, '发生两车追尾，驾驶员被困');

      const shortNormal = ExternalIncident(
        externalId: 'ext-clean-3',
        incidentNumber: '20261114103',
        incidentType: '火灾扑救',
        crimeAddress: '示例县幸福小区1栋',
        incidentDescribe: '民房厨房油锅起火',
        registerTime: 1786177140000,
      );
      expect(shortNormal.effectiveEventTitle, '民房厨房油锅起火');

      const boilerplateOnly = ExternalIncident(
        externalId: 'ext-clean-4',
        incidentNumber: '20261114104',
        incidentType: '社会救助',
        disposalObjectName: '马蜂窝',
        crimeAddress: '示例县滨河路12号',
        incidentDescribe: '00时26分，示例大队接警称：暂无人员被困，官方状态: 出动',
        registerTime: 1786177140000,
      );
      expect(boilerplateOnly.effectiveEventTitle, '社会救助（马蜂窝）');
    });

    testWidgets('搜索框支持按 incidentDescribe 与 disposalObjectName 全文过滤', (tester) async {
      const traffic = ExternalIncident(
        externalId: 'ext-search-1',
        incidentNumber: '20261114201',
        districtName: '示例县',
        incidentType: '抢险救援',
        disposalObjectName: '半挂货车',
        eventSummary: '高速交通事故处置',
        incidentDescribe: '示例县高速路口两车追尾，驾驶室变形',
        crimeAddress: '示例县高速路口',
        registerTime: 1786177140000,
      );
      const pit = ExternalIncident(
        externalId: 'ext-search-2',
        incidentNumber: '20261114202',
        districtName: '示例县',
        incidentType: '抢险救援',
        disposalObjectName: '深坑救援',
        eventSummary: '工地人员坠落救助',
        incidentDescribe: '一施工人员不慎坠入6米坑内，暂无生命危险',
        crimeAddress: '示例县工地2号门',
        registerTime: 1786177200000,
      );

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[],
            externalIncidents: const <ExternalIncident>[traffic, pit],
            loading: false,
            now: fixedNow,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '两车追尾');
      await tester.pumpAndSettle();
      expect(find.text('高速交通事故处置'), findsOneWidget);
      expect(find.text('工地人员坠落救助'), findsNothing);

      await tester.enterText(find.byType(TextField).first, '6米坑');
      await tester.pumpAndSettle();
      expect(find.text('高速交通事故处置'), findsNothing);
      expect(find.text('工地人员坠落救助'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '半挂货车');
      await tester.pumpAndSettle();
      expect(find.text('高速交通事故处置'), findsOneWidget);
      expect(find.text('工地人员坠落救助'), findsNothing);
    });

    testWidgets('跨区增援警情在 dispatchedForces 或 incidentDescribe 含本单位关键词时仍可见', (tester) async {
      const unrelated = ExternalIncident(
        externalId: 'ext-cross-0',
        incidentNumber: '20261114300',
        brigadeName: '示例东区大队',
        squadronName: '示例东路站',
        districtName: '示例东区',
        incidentType: '火灾扑救',
        eventSummary: '示例东区无关杂草起火',
        crimeAddress: '示例东区幸福路1号',
        dispatchedForces: <ExternalDispatchedForce>[
          ExternalDispatchedForce(stationName: '示例东路站', vehicleCount: 1),
        ],
        incidentDescribe: '示例东区空地杂草起火，示例东路站出动1车扑救',
        registerTime: 1786177100000,
      );
      const reinforceForces = ExternalIncident(
        externalId: 'ext-cross-1',
        incidentNumber: '20261114301',
        brigadeName: '示例东区大队',
        districtName: '示例东区',
        incidentType: '火灾扑救',
        eventSummary: '跨区联动厂房冒烟',
        crimeAddress: '示例东区工业大道2号',
        dispatchedForces: <ExternalDispatchedForce>[
          ExternalDispatchedForce(stationName: '示例县示例路站', vehicleCount: 1, personnelCount: 6),
        ],
        registerTime: 1786177140000,
      );
      const reinforceDesc = ExternalIncident(
        externalId: 'ext-cross-2',
        incidentNumber: '20261114302',
        brigadeName: '示例东区大队',
        districtName: '示例东区',
        incidentType: '抢险救援',
        eventSummary: '跨区增援危化品槽车处置',
        crimeAddress: '示例东区物流园3号',
        incidentDescribe: '示例东区高速口槽车侧翻，支队调派示例县示例路站跨区增援',
        registerTime: 1786177200000,
      );

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            userUnitName: '示例县消防救援大队',
            activeIncidents: const <Incident>[],
            externalIncidents: const <ExternalIncident>[unrelated, reinforceForces, reinforceDesc],
            loading: false,
            now: fixedNow,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('示例东区无关杂草起火'), findsNothing);
      expect(find.text('跨区联动厂房冒烟'), findsOneWidget);
      expect(find.text('跨区增援危化品槽车处置'), findsOneWidget);
    });
  });

  group('状态标签防误标、终态归队、冷启动加载与主题/大字号适配', () {
    testWidgets('官方状态【已归队】且已认领时显示【进入】+【已归队】且绝不出现【处置中】', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const returnedExternal = ExternalIncident(
        externalId: 'ext-returned-1',
        incidentNumber: '20261115001',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '火灾扑救',
        eventSummary: '示例厂房冒烟警情',
        officialStatus: '已归队',
        factHighlights: <String>['1人被困', '处置中'],
        crimeAddress: '示例大道100号',
        registerTime: 1786177100000,
        claimed: true,
        claimedIncidentId: 'local-returned-1',
      );
      const archivedLinkedExternal = ExternalIncident(
        externalId: 'ext-returned-2',
        incidentNumber: '20261115002',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '社会救助',
        eventSummary: '示例小区电梯困人警情',
        factHighlights: <String>['处置中'],
        crimeAddress: '示例大道200号',
        registerTime: 1786177150000,
        claimed: true,
        claimedIncidentId: 'local-archived-2',
      );
      const archivedLinkedLocal = Incident(
        id: 'local-archived-2',
        number: '20261115002',
        title: '示例小区电梯困人警情',
        status: 'archived',
        info: <String, dynamic>{'incident_status': '已归队'},
        createdAt: 1786177150000,
        lastActivityAt: 1786177150000,
      );
      const terminalCustom = Incident(
        id: 'custom-terminal-3',
        number: '20261115003#警情',
        title: '示例自建演练归队',
        status: 'archived',
        info: <String, dynamic>{'incident_status': '已归队'},
        unresolvedActiveCount: 3,
        createdAt: 1786177200000,
        lastActivityAt: 1786177200000,
      );

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[archivedLinkedLocal, terminalCustom],
            externalIncidents: const <ExternalIncident>[returnedExternal, archivedLinkedExternal],
            loading: false,
            now: fixedNow,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('进入'), findsNWidgets(3));
      expect(find.text('已归队'), findsNWidgets(3));
      expect(find.textContaining('处置'), findsNothing);
      expect(find.text('1人被困'), findsOneWidget);

      final wrap1 = find.byKey(const Key('ext-forces-wrap-ext_ext-returned-1'));
      final textsInWrap1 = tester
          .widgetList<Text>(find.descendant(of: wrap1, matching: find.byType(Text)))
          .map((t) => t.data)
          .toList();
      expect(textsInWrap1, <String>['示例路站', '已归队', '1人被困']);
    });

    testWidgets('官方状态【作战中】时：已认领显示安全绿【处置中】+【作战中】，未认领无【处置中】', (tester) async {
      const claimedFighting = ExternalIncident(
        externalId: 'ext-fight-claimed',
        incidentNumber: '20261115101',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '火灾扑救',
        eventSummary: '示例仓库火情扑救',
        officialStatus: '作战中',
        crimeAddress: '示例大道100号',
        registerTime: 1786177100000,
        claimed: true,
        claimedIncidentId: 'claimed-fight-local',
      );
      const unclaimedFighting = ExternalIncident(
        externalId: 'ext-fight-unclaimed',
        incidentNumber: '20261115102',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '抢险救援',
        eventSummary: '示例路段车辆救援',
        officialStatus: '作战中',
        crimeAddress: '示例大道200号',
        registerTime: 1786177200000,
        claimed: false,
      );

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[],
            externalIncidents: const <ExternalIncident>[claimedFighting, unclaimedFighting],
            loading: false,
            now: fixedNow,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('进入'), findsNWidgets(2));
      final claimedWrap = find.byKey(const Key('ext-forces-wrap-ext_ext-fight-claimed'));
      final claimedTexts = tester
          .widgetList<Text>(find.descendant(of: claimedWrap, matching: find.byType(Text)))
          .map((t) => t.data)
          .toList();
      expect(claimedTexts, <String>['示例路站', '处置中', '作战中']);

      final inProgressPill = tester.widget<StatusPill>(
        find.ancestor(of: find.text('处置中'), matching: find.byType(StatusPill)).first,
      );
      expect(inProgressPill.status, DsStatus.safe);

      final unclaimedWrap = find.byKey(const Key('ext-forces-wrap-ext_ext-fight-unclaimed'));
      expect(find.descendant(of: unclaimedWrap, matching: find.text('处置中')), findsNothing);
      expect(find.descendant(of: unclaimedWrap, matching: find.text('作战中')), findsOneWidget);
    });

    testWidgets('冷启动双加载态收口为单一进度指示且加载期不闪烁空态占位', (tester) async {
      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[],
            externalIncidents: const <ExternalIncident>[],
            loading: true,
            externalLoading: true,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('incident-selection-loading')), findsOneWidget);
      expect(find.text('正在拉取警情列表…'), findsOneWidget);
      expect(find.byKey(const Key('incident-selection-loading-placeholder')), findsOneWidget);
      expect(find.text('当前没有进行中的警情'), findsNothing);

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[],
            externalIncidents: const <ExternalIncident>[],
            loading: false,
            externalLoading: true,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在获取已调派警情…'), findsOneWidget);
      expect(find.text('当前没有进行中的警情'), findsNothing);

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[],
            externalIncidents: const <ExternalIncident>[],
            loading: false,
            externalLoading: false,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('当前没有进行中的警情'), findsOneWidget);
    });

    testWidgets('新建警情冷却期冲突自动弹出 CommandSheet 并支持直接加入现有警情', (tester) async {
      Incident? joined;
      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[],
            loading: false,
            onSelect: (inc) async => joined = inc,
            onCreate: () async {
              throw IncidentCreateConflictException('10秒前已有队员新建警情', customIncident);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-picker-create-btn')));
      await tester.pumpAndSettle();

      expect(find.text('已有刚创建的警情'), findsOneWidget);
      await tester.tap(find.byKey(const Key('incident-picker-join-conflict-btn')));
      await tester.pumpAndSettle();
      expect(joined?.id, customIncident.id);
    });

    testWidgets('昼白与暗曜双主题及 360dp @ 130% 大字号下零溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      for (final brightness in Brightness.values) {
        final expectedColors = DsColors.of(brightness);
        await tester.pumpWidget(
          wrap(
            IncidentPickerPage(
              activeIncidents: <Incident>[customIncident],
              externalIncidents: <ExternalIncident>[claimedExternal, unclaimedExternal],
              loading: false,
              now: fixedNow,
              onSelect: (_) async {},
              onCreate: () async {},
              onEnterWithoutIncident: () {},
            ),
            brightness: brightness,
            textScale: 1.3,
          ),
        );
        await tester.pumpAndSettle();

        final overlay = tester.widget<Material>(
          find.byKey(const Key('incident-selection-overlay')),
        );
        expect(overlay.color, expectedColors.canvas);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('配置 onCreateWithDraft 后新建警情弹出建档抽屉并回传名称/地点/定位/分类', (
      tester,
    ) async {
      IncidentCreateDraft? submittedDraft;
      Incident? joined;
      var throwConflict = false;

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: const <Incident>[],
            loading: false,
            onSelect: (inc) async => joined = inc,
            onCreateWithDraft: (IncidentCreateDraft draft) async {
              submittedDraft = draft;
              if (throwConflict) {
                throw IncidentCreateConflictException('10秒前已有队员新建警情', customIncident);
              }
            },
            onLocateAddress: () async => const IncidentLocatedAddress(
              address: '示例大道66号物流园',
              latitude: 31.2304,
              longitude: 121.4737,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-picker-create-btn')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('incident-create-title-field')),
        '示例工业园厂房火灾',
      );
      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-create-category-rescue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-create-confirm-btn')));
      await tester.pumpAndSettle();

      expect(submittedDraft?.title, '示例工业园厂房火灾');
      expect(submittedDraft?.location, '示例大道66号物流园');
      expect(submittedDraft?.category, DsIncidentCategory.rescue);
      expect(submittedDraft?.categoryExplicitlySelected, isTrue);
      expect(submittedDraft?.latitude, 31.2304);
      expect(submittedDraft?.longitude, 121.4737);

      // 带草稿建档触发冷却冲突同样支持直接加入现有警情
      throwConflict = true;
      await tester.tap(find.byKey(const Key('incident-picker-create-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-create-confirm-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-picker-join-conflict-btn')));
      await tester.pumpAndSettle();
      expect(joined?.id, customIncident.id);
    });

    testWidgets('已建档外部警情即使编号带后缀且未刷新外部列表也不重复渲染，全部警情统一按时间倒序排列', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final nowMs = fixedNow.millisecondsSinceEpoch;
      final tNewestExt = nowMs - 5 * 60 * 1000;
      final tCustomMid = nowMs - 20 * 60 * 1000;
      final tClaimedExt = nowMs - 40 * 60 * 1000;
      final tOlderExt = nowMs - 90 * 60 * 1000;
      final tExpiredClaimed = nowMs - 4 * 24 * 60 * 60 * 1000;

      Incident? selected;
      final claimedLocal = Incident(
        id: 'inc-claimed-1',
        number: 'POL-1120-a3f9',
        title: '厂房仓库起火',
        status: 'active',
        createdAt: nowMs - 1 * 60 * 1000,
        lastActivityAt: nowMs - 1 * 60 * 1000,
        info: <String, dynamic>{
          'external_id': 'ext-claimed-1',
          'external_incident_number': 'POL-1120',
          'external_source': 'police_api',
          'administrative_area': '示例县',
          'location': '示例县工业园8号',
          'received_at': DateTime.fromMillisecondsSinceEpoch(
            tClaimedExt,
          ).toIso8601String(),
        },
      );
      final customLocal = Incident(
        id: 'inc-custom-1',
        number: '2026-11-25-1140',
        title: '自建演练现场',
        status: 'active',
        createdAt: tCustomMid,
        lastActivityAt: tCustomMid,
        info: const <String, dynamic>{'location': '训练塔北侧'},
      );
      final expiredClaimedLocal = Incident(
        id: 'inc-expired-1',
        number: 'POL-OLD-001',
        title: '山林零星火点',
        status: 'active',
        createdAt: nowMs - 2 * 60 * 1000,
        lastActivityAt: nowMs - 2 * 60 * 1000,
        info: <String, dynamic>{
          'external_id': 'ext-expired-1',
          'external_incident_number': 'POL-OLD-001',
          'external_source': 'police_api',
          'administrative_area': '示例区',
          'location': '示例区林场山坡',
          'received_at': DateTime.fromMillisecondsSinceEpoch(
            tExpiredClaimed,
          ).toIso8601String(),
        },
      );

      final extList = <ExternalIncident>[
        ExternalIncident(
          externalId: 'ext-newest',
          incidentNumber: 'POL-1155',
          districtName: '示例县',
          incidentType: '火灾扑救',
          crimeAddress: '示例县人民路1号',
          eventSummary: '沿街商铺冒烟',
          registerTime: tNewestExt,
        ),
        ExternalIncident(
          externalId: 'ext-claimed-1',
          incidentNumber: 'POL-1120',
          districtName: '示例县',
          incidentType: '火灾扑救',
          crimeAddress: '示例县工业园8号',
          eventSummary: '厂房仓库起火',
          registerTime: tClaimedExt,
          claimed: false,
          claimedIncidentId: null,
        ),
        ExternalIncident(
          externalId: 'ext-older',
          incidentNumber: 'POL-1030',
          districtName: '示例县',
          incidentType: '抢险救援',
          crimeAddress: '示例县大桥南口',
          eventSummary: '货车追尾事故',
          registerTime: tOlderExt,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          IncidentPickerPage(
            activeIncidents: <Incident>[
              claimedLocal,
              expiredClaimedLocal,
              customLocal,
            ],
            externalIncidents: extList,
            loading: false,
            now: fixedNow,
            onSelect: (inc) async => selected = inc,
            onCreate: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('厂房仓库起火'), findsOneWidget);
      expect(find.text('自建'), findsOneWidget);
      expect(find.text('示例区'), findsOneWidget);

      final y1 = tester.getTopLeft(find.text('沿街商铺冒烟')).dy;
      final y2 = tester.getTopLeft(find.text('自建演练现场')).dy;
      final y3 = tester.getTopLeft(find.text('厂房仓库起火')).dy;
      final y4 = tester.getTopLeft(find.text('货车追尾事故')).dy;
      final y5 = tester.getTopLeft(find.text('山林零星火点')).dy;
      expect(y1, lessThan(y2));
      expect(y2, lessThan(y3));
      expect(y3, lessThan(y4));
      expect(y4, lessThan(y5));

      await tester.tap(find.text('厂房仓库起火'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'inc-claimed-1');
    });

    test('ExternalIncident.copyWithClaimed 正确回写认领状态且保留原字段', () {
      const origin = ExternalIncident(
        externalId: 'ext-99',
        incidentNumber: 'POL-99',
        crimeAddress: '示例路99号',
        eventSummary: '民房厨房起火',
        registerTime: 1700000000000,
      );
      final updated = origin.copyWithClaimed(
        claimed: true,
        claimedIncidentId: 'inc-99',
        claimedIncidentNumber: 'POL-99-abcd',
        claimedIncidentTitle: '民房厨房起火',
      );
      expect(updated.claimed, isTrue);
      expect(updated.claimedIncidentId, 'inc-99');
      expect(updated.claimedIncidentNumber, 'POL-99-abcd');
      expect(updated.claimedIncidentTitle, '民房厨房起火');
      expect(updated.externalId, origin.externalId);
      expect(updated.registerTime, origin.registerTime);
    });
  });
}
