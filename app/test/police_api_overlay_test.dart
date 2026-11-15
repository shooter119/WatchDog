import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/incident_selection_overlay.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/theme/app_palette.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

void main() {
  final customIncident = Incident(
    id: 'custom-inc-1',
    number: '202611071001#警情',
    title: '南区综合演练现场',
    status: 'active',
    createdAt: 1786177140000,
    lastActivityAt: 1786177140000,
  );

  final claimedExternal = ExternalIncident(
    externalId: 'ext-claimed-1',
    incidentNumber: '2026110712345601',
    detachmentName: '衢州支队',
    brigadeName: '柯城大队',
    districtName: '柯城区',
    incidentType: '火灾扑救',
    crimeAddress: '柯城区新桥街88号',
    registerTime: 1786177100000,
    claimed: true,
    claimedIncidentId: 'claimed-local-id',
  );

  final unclaimedExternal = ExternalIncident(
    externalId: 'ext-unclaimed-2',
    incidentNumber: '2026110712345602',
    detachmentName: '衢州支队',
    brigadeName: '龙游大队',
    districtName: '龙游县',
    incidentType: '抢险救援',
    crimeAddress: '龙游县荣昌广场',
    registerTime: 1786177200000,
    claimed: false,
  );

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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncidentSelectionOverlay(
            activeIncidents: [customIncident],
            externalIncidents: [claimedExternal, unclaimedExternal],
            loading: false,
            onSelect: (inc) async => selectedIncident = inc,
            onCreate: () async => createTriggered = true,
            onClaimExternal: (ext) async => claimedIncident = ext,
            onRefreshExternal: ({bool forceRefresh = false}) async {
              refreshTriggered = true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 所有卡片右侧操作胶囊统一为【进入】
    expect(find.text('进入'), findsNWidgets(3));
    expect(find.text('加入'), findsNothing);
    expect(find.text('待认领'), findsNothing);

    // 验证自建警情及标签
    expect(find.text('自建'), findsOneWidget);
    expect(find.text('南区综合演练现场'), findsOneWidget);

    // 验证官方已认领警情保留第3层【处置中】提示与辖区标签
    expect(find.text('处置中'), findsOneWidget);
    expect(find.text('柯城区'), findsOneWidget);
    expect(find.text('柯城区新桥街88号'), findsOneWidget);

    // 验证官方未认领警情无【处置中】并展示属地
    expect(find.text('龙游县荣昌广场'), findsOneWidget);
    expect(find.text('龙游县'), findsOneWidget);

    // 验证底部新建警情按钮
    expect(find.text('新建警情'), findsOneWidget);

    // 点击未认领外部警情卡片触发认领建档
    await tester.tap(find.text('龙游县荣昌广场'));
    await tester.pumpAndSettle();
    expect(claimedIncident?.externalId, 'ext-unclaimed-2');

    // 点击【自建】卡片触发进入
    await tester.tap(find.text('南区综合演练现场'));
    await tester.pumpAndSettle();
    expect(selectedIncident?.id, 'custom-inc-1');

    // 点击【新建警情】按钮触发新建
    await tester.tap(find.text('新建警情'));
    await tester.pumpAndSettle();
    expect(createTriggered, true);

    // 点击右上角刷新按钮触发刷新
    await tester.tap(find.byTooltip('刷新派警列表'));
    await tester.pumpAndSettle();
    expect(refreshTriggered, true);
  });

  testWidgets('搜索框可实时过滤混合警情列表', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncidentSelectionOverlay(
            activeIncidents: [customIncident],
            externalIncidents: [claimedExternal, unclaimedExternal],
            loading: false,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始三条全在
    expect(find.text('南区综合演练现场'), findsOneWidget);
    expect(find.text('柯城区新桥街88号'), findsOneWidget);
    expect(find.text('龙游县荣昌广场'), findsOneWidget);

    // 输入搜索关键词
    await tester.enterText(find.byType(TextField).first, '荣昌');
    await tester.pumpAndSettle();

    // 仅剩命中项
    expect(find.text('南区综合演练现场'), findsNothing);
    expect(find.text('柯城区新桥街88号'), findsNothing);
    expect(find.text('龙游县荣昌广场'), findsOneWidget);

    // 点击清除按钮恢复
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();

    expect(find.text('南区综合演练现场'), findsOneWidget);
    expect(find.text('柯城区新桥街88号'), findsOneWidget);
    expect(find.text('龙游县荣昌广场'), findsOneWidget);
  });

  testWidgets('按用户大队（如龙游县消防救援大队）强隔离展示警情列表', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncidentSelectionOverlay(
            userUnitName: '龙游县消防救援大队',
            activeIncidents: [customIncident],
            externalIncidents: [claimedExternal, unclaimedExternal],
            loading: false,
            onSelect: (_) async {},
            onCreate: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 自建警情属于当前单位，显示
    expect(find.text('南区综合演练现场'), findsOneWidget);
    // 龙游警情属于本大队，显示
    expect(find.text('龙游县荣昌广场'), findsOneWidget);
    // 柯城区警情非本大队，强隔离过滤不展示
    expect(find.text('柯城区新桥街88号'), findsNothing);
  });

  testWidgets('重构后优先突出事件主标题、三分类徽标与条件出动力量且支持 AI 一键重整', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    var reorganizeCalled = false;
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
      dispatchedForces: const [
        ExternalDispatchedForce(
          stationName: '示例路站',
          vehicleCount: 2,
          personnelCount: null,
        ),
      ],
      factHighlights: const ['1人被困', '二级'],
      registerTime: DateTime.now()
          .subtract(const Duration(minutes: 15))
          .millisecondsSinceEpoch,
      claimed: false,
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
      dispatchedForces: const [],
      factHighlights: const [],
      registerTime: DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch,
      claimed: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncidentSelectionOverlay(
            activeIncidents: const [],
            externalIncidents: [aiIncident, noForceIncident],
            loading: false,
            onSelect: (_) async {},
            onCreate: () async {},
            onReorganizeExternal: () async {
              reorganizeCalled = true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 最突出的事件主标题与三分类徽标
    expect(find.text('货车追尾驾驶室人员被困'), findsOneWidget);
    expect(find.text('小区居民电梯困人救助'), findsOneWidget);
    expect(
      find.byKey(const Key('ext-category-badge-ext_ext-ai-1-rescue')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('ext-category-badge-ext_ext-noforce-2-aid')),
      findsOneWidget,
    );

    // 2. 规范化地点与出动力量条件展示
    expect(find.text('示例县建设大道66号'), findsOneWidget);
    expect(find.text('示例路站 2车'), findsOneWidget);
    expect(find.text('1人被困'), findsOneWidget);
    expect(find.byKey(const Key('ext-forces-wrap-ext_ext-ai-1')), findsOneWidget);
    expect(
      find.byKey(const Key('ext-forces-wrap-ext_ext-noforce-2')),
      findsNothing,
    );

    // 3. 点击 AI 一键重整按钮
    await tester.tap(find.byKey(const Key('external-reorganize-btn')));
    await tester.pumpAndSettle();
    expect(reorganizeCalled, isTrue);
  });

  group('接警描述清洗、全文检索与跨区增援展示', () {
    test('ExternalIncident.effectiveEventTitle 清洗长段接警通报与超长截断且保留常规短描述', () {
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

      const multiRoundAndTruncate = ExternalIncident(
        externalId: 'ext-clean-2',
        incidentNumber: '20261114102',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '抢险救援',
        crimeAddress: '示例县建设大道66号',
        incidentDescribe:
            '19:15许，示例支队指挥中心接110转警称，2026年11月13日19时15分，位于上述地址：一大型冷链物流货车在高速匝道发生侧翻并伴随燃油泄漏，示例路站出动1车7人赶赴现场。',
        registerTime: 1786177140000,
      );
      final title2 = multiRoundAndTruncate.effectiveEventTitle;
      expect(title2.length, 24);
      expect(title2, '一大型冷链物流货车在高速匝道发生侧翻并伴随燃油…');

      const shortNormal = ExternalIncident(
        externalId: 'ext-clean-3',
        incidentNumber: '20261114103',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '火灾扑救',
        crimeAddress: '示例县幸福小区1栋',
        incidentDescribe: '民房厨房油锅起火',
        registerTime: 1786177140000,
      );
      expect(shortNormal.effectiveEventTitle, '民房厨房油锅起火');

      const boilerplateOnly = ExternalIncident(
        externalId: 'ext-clean-4',
        incidentNumber: '20261114104',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '社会救助',
        disposalObjectName: '马蜂窝',
        crimeAddress: '示例县滨河路12号',
        incidentDescribe: '00时26分，示例大队接警称：暂无人员被困，官方状态: 出动',
        registerTime: 1786177140000,
      );
      expect(boilerplateOnly.effectiveEventTitle, '社会救助（马蜂窝）');
    });

    testWidgets('搜索框支持按 incidentDescribe 细节与 disposalObjectName 实时过滤命中', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const trafficIncident = ExternalIncident(
        externalId: 'ext-search-1',
        incidentNumber: '20261114201',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '抢险救援',
        disposalObjectName: '半挂货车',
        eventSummary: '高速交通事故处置',
        situationDetail: '道路交通事故现场救援',
        incidentDescribe: '示例县高速路口两车追尾，驾驶室变形',
        crimeAddress: '示例县高速路口',
        registerTime: 1786177140000,
      );

      const pitIncident = ExternalIncident(
        externalId: 'ext-search-2',
        incidentNumber: '20261114202',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '抢险救援',
        disposalObjectName: '深坑救援',
        eventSummary: '工地人员坠落救助',
        situationDetail: '人员坠落待救',
        incidentDescribe: '一施工人员不慎坠入6米坑内，暂无生命危险',
        crimeAddress: '示例县工地2号门',
        registerTime: 1786177200000,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IncidentSelectionOverlay(
              activeIncidents: const [],
              externalIncidents: const [trafficIncident, pitIncident],
              loading: false,
              onSelect: (_) async {},
              onCreate: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('高速交通事故处置'), findsOneWidget);
      expect(find.text('工地人员坠落救助'), findsOneWidget);

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

    testWidgets('跨区增援警情在 dispatchedForces 或 incidentDescribe 含本单位关键词时仍对本单位可见', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const unrelatedOtherDistrict = ExternalIncident(
        externalId: 'ext-cross-0',
        incidentNumber: '20261114300',
        detachmentName: '示例支队',
        brigadeName: '示例东区大队',
        squadronName: '示例东路站',
        districtName: '示例东区',
        incidentType: '火灾扑救',
        eventSummary: '示例东区无关杂草起火',
        crimeAddress: '示例东区幸福路1号',
        dispatchedForces: [
          ExternalDispatchedForce(
            stationName: '示例东路站',
            vehicleCount: 1,
          ),
        ],
        incidentDescribe: '示例东区空地杂草起火，示例东路站出动1车扑救',
        registerTime: 1786177100000,
      );

      const reinforceViaForces = ExternalIncident(
        externalId: 'ext-cross-1',
        incidentNumber: '20261114301',
        detachmentName: '示例支队',
        brigadeName: '示例东区大队',
        squadronName: '示例东路站',
        districtName: '示例东区',
        incidentType: '火灾扑救',
        eventSummary: '跨区联动厂房冒烟',
        crimeAddress: '示例东区工业大道2号',
        dispatchedForces: [
          ExternalDispatchedForce(
            stationName: '示例东路站',
            vehicleCount: 2,
          ),
          ExternalDispatchedForce(
            stationName: '示例县示例路站',
            vehicleCount: 1,
            personnelCount: 6,
          ),
        ],
        registerTime: 1786177140000,
      );

      const reinforceViaDescribe = ExternalIncident(
        externalId: 'ext-cross-2',
        incidentNumber: '20261114302',
        detachmentName: '示例支队',
        brigadeName: '示例东区大队',
        squadronName: '示例东路站',
        districtName: '示例东区',
        incidentType: '抢险救援',
        eventSummary: '跨区增援危化品槽车处置',
        crimeAddress: '示例东区物流园3号',
        incidentDescribe: '示例东区高速口槽车侧翻，支队调派示例县示例路站跨区增援',
        registerTime: 1786177200000,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IncidentSelectionOverlay(
              userUnitName: '示例县消防救援大队',
              activeIncidents: const [],
              externalIncidents: const [
                unrelatedOtherDistrict,
                reinforceViaForces,
                reinforceViaDescribe,
              ],
              loading: false,
              onSelect: (_) async {},
              onCreate: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 非增援的其他示例区警情继续强隔离隐藏
      expect(find.text('示例东区无关杂草起火'), findsNothing);
      // 派出本单位力量或描述提及本单位跨区增援时可见
      expect(find.text('跨区联动厂房冒烟'), findsOneWidget);
      expect(find.text('跨区增援危化品槽车处置'), findsOneWidget);
    });
  });

  group('状态标签防误标、终态归队与暗曜主题适配', () {
    testWidgets('官方状态为【已归队】且已被认领时最右侧为【进入】、显示【已归队】且绝不出现【处置中】', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const returnedExternal = ExternalIncident(
        externalId: 'ext-returned-1',
        incidentNumber: '20261115001',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '火灾扑救',
        eventSummary: '示例厂房冒烟警情',
        officialStatus: '已归队',
        factHighlights: ['1人被困', '处置中'],
        crimeAddress: '示例大道100号',
        registerTime: 1786177100000,
        claimed: true,
        claimedIncidentId: 'local-returned-1',
      );

      const archivedLinkedExternal = ExternalIncident(
        externalId: 'ext-returned-2',
        incidentNumber: '20261115002',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '社会救助',
        eventSummary: '示例小区电梯困人警情',
        officialStatus: '',
        factHighlights: ['处置中'],
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
        info: {'incident_status': '已归队'},
        createdAt: 1786177150000,
        lastActivityAt: 1786177150000,
      );

      const terminalCustomIncident = Incident(
        id: 'custom-terminal-3',
        number: '20261115003#警情',
        title: '示例自建演练归队',
        status: 'archived',
        info: {'incident_status': '已归队'},
        unresolvedActiveCount: 3,
        createdAt: 1786177200000,
        lastActivityAt: 1786177200000,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: IncidentSelectionOverlay(
              activeIncidents: const [
                archivedLinkedLocal,
                terminalCustomIncident,
              ],
              externalIncidents: const [
                returnedExternal,
                archivedLinkedExternal,
              ],
              loading: false,
              onSelect: (_) async {},
              onCreate: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 三张卡片右侧均为【进入】，且均显示【已归队】
      expect(find.text('进入'), findsNWidgets(3));
      expect(find.text('已归队'), findsNWidgets(3));
      // 终态卡片任何位置绝不出现【处置中】或【3人处置中】
      expect(find.textContaining('处置'), findsNothing);
      // 原有其他关键事实保留
      expect(find.text('1人被困'), findsOneWidget);
      // 验证外部警情卡片【已归队】位于第3层 factHighlights 首位（紧随出动力量标签之后）
      final wrap1 = find.byKey(
        const Key('ext-forces-wrap-ext_ext-returned-1'),
      );
      final textsInWrap1 = tester
          .widgetList<Text>(
            find.descendant(of: wrap1, matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .toList();
      expect(textsInWrap1, ['示例路站', '已归队', '1人被困']);
    });

    testWidgets('官方状态为【作战中】时：已认领第3层显示【处置中】且右侧为【进入】，未认领无【处置中】且右侧为【进入】', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const claimedFighting = ExternalIncident(
        externalId: 'ext-fight-claimed',
        incidentNumber: '20261115101',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
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
        detachmentName: '示例支队',
        brigadeName: '示例大队',
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
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: IncidentSelectionOverlay(
              activeIncidents: const [],
              externalIncidents: const [claimedFighting, unclaimedFighting],
              loading: false,
              onSelect: (_) async {},
              onCreate: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 两张卡片最右侧按钮均为【进入】
      expect(find.text('进入'), findsNWidgets(2));
      expect(find.text('待认领'), findsNothing);

      // 已认领卡片第 3 层 factHighlights 首位显示【处置中】，且采用安全绿状态配色
      final claimedWrap = find.byKey(
        const Key('ext-forces-wrap-ext_ext-fight-claimed'),
      );
      expect(claimedWrap, findsOneWidget);
      final claimedTexts = tester
          .widgetList<Text>(
            find.descendant(of: claimedWrap, matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .toList();
      expect(claimedTexts, ['示例路站', '处置中', '作战中']);

      final inProgressText = tester.widget<Text>(find.text('处置中'));
      expect(inProgressText.style?.color, AppColors.safeText);
      final inProgressContainer = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('处置中'),
              matching: find.byType(Container),
            )
            .first,
      );
      final inProgressDeco = inProgressContainer.decoration! as BoxDecoration;
      expect(inProgressDeco.color, AppColors.safeSurface);
      expect(
        inProgressDeco.border,
        Border.all(color: AppColors.safe.withValues(alpha: 0.3), width: 1.0),
      );

      // 未认领卡片第 3 层无【处置中】
      final unclaimedWrap = find.byKey(
        const Key('ext-forces-wrap-ext_ext-fight-unclaimed'),
      );
      expect(unclaimedWrap, findsOneWidget);
      expect(
        find.descendant(of: unclaimedWrap, matching: find.text('处置中')),
        findsNothing,
      );
      expect(
        find.descendant(of: unclaimedWrap, matching: find.text('作战中')),
        findsOneWidget,
      );
      expect(find.text('处置中'), findsOneWidget);
    });

    testWidgets('在 AppPalette.nightTactical（暗曜）下渲染浮层卡片无异常且文字与按钮配色正确随主题切换', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        ThemeController.instance.resetForTest();
      });

      ThemeController.instance.resetForTest();

      const customActive = Incident(
        id: 'custom-night-1',
        number: '20261115201#警情',
        title: '示例演练现场',
        status: 'active',
        createdAt: 1786177100000,
        lastActivityAt: 1786177100000,
      );

      const externalActive = ExternalIncident(
        externalId: 'ext-night-1',
        incidentNumber: '20261115202',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '火灾扑救',
        eventSummary: '示例商铺火情',
        officialStatus: '作战中',
        crimeAddress: '示例大道100号',
        registerTime: 1786177150000,
        claimed: true,
        claimedIncidentId: 'claimed-night-1',
      );

      const externalReturned = ExternalIncident(
        externalId: 'ext-night-2',
        incidentNumber: '20261115203',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '社会救助',
        eventSummary: '示例小区救助',
        officialStatus: '已归队',
        crimeAddress: '示例大道200号',
        registerTime: 1786177200000,
        claimed: true,
        claimedIncidentId: 'claimed-night-2',
      );

      await tester.pumpWidget(
        ListenableBuilder(
          listenable: ThemeController.instance,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(),
            themeAnimationDuration: Duration.zero,
            home: KeyedSubtree(
              key: ValueKey(ThemeController.instance.currentId),
              child: Scaffold(
                body: IncidentSelectionOverlay(
                  activeIncidents: const [customActive],
                  externalIncidents: const [externalActive, externalReturned],
                  loading: false,
                  onSelect: (_) async {},
                  onCreate: () async {},
                  onReorganizeExternal: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 昼白基线验证
      final daylightOverlay = tester.widget<Material>(
        find.byKey(const Key('incident-selection-overlay')),
      );
      expect(daylightOverlay.color, AppPalette.daylight.background);

      // 动态切换为暗曜（AppPalette.nightTactical）
      ThemeController.instance.select(AppPalette.nightTactical);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      final nightOverlay = tester.widget<Material>(
        find.byKey(const Key('incident-selection-overlay')),
      );
      expect(nightOverlay.color, AppPalette.nightTactical.background);

      // 标题文字为暗曜高对比浅色
      final titleText = tester.widget<Text>(find.text('示例商铺火情'));
      expect(titleText.style?.color, AppPalette.nightTactical.textPrimary);

      // 右侧【进入】胶囊背景与文字跟随暗曜 actionPrimary
      final enterText = tester.widget<Text>(find.text('进入').first);
      expect(enterText.style?.color, AppPalette.nightTactical.actionPrimary);
      final enterPill = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('进入').first,
              matching: find.byType(Container),
            )
            .first,
      );
      final enterDeco = enterPill.decoration! as BoxDecoration;
      expect(
        enterDeco.color,
        AppPalette.nightTactical.actionPrimary.withValues(alpha: 0.12),
      );

      // 【自建】辖区标签与右侧【进入】彻底解耦，读取 cautionSurface / cautionText
      final customTagText = tester.widget<Text>(find.text('自建'));
      expect(customTagText.style?.color, AppPalette.nightTactical.cautionText);
      final customTagContainer = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('自建'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (customTagContainer.decoration! as BoxDecoration).color,
        AppPalette.nightTactical.cautionSurface,
      );

      // 外部辖区标签读取 surfaceSubtle / textSecondary
      final districtTagText = tester.widget<Text>(find.text('示例县').first);
      expect(
        districtTagText.style?.color,
        AppPalette.nightTactical.textSecondary,
      );
      final districtTagContainer = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('示例县').first,
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (districtTagContainer.decoration! as BoxDecoration).color,
        AppPalette.nightTactical.surfaceSubtle,
      );

      // 【处置中】第3层标签在暗曜下读取 safeSurface / safeText / safe border
      final activeTagText = tester.widget<Text>(find.text('处置中'));
      expect(activeTagText.style?.color, AppPalette.nightTactical.safeText);
      final activeTagContainer = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('处置中'),
              matching: find.byType(Container),
            )
            .first,
      );
      final activeDeco = activeTagContainer.decoration! as BoxDecoration;
      expect(
        activeDeco.color,
        AppPalette.nightTactical.safe.withValues(alpha: 0.12),
      );
      expect(
        activeDeco.border,
        Border.all(
          color: AppPalette.nightTactical.safe.withValues(alpha: 0.3),
          width: 1.0,
        ),
      );

      // 搜索框文字采用暗曜 textPrimary
      final searchField = tester.widget<TextField>(find.byType(TextField).first);
      expect(searchField.style?.color, AppPalette.nightTactical.textPrimary);

      // 空态提示在暗曜下同样使用 textPrimary 且无异常
      await tester.enterText(find.byType(TextField).first, '不存在的关键词xyz');
      await tester.pumpAndSettle();
      final emptyTitle = tester.widget<Text>(find.text('当前没有进行中的警情'));
      expect(emptyTitle.style?.color, AppPalette.nightTactical.textPrimary);
      expect(tester.takeException(), isNull);
    });
  });
}
