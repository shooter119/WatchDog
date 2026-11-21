@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/data/models/external_incident.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/ui/incident_picker_page.dart';

Future<void> _pumpGoldenSurface(
  WidgetTester tester, {
  required Brightness brightness,
  required GlobalKey captureKey,
  required Widget child,
  Size surfaceSize = const Size(390, 844),
}) async {
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
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
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixedNow = DateTime(2026, 11, 15, 16, 0);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  final customActive = Incident(
    id: 'custom-golden-1',
    number: '202611151001#警情',
    title: '示例路综合演练现场',
    status: 'active',
    unresolvedActiveCount: 2,
    createdAt: DateTime(2026, 11, 15, 15, 42).millisecondsSinceEpoch,
    lastActivityAt: DateTime(2026, 11, 15, 15, 42).millisecondsSinceEpoch,
  );

  final claimedFire = ExternalIncident(
    externalId: 'ext-golden-1',
    incidentNumber: '202611150001',
    detachmentName: '示例市支队',
    brigadeName: '示例县大队',
    squadronName: '示例路站',
    districtName: '示例县',
    incidentType: '火灾扑救',
    disasterCategory: 'fire',
    eventSummary: '沿街商铺一楼仓储起火冒烟',
    locationDisplay: '示例县建设大道66号',
    crimeAddress: '示例县建设大道66号',
    officialStatus: '作战中',
    dispatchedForces: const <ExternalDispatchedForce>[
      ExternalDispatchedForce(stationName: '示例路站', vehicleCount: 2, personnelCount: 12),
    ],
    factHighlights: const <String>['1人被困', '二级'],
    registerTime: DateTime(2026, 11, 15, 15, 35).millisecondsSinceEpoch,
    claimed: true,
    claimedIncidentId: 'claimed-golden-1',
  );

  final unclaimedRescue = ExternalIncident(
    externalId: 'ext-golden-2',
    incidentNumber: '202611150002',
    detachmentName: '示例市支队',
    brigadeName: '示例县大队',
    squadronName: '北环路站',
    districtName: '示例县',
    incidentType: '抢险救援',
    disasterCategory: 'rescue',
    eventSummary: '货车追尾驾驶室人员被困',
    locationDisplay: '示例县和平路与东环交叉口',
    crimeAddress: '示例县和平路与东环交叉口',
    dispatchedForces: const <ExternalDispatchedForce>[
      ExternalDispatchedForce(stationName: '北环路站', vehicleCount: 1, personnelCount: 6),
    ],
    factHighlights: const <String>['作战中'],
    registerTime: DateTime(2026, 11, 15, 15, 10).millisecondsSinceEpoch,
    claimed: false,
  );

  final returnedAid = ExternalIncident(
    externalId: 'ext-golden-3',
    incidentNumber: '202611150003',
    detachmentName: '示例市支队',
    brigadeName: '示例县大队',
    squadronName: '示例路站',
    districtName: '示例县',
    incidentType: '社会救助',
    disasterCategory: 'aid',
    eventSummary: '居民小区电梯困人救助',
    locationDisplay: '示例县幸福小区3栋',
    crimeAddress: '示例县幸福小区3栋',
    officialStatus: '已归队',
    registerTime: DateTime(2026, 11, 15, 14, 20).millisecondsSinceEpoch,
    claimed: true,
    claimedIncidentId: 'claimed-golden-3',
  );

  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3g 警情选择全屏页 ($themeTag)', (tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenSurface(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: IncidentPickerPage(
          activeIncidents: <Incident>[customActive],
          externalIncidents: <ExternalIncident>[claimedFire, unclaimedRescue, returnedAid],
          loading: false,
          now: fixedNow,
          onSelect: (_) async {},
          onCreate: () async {},
          onClaimExternal: (_) async {},
          onRefreshExternal: ({bool forceRefresh = false}) async {},
          onEnterWithoutIncident: () {},
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3g_incident_picker_$themeTag.png'),
      );
    });
  }
}
