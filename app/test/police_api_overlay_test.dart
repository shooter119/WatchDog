import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/incident_selection_overlay.dart';

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

  testWidgets('混合列表展示【自建】与官方【处置中】【待认领】标签及对应操作', (tester) async {
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

    // 验证自建警情及 Badge
    expect(find.text('自建'), findsOneWidget);
    expect(find.text('加入'), findsOneWidget);
    expect(find.text('南区综合演练现场'), findsOneWidget);

    // 验证官方已认领警情及 Badge
    expect(find.text('处置中'), findsOneWidget);
    expect(find.text('柯城区新桥街88号'), findsOneWidget);

    // 验证官方未认领警情及 Badge与属地
    expect(find.text('待认领'), findsOneWidget);
    expect(find.text('龙游县荣昌广场'), findsOneWidget);
    expect(find.text('龙游县'), findsOneWidget);

    // 验证底部新建警情按钮
    expect(find.text('新建警情'), findsOneWidget);

    // 点击【待认领】卡片触发认领建档
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
}
