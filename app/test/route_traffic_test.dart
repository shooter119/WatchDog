import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/route_traffic_page.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

class _FakeController extends AppController {
  Incident? mockIncident;
  bool requestIncidentSelectionCalled = false;

  _FakeController({this.mockIncident});

  @override
  Incident? get currentIncident => mockIncident;

  @override
  void requestIncidentSelection() {
    requestIncidentSelectionCalled = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mockRouteInfo = RouteTrafficInfo(
    destination: const RouteEndpointInfo(
      queryAddress: '新安东路1号',
      formattedAddress: '浙江省杭州市建德市新安江街道新安东路1号',
      city: '杭州市',
      district: '建德市',
      adcode: '330182',
      location: AmapLocation(lat: 29.474, lon: 119.281, coordinate: 'gcj02'),
    ),
    origin: const RouteOriginInfo(
      address: '浙江省杭州市建德市洋溪街道洋安大道',
      location: AmapLocation(lat: 29.491, lon: 119.302, coordinate: 'gcj02'),
    ),
    weather: const RouteWeatherLive(
      text: '多云',
      temperature: '22',
      humidity: '65',
      windDirection: '东南',
      windPower: '≤3',
      city: '建德市',
    ),
    forecast: const RouteWeatherForecast(
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
        roads: const ['洋安大道', '新安江大桥', '新安东路'],
        trafficSummary: const TrafficSummary(
          smoothMeters: 5200,
          slowMeters: 1200,
          jamMeters: 400,
        ),
        congestedSegments: const [
          CongestedSegment(road: '新安江大桥', status: '拥堵', distanceMeters: 400),
        ],
        steps: const [
          RouteStepInfo(
            instruction: '沿洋安大道向西南行驶1.8公里左转',
            road: '洋安大道',
            distanceMeters: 1800,
            durationSeconds: 180,
            action: '左转',
            status: '畅通',
          ),
        ],
      ),
      const DrivingRoutePlan(
        strategy: '备选路线',
        distanceMeters: 7500,
        durationSeconds: 900,
        trafficLights: 8,
        overallStatus: '畅通',
        roads: ['洋安大道', '白沙路'],
      ),
    ],
    routeAvailable: true,
  );

