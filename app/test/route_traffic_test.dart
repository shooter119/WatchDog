import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/route_traffic_page.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_palette.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

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
      queryAddress: '示范东路1号',
      formattedAddress: '示例省示例市示例县示例街道示范东路1号',
      city: '示例市',
      district: '示例县',
      adcode: '330182',
      location: AmapLocation(lat: 29.474, lon: 119.281, coordinate: 'gcj02'),
    ),
    origin: const RouteOriginInfo(
      address: '示例省示例市示例县示例南街道示范大道',
      location: AmapLocation(lat: 29.491, lon: 119.302, coordinate: 'gcj02'),
    ),
    weather: const RouteWeatherLive(
      text: '多云',
      temperature: '22',
      humidity: '65',
      windDirection: '东南',
      windPower: '≤3',
      city: '示例县',
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
        roads: const ['示范大道', '示范大桥', '示范东路'],
        trafficSummary: const TrafficSummary(
          smoothMeters: 5200,
          slowMeters: 1200,
          jamMeters: 400,
        ),
        congestedSegments: const [
          CongestedSegment(road: '示范大桥', status: '拥堵', distanceMeters: 400),
        ],
        steps: const [
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
      const DrivingRoutePlan(
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

    test('生成高德驾车导航链接与 Android 原生 URI', () {
      final uri = mockRouteInfo.navigationUri;
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'uri.amap.com');
      expect(uri.path, '/navigation');
      expect(uri.queryParameters, {
        'to': '119.281000,29.474000,示例省示例市示例县示例街道示范东路1号',
        'mode': 'car',
        'src': 'watchdog',
        'callnative': '1',
      });

      final nativeUri = mockRouteInfo.nativeAndroidNavigationUri;
      expect(nativeUri, isNotNull);
      expect(nativeUri!.scheme, 'androidamap');
      expect(nativeUri.host, 'navi');
      expect(nativeUri.queryParameters, {
        'sourceApplication': 'watchdog',
        'poiname': '示例省示例市示例县示例街道示范东路1号',
        'lat': '29.474000',
        'lon': '119.281000',
        'dev': '0',
        'style': '2',
      });

      const emptyNameRoute = RouteTrafficInfo(
        destination: RouteEndpointInfo(
          queryAddress: '',
          formattedAddress: '',
          location: AmapLocation(lat: 29.5, lon: 119.3, coordinate: 'gcj02'),
        ),
      );
      expect(emptyNameRoute.navigationUri?.queryParameters['to'], '119.300000,29.500000');
      expect(emptyNameRoute.nativeAndroidNavigationUri?.queryParameters['poiname'], '事发地点');

      const wgs84Route = RouteTrafficInfo(
        destination: RouteEndpointInfo(
          queryAddress: '示例大道100号',
          formattedAddress: '示例市示例大道100号',
          location: AmapLocation(lat: 29.5, lon: 119.3, coordinate: 'wgs84'),
        ),
      );
      expect(wgs84Route.navigationUri, isNull);
      expect(wgs84Route.nativeAndroidNavigationUri, isNull);
    });

    test('生成路况纯文本简报', () {
      final text = mockRouteInfo.toSummaryText(incidentName: '示例县某厂火警');
      expect(text, contains('警情：示例县某厂火警'));
      expect(text, contains('事发地点：示例省示例市示例县示例街道示范东路1号'));
      expect(text, contains('预计行程：13 分钟（6.8 公里，红绿灯 6 个）'));
      expect(text, contains('整体路况：局部缓行'));
      expect(text, contains('途经道路：示范大道 → 示范大桥 → 示范东路'));
      expect(text, contains('拥堵提醒：示范大桥 · 拥堵 400米'));
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
          title: '示例县某厂火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {
            'location': '示范东路1号',
            'administrative_area': '示例县',
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
                expect(address, '示范东路1号');
                expect(city, '示例县');
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
      expect(find.text('示范大桥'), findsWidgets);
      expect(find.text('主要途经道路'), findsOneWidget);
      expect(find.text('示范大道'), findsWidgets);
      expect(find.text('示范东路'), findsWidgets);
      expect(find.text('事发地气象与火场风向'), findsOneWidget);
      expect(find.text('多云'), findsWidgets);
      expect(find.text('22℃'), findsOneWidget);
      expect(find.textContaining('风向：东南风 · ≤3级'), findsOneWidget);
      expect(find.textContaining('上风或侧上风方向停车'), findsOneWidget);

      // 验证多方案切换（直接展示策略名，不再拼接「方案N · 」前缀）
      expect(find.text('速度最快'), findsOneWidget);
      expect(find.text('备选路线'), findsOneWidget);
      expect(find.textContaining('方案1'), findsNothing);
      await tester.tap(find.text('备选路线'));
      await tester.pumpAndSettle();
      expect(find.text('15 分钟'), findsOneWidget);
      expect(find.text('7.5 公里'), findsOneWidget);

      // 验证导航按钮（Android 环境优先尝试拉起原生高德 App）
      await tester.tap(find.byKey(const Key('route-traffic-navigate')));
      await tester.pumpAndSettle();
      expect(launchedUri, isNotNull);
      expect(launchedUri!.scheme, 'androidamap');
      expect(launchedUri!.host, 'navi');

      // 验证复制简报
      await tester.tap(find.byKey(const Key('route-traffic-copy')));
      await tester.pumpAndSettle();
      expect(copiedText, isNotNull);
      expect(copiedText, contains('示例县某厂火警'));
    });

    testWidgets('定位权限被拒时不阻断查询，降级展示天气并提示授权', (tester) async {
      var appSettingsOpened = false;

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-1',
          number: '2026-11-05-01',
          title: '示例县某厂火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '示范东路1号'},
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
          formattedAddress: '示例省示例市甲县东山村',
          province: '示例省',
          city: '示例市',
          district: '甲县',
          adcode: '330822',
          location: AmapLocation(lat: 28.825, lon: 118.339, coordinate: 'gcj02'),
        ),
        ambiguous: true,
        candidates: const [
          RouteDestinationCandidate(
            name: '东山村',
            formattedAddress: '示例省示例市甲县东山村',
            district: '甲县',
            adcode: '330822',
            location: AmapLocation(lat: 28.825, lon: 118.339, coordinate: 'gcj02'),
          ),
          RouteDestinationCandidate(
            name: '东山村',
            formattedAddress: '示例省示例市乙市东山村',
            district: '乙市',
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
      expect(find.text('甲县'), findsOneWidget);
      expect(find.text('乙市'), findsOneWidget);

      // 点选乙市候选
      await tester.tap(find.byKey(const Key('route-candidate-item-1')));
      await tester.pumpAndSettle();

      // 底栏关闭，且按乙市坐标重新发起了请求
      expect(requestedDestLat, 28.581);
    });

    testWidgets('气象卡片置顶展示（位于起终点卡片之前）', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-1',
          number: '2026-11-05-01',
          title: '示例县某厂火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {
            'location': '示范东路1号',
            'administrative_area': '示例县',
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
              }) async => mockRouteInfo,
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final weatherTop = tester.getTopLeft(find.text('事发地气象与火场风向')).dy;
      final endpointsTop = tester.getTopLeft(find.text('示例省示例市示例县示例街道示范东路1号')).dy;

      expect(weatherTop, lessThan(endpointsTop), reason: '气象卡片必须置顶于起终点卡片之前');
    });

    testWidgets('窄屏与超长预报文本下切换路线方案无 RenderFlex 溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 900); // 极窄屏幕
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final longWeatherInfo = RouteTrafficInfo(
        destination: const RouteEndpointInfo(
          queryAddress: '示范东路1号',
          formattedAddress: '示例省示例市示例县示例街道示范东路1号超长测试地址地址地址地址',
        ),
        weather: const RouteWeatherLive(
          text: '强雷阵雨伴有冰雹',
          temperature: '38',
          humidity: '99',
          windDirection: '西北偏北超强阵风',
          windPower: '9-10',
          city: '示例县超长行政区划测试',
        ),
        forecast: const RouteWeatherForecast(
          dayWeather: '特大暴雨转大暴雨强对流大风黄色预警',
          nightWeather: '阴转小雨局部有轻度雾霾伴微风',
          dayTemp: '36',
          nightTemp: '24',
        ),
        routes: [
          DrivingRoutePlan(
            strategy: '方案一避开拥堵优先高架超长策略名称',
            distanceMeters: 168000,
            durationSeconds: 10800,
            trafficLights: 38,
            overallStatus: '严重拥堵',
            roads: const ['示范大道超长路段一', '示范大桥跨江通道超长路段二', '示范东路核心主干道超长三'],
            trafficSummary: const TrafficSummary(
              smoothMeters: 52000,
              slowMeters: 32000,
              jamMeters: 44000,
              severeJamMeters: 40000,
            ),
            congestedSegments: const [
              CongestedSegment(
                road: '示范大桥超长拥堵路段名极其狭窄空间测试专用',
                status: '严重拥堵',
                distanceMeters: 40000,
              ),
              CongestedSegment(
                road: '示范东路某某辅路口持续缓行路段',
                status: '缓行',
                distanceMeters: 32000,
              ),
            ],
          ),
          const DrivingRoutePlan(
            strategy: '方案二备选常规通道',
            distanceMeters: 175000,
            durationSeconds: 12000,
            trafficLights: 45,
            overallStatus: '畅通',
            roads: ['示范大道', '示范二路'],
            trafficSummary: TrafficSummary(
              smoothMeters: 175000,
            ),
          ),
        ],
        routeAvailable: true,
      );

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-narrow',
          number: '2026-11-05-03',
          title: '窄屏测试火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '示范东路1号'},
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
              }) async => longWeatherInfo,
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 无 RenderFlex 异常
      expect(tester.takeException(), isNull);
      expect(find.textContaining('严重拥堵'), findsWidgets);

      // 切换到方案二
      await tester.ensureVisible(find.byKey(const Key('route-strategy-chip-1')));
      await tester.tap(find.byKey(const Key('route-strategy-chip-1')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('当前路线全线畅通，无明显拥堵路段。'), findsOneWidget);

      // 切换回方案一
      await tester.ensureVisible(find.byKey(const Key('route-strategy-chip-0')));
      await tester.tap(find.byKey(const Key('route-strategy-chip-0')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('暖砂配色下各项语义色正常生效且无静态报错', (tester) async {
      AppColors.use(AppPalette.warmSand);
      addTearDown(AppColors.reset);

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-warm',
          number: '2026-11-05-04',
          title: '暖砂主题测试',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '示范东路1号'},
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(AppPalette.warmSand),
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
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('事发地气象与火场风向'), findsOneWidget);
    });

    testWidgets('官方高精度坐标直传 fetchRouteTraffic，跳过逆地理编码', (tester) async {
      double? capturedDestLat;
      double? capturedDestLon;

      final controller = AppController();
      controller.currentIncident = Incident(
        id: 'inc-official-coords',
        number: '20261108001',
        title: '示例镇示范加油站附近',
        status: 'active',
        createdAt: 1000,
        lastActivityAt: 2000,
        info: {
          'location': '示例镇示范加油站附近',
          'administrative_area': '示例区',
          'latitude': '28.869366',
          'longitude': '118.980502',
        },
      );

      await tester.pumpWidget(
        MaterialApp(
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
                capturedDestLat = destLat;
                capturedDestLon = destLon;
                return mockRouteInfo;
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

      expect(capturedDestLat, 28.869366);
      expect(capturedDestLon, 118.980502);
    });

    testWidgets('空 strategy 兜底文案正确且不带方案编号前缀', (tester) async {
      final fallbackInfo = RouteTrafficInfo(
        destination: const RouteEndpointInfo(
          queryAddress: '示例大道100号',
          formattedAddress: '示例市示例大道100号',
          location: AmapLocation(lat: 29.474, lon: 119.281, coordinate: 'gcj02'),
        ),
        routes: const [
          DrivingRoutePlan(
            strategy: '',
            distanceMeters: 4200,
            durationSeconds: 480,
            trafficLights: 3,
          ),
          DrivingRoutePlan(
            strategy: '',
            distanceMeters: 5100,
            durationSeconds: 600,
            trafficLights: 5,
          ),
        ],
        routeAvailable: true,
      );

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-empty-strategy',
          number: '2026-11-15-01',
          title: '示例火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '示例大道100号', 'administrative_area': '示例市'},
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
              }) async => fallbackInfo,
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('时间最短'), findsOneWidget);
      expect(find.text('备选路线'), findsOneWidget);
      expect(find.textContaining('方案1'), findsNothing);
      expect(find.textContaining('方案2'), findsNothing);
    });

    testWidgets(
      'Android 原生拉起返回 false 或抛异常时自动回退高德 Web 导航链接',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
      final launched = <Uri>[];
      var throwOnNative = false;
      var failAll = false;

      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-fallback',
          number: '2026-11-15-02',
          title: '示例火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '示例大道100号', 'administrative_area': '示例市'},
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
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (uri) async {
                launched.add(uri);
                if (failAll) return false;
                if (uri.scheme == 'androidamap') {
                  if (throwOnNative) throw Exception('no amap app');
                  return false;
                }
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1) 原生返回 false -> 回退 webUri
      await tester.tap(find.byKey(const Key('route-traffic-navigate')));
      await tester.pumpAndSettle();
      expect(launched.map((u) => u.scheme).toList(), ['androidamap', 'https']);
      expect(launched.last.host, 'uri.amap.com');

      // 2) 原生抛异常 -> 捕获异常并回退 webUri
      launched.clear();
      throwOnNative = true;
      await tester.tap(find.byKey(const Key('route-traffic-navigate')));
      await tester.pumpAndSettle();
      expect(launched.map((u) => u.scheme).toList(), ['androidamap', 'https']);

      // 3) 两者均失败 -> 提示无法打开外部地图导航应用
      launched.clear();
      throwOnNative = false;
      failAll = true;
      await tester.tap(find.byKey(const Key('route-traffic-navigate')));
      await tester.pumpAndSettle();
      expect(find.text('无法打开外部地图导航应用'), findsOneWidget);
    },
    );

    testWidgets(
      '非 Android 平台直接拉起高德 Web 导航链接',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
      final launched = <Uri>[];
      final controller = _FakeController(
        mockIncident: const Incident(
          id: 'inc-ios',
          number: '2026-11-15-03',
          title: '示例火警',
          status: 'active',
          createdAt: 1000,
          lastActivityAt: 2000,
          info: {'location': '示例大道100号', 'administrative_area': '示例市'},
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
              openAppSettings: () async {},
              openLocationSettings: () async {},
              copyText: (_) async {},
              launchNavigation: (uri) async {
                launched.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('route-traffic-navigate')));
      await tester.pumpAndSettle();
      expect(launched, hasLength(1));
      expect(launched.single.scheme, 'https');
      expect(launched.single.host, 'uri.amap.com');
      expect(launched.single.queryParameters['callnative'], '1');
    },
    );
  });
}
