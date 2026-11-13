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
}
