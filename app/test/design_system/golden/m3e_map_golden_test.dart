@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/core/models/amap_location.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/map/ui/route_traffic_page.dart';
import 'package:watchdog/features/water_sources/ui/water_sources_page.dart';
import 'package:watchdog/services/camera_bridge.dart';

const _goldenRouteInfo = RouteTrafficInfo(
  destination: RouteEndpointInfo(
    queryAddress: '示范东路1号',
    formattedAddress: '示例省示例市示例县示例街道示范东路1号',
    city: '示例市',
    district: '示例县',
    adcode: '330182',
    location: AmapLocation(lat: 29.474, lon: 119.281, coordinate: 'gcj02'),
  ),
  origin: RouteOriginInfo(
    address: '示例省示例市示例县示例南街道示范大道',
    location: AmapLocation(lat: 29.491, lon: 119.302, coordinate: 'gcj02'),
  ),
  weather: RouteWeatherLive(
    text: '多云',
    temperature: '22',
    humidity: '65',
    windDirection: '东南',
    windPower: '≤3',
    city: '示例县',
  ),
  forecast: RouteWeatherForecast(
    dayWeather: '多云',
    nightWeather: '阴',
    dayTemp: '24',
    nightTemp: '15',
  ),
  routes: [
    DrivingRoutePlan(
      strategy: '速度最快',
      distanceMeters: 6800,
      durationSeconds: 780,
      trafficLights: 6,
      overallStatus: '局部缓行',
      roads: ['示范大道', '示范大桥', '示范东路'],
      trafficSummary: TrafficSummary(
        smoothMeters: 5200,
        slowMeters: 1200,
        jamMeters: 400,
      ),
      congestedSegments: [
        CongestedSegment(road: '示范大桥', status: '拥堵', distanceMeters: 400),
      ],
      steps: [
        RouteStepInfo(
          instruction: '沿示范大道向西南行驶1.8公里左转',
          road: '示范大道',
          distanceMeters: 1800,
          durationSeconds: 180,
          action: '左转',
          status: '畅通',
        ),
      ],
    ),
    DrivingRoutePlan(
      strategy: '备选路线',
      distanceMeters: 7500,
      durationSeconds: 900,
      trafficLights: 8,
      overallStatus: '畅通',
      roads: ['示范大道', '示范二路'],
    ),
  ],
  routeAvailable: true,
);

final _goldenWaterSources = <WaterSource>[
  const WaterSource(
    id: 'ws-1',
    unitId: 'example-unit-1',
    category: WaterSourceCategory.hydrant,
    name: '示范路北口市政消火栓',
    lat: 30.2505,
    lng: 120.1500,
    status: WaterSourceStatus.available,
    note: '口径 DN150，水压充足，消防车可直接靠边连接',
    updatedAt: 1730000009000,
    updatedByName: '张三',
  ),
  const WaterSource(
    id: 'ws-2',
    unitId: 'example-unit-1',
    category: WaterSourceCategory.natural,
    name: '示范公园消防水池',
    lat: 30.2520,
    lng: 120.1500,
    status: WaterSourceStatus.available,
    intakeMethods: [
      WaterIntakeMethod.fireTruck,
      WaterIntakeMethod.portablePump,
    ],
    note: '有效容积 200 立方米，东侧设有专用取水口',
    updatedAt: 1730000005000,
    updatedByName: '李四',
  ),
  const WaterSource(
    id: 'ws-3',
    unitId: 'example-unit-1',
    category: WaterSourceCategory.pumpConnector,
    name: '示例商厦西侧水泵接合器',
    lat: 30.2580,
    lng: 120.1500,
    status: WaterSourceStatus.unavailable,
    note: '闷盖缺失且周边施工围挡占用，暂不可用',
    updatedAt: 1730000001000,
    updatedByName: '王五',
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

    testWidgets('M3e 路况概览页 ($themeTag)', (tester) async {
      final captureKey = GlobalKey();
      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: RouteTrafficPage(
          gateway: RouteTrafficGateway(
            requestPermission: () async => true,
            locationServiceEnabled: () async => true,
            currentLocation: () async => const LocationFix(
              lat: 29.491,
              lon: 119.302,
              accuracyMeters: 6,
              provider: 'gps',
              ageMs: 100,
            ),
            fetchRouteTraffic: ({
              required address,
              city,
              originLat,
              originLon,
              destLat,
              destLon,
              destName,
              destAdcode,
            }) async => _goldenRouteInfo,
            openAppSettings: () async {},
            openLocationSettings: () async {},
            copyText: (_) async {},
            launchNavigation: (_) async => true,
          ),
          readCurrentIncident: () => const RouteTrafficIncidentContext(
            id: 'inc-golden',
            displayName: '示例县仓储火警',
            location: '示范东路1号',
            administrativeArea: '示例县',
          ),
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3e_route_traffic_$themeTag.png'),
      );
    });

    testWidgets('M3e 大队水源库列表卡片 ($themeTag)', (tester) async {
      final captureKey = GlobalKey();
      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: WaterSourcesPage(
          gateway: WaterSourcesGateway(
            requestLocationPermission: () async => true,
            isLocationServiceEnabled: () async => true,
            currentLocation: () async => const LocationFix(
              lat: 30.2500,
              lon: 120.1500,
              accuracyMeters: 10,
              provider: 'gps',
              ageMs: 0,
            ),
            fetchMapBootstrap: () async => const WaterMapBootstrap(
              configured: false,
              message: '底图未配置，已自动切换列表查水',
            ),
            fetchWaterSources: () async => WaterSourceListResult(
              items: _goldenWaterSources,
              summary: WaterSourceSummary.fromItems(_goldenWaterSources),
            ),
          ),
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3e_water_sources_$themeTag.png'),
      );
    });
  }
}