  group('RouteTrafficInfo 单元测试', () {
    test('格式化耗时与距离', () {
      expect(RouteTrafficInfo.formatDuration(780), '13 分钟');
      expect(RouteTrafficInfo.formatDuration(3660), '1小时1分');
      expect(RouteTrafficInfo.formatDuration(7200), '2小时');
      expect(RouteTrafficInfo.formatDistance(800), '800 米');
      expect(RouteTrafficInfo.formatDistance(6800), '6.8 公里');
      expect(
        RouteTrafficInfo.formatDistance(6800, compactUnit: true),
        '6.8公里',
      );
    });

    test('生成高德驾车导航链接', () {
      final uri = mockRouteInfo.navigationUri;
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'uri.amap.com');
      expect(uri.path, '/navigation');
      expect(uri.queryParameters['to'], '119.281000,29.474000');
      expect(uri.queryParameters['mode'], 'car');
    });

    test('生成路况纯文本简报', () {
      final text = mockRouteInfo.toSummaryText(incidentName: '建德某厂火警');
      expect(text, contains('警情：建德某厂火警'));
      expect(text, contains('事发地点：浙江省杭州市建德市新安江街道新安东路1号'));
      expect(text, contains('预计行程：13 分钟（6.8 公里，红绿灯 6 个）'));
      expect(text, contains('整体路况：局部缓行'));
      expect(text, contains('途经道路：洋安大道 → 新安江大桥 → 新安东路'));
      expect(text, contains('拥堵提醒：新安江大桥 · 拥堵 400米'));
      expect(text, contains('现场天气：多云 · 22℃ · 湿度65% · 东南风 · ≤3级'));
      expect(text, contains('高德驾车导航：'));
    });

    test('fromJson 解析空或异常字段能够健壮兜底', () {
      final info = RouteTrafficInfo.fromJson({
        'destination': {'queryAddress': '某地点'},
        'routes': [
          {'distance': 1000, 'duration': 120},
        ],
      });
      expect(info.destination?.queryAddress, '某地点');
      expect(info.routes.length, 1);
      expect(info.routes.first.distanceMeters, 1000);
      expect(info.routes.first.durationSeconds, 120);
    });
  });

  group('RouteTrafficPage 界面测试', () {
    testWidgets('未选警情时显示空状态引导选择', (tester) async {
      final controller = _FakeController(mockIncident: null);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RouteTrafficPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('尚未选择正在处置的警情'), findsOneWidget);
      expect(find.byKey(const Key('route-traffic-select-incident')), findsOneWidget);

      await tester.tap(find.byKey(const Key('route-traffic-select-incident')));
      expect(controller.requestIncidentSelectionCalled, isTrue);
    });

    testWidgets('警情无具体地点时提示完善警情信息并提供操作按钮', (tester) async {
      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-1',
          number: '2026-11-05-01',
          title: '测试警情',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {}, // location 为空
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RouteTrafficPage(
            controller: controller,
            gateway: RouteTrafficGateway(
              requestPermission: () async => true,
              locationServiceEnabled: () async => true,
              currentLocation: () async => null,
              fetchRouteTraffic: ({
                required address,
                city,
                originLat,
                originLon,
                destLat,
                destLon,
                destName,
                destAdcode,
              }) async => mockRouteInfo,
              fetchIncidentDetails: (id) async => {'data': {}},
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('警情缺少事发地点'), findsOneWidget);
      expect(
        find.text('当前警情尚未填写具体位置信息，请先完善警情信息后再查询路况。'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('route-traffic-edit-details')), findsOneWidget);
      expect(find.byKey(const Key('route-traffic-import-details')), findsOneWidget);
    });

    testWidgets('警情有地址时展示耗时、里程、途经道路、实时路况与风向天气', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String? copiedText;
      Uri? launchedUri;

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-1',
          number: '2026-11-05-01',
          title: '建德某厂火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {
            'location': '新安东路1号',
            'administrative_area': '建德市',
          },
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RouteTrafficPage(
            controller: controller,
            gateway: RouteTrafficGateway(
              requestPermission: () async => true,
              locationServiceEnabled: () async => true,
              currentLocation: () async => const LocationFix(
                lat: 29.491,
                lon: 119.302,
                accuracyMeters: 5.0,
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
              }) async {
                expect(address, '新安东路1号');
                expect(city, '建德市');
                expect(originLat, 29.491);
                expect(originLon, 119.302);
                return mockRouteInfo;
              },
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (text) async {
                copiedText = text;
              },
              launchNavigation: (uri) async {
                launchedUri = uri;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 验证核心信息展示
      expect(find.text('13 分钟'), findsOneWidget);
      expect(find.text('6.8 公里'), findsOneWidget);
      expect(find.text('红绿灯 6 个'), findsOneWidget);
      expect(find.text('路况：局部缓行'), findsOneWidget);
      expect(find.text('沿途拥堵/缓行路段'), findsOneWidget);
      expect(find.text('新安江大桥'), findsWidgets);
      expect(find.text('主要途经道路'), findsOneWidget);
      expect(find.text('洋安大道'), findsWidgets);
      expect(find.text('新安东路'), findsWidgets);
      expect(find.text('事发地气象与火场风向'), findsOneWidget);
      expect(find.text('多云'), findsWidgets);
      expect(find.text('22℃'), findsOneWidget);
      expect(find.textContaining('风向：东南风 · ≤3级'), findsOneWidget);
      expect(find.textContaining('上风或侧上风方向停车'), findsOneWidget);

      // 验证多方案切换
      expect(find.text('方案1 · 速度最快'), findsOneWidget);
      expect(find.text('方案2 · 备选路线'), findsOneWidget);
      await tester.tap(find.text('方案2 · 备选路线'));
      await tester.pumpAndSettle();
      expect(find.text('15 分钟'), findsOneWidget);
      expect(find.text('7.5 公里'), findsOneWidget);

      // 验证导航按钮
      await tester.tap(find.byKey(const Key('route-traffic-navigate')));
      await tester.pumpAndSettle();
      expect(launchedUri, isNotNull);
      expect(launchedUri!.host, 'uri.amap.com');

      // 验证复制简报
      await tester.tap(find.byKey(const Key('route-traffic-copy')));
      await tester.pumpAndSettle();
      expect(copiedText, isNotNull);
      expect(copiedText, contains('建德某厂火警'));
    });

    testWidgets('定位权限被拒时不阻断查询，降级展示天气并提示授权', (tester) async {
      var appSettingsOpened = false;

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-1',
          number: '2026-11-05-01',
          title: '建德某厂火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '新安东路1号'},
        ),
      );

      final noRouteInfo = RouteTrafficInfo(
        destination: mockRouteInfo.destination,
        origin: null,
        weather: mockRouteInfo.weather,
        forecast: mockRouteInfo.forecast,
        routes: const [],
        routeAvailable: false,
        degraded: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RouteTrafficPage(
            controller: controller,
            gateway: RouteTrafficGateway(
              requestPermission: () async => false, // 权限被拒
              locationServiceEnabled: () async => true,
              currentLocation: () async => null,
              fetchRouteTraffic: ({
                required address,
                city,
                originLat,
                originLon,
                destLat,
                destLon,
                destName,
                destAdcode,
              }) async {
                expect(originLat, isNull);
                expect(originLon, isNull);
                return noRouteInfo;
              },
              openAppSettings: () async {
                appSettingsOpened = true;
              },
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('未授予定位权限，暂无法计算本机至事发地耗时与路线'), findsOneWidget);
      expect(find.text('去授权'), findsOneWidget);
      await tester.tap(find.text('去授权'));
      expect(appSettingsOpened, isTrue);

      // 终点和天气依然展示
      expect(find.text('事发地气象与火场风向'), findsOneWidget);
      expect(find.text('多云'), findsWidgets);
    });

    testWidgets('存在同名村歧义时展示候选切换并支持手动选择', (tester) async {
      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-ambiguous',
          number: '2026-11-05-02',
          title: '东山村民房火灾',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '东山村'},
        ),
      );

      final ambiguousInfo = RouteTrafficInfo(
        destination: const RouteEndpointInfo(
          queryAddress: '东山村',
          formattedAddress: '浙江省衢州市常山县东山村',
          province: '浙江省',
          city: '衢州市',
          district: '常山县',
          adcode: '330822',
          location: AmapLocation(lat: 28.825, lon: 118.339, coordinate: 'gcj02'),
        ),
        ambiguous: true,
        candidates: const [
          RouteDestinationCandidate(
            name: '东山村',
            formattedAddress: '浙江省衢州市常山县东山村',
            district: '常山县',
            adcode: '330822',
            location: AmapLocation(lat: 28.825, lon: 118.339, coordinate: 'gcj02'),
          ),
          RouteDestinationCandidate(
            name: '东山村',
            formattedAddress: '浙江省衢州市江山市东山村',
            district: '江山市',
            adcode: '330881',
            location: AmapLocation(lat: 28.581, lon: 118.480, coordinate: 'gcj02'),
          ),
        ],
      );

      double? requestedDestLat;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RouteTrafficPage(
            controller: controller,
            gateway: RouteTrafficGateway(
              requestPermission: () async => true,
              locationServiceEnabled: () async => true,
              currentLocation: () async => null,
              fetchRouteTraffic: ({
                required address,
                city,
                originLat,
                originLon,
                destLat,
                destLon,
                destName,
                destAdcode,
              }) async {
                requestedDestLat = destLat;
                return ambiguousInfo;
              },
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 应当自动弹出多候选选择底栏
      expect(find.text('发现多处同名地点，请确认目的地'), findsOneWidget);
      expect(find.text('常山县'), findsOneWidget);
      expect(find.text('江山市'), findsOneWidget);

      // 点选江山市候选
      await tester.tap(find.byKey(const Key('route-candidate-item-1')));
      await tester.pumpAndSettle();

      // 底栏关闭，且按江山市坐标重新发起了请求
      expect(requestedDestLat, 28.581);
    });
  });
}
