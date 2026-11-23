import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/models/amap_location.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/map/ui/route_traffic_page.dart';
import 'package:watchdog/services/camera_bridge.dart';

RouteTrafficGateway _makeGateway({
  bool permitted = true,
  bool serviceEnabled = true,
  LocationFix? fix,
  required Future<RouteTrafficInfo> Function({
    required String address,
    String? city,
    double? originLat,
    double? originLon,
    double? destLat,
    double? destLon,
    String? destName,
    String? destAdcode,
  })
  fetchRouteTraffic,
  Future<Map<String, dynamic>> Function(String incidentId)? fetchIncidentDetails,
  Future<void> Function()? openAppSettings,
  Future<void> Function()? openLocationSettings,
  Future<void> Function(String text)? copyText,
  Future<bool> Function(Uri uri)? launchNavigation,
}) {
  return RouteTrafficGateway(
    requestPermission: () async => permitted,
    locationServiceEnabled: () async => serviceEnabled,
    currentLocation: () async => fix,
    fetchRouteTraffic: fetchRouteTraffic,
    fetchIncidentDetails: fetchIncidentDetails,
    openAppSettings: openAppSettings ?? () async {},
    openLocationSettings: openLocationSettings ?? () async {},
    copyText: copyText ?? (_) async {},
    launchNavigation: launchNavigation ?? (_) async => true,
  );
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

      final nativeUri = mockRouteInfo.nativeAndroidNavigationUri;
      expect(nativeUri, isNotNull);
      expect(nativeUri!.scheme, 'androidamap');
      expect(nativeUri.host, 'navi');
      expect(nativeUri.queryParameters['lat'], '29.474000');

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

    test('生成路况纯文本简报与防御性 JSON 解析', () {
      final text = mockRouteInfo.toSummaryText(incidentName: '示例县某厂火警');
      expect(text, contains('警情：示例县某厂火警'));
      expect(text, contains('预计行程：13 分钟（6.8 公里，红绿灯 6 个）'));
      expect(text, contains('拥堵提醒：示范大桥 · 拥堵 400米'));
      expect(text, contains('现场天气：多云 · 22℃ · 湿度65% · 东南风 · ≤3级'));

      final parsed = RouteTrafficInfo.fromJson({
        'destination': {'queryAddress': '某地点'},
        'routes': [
          {'distance': 1000, 'duration': 120},
        ],
      });
      expect(parsed.destination?.queryAddress, '某地点');
      expect(parsed.routes.single.distanceMeters, 1000);
    });

    test('RouteEndpointInfo 解析粗粒度精度字段并生成高德搜原址 URI 与简报附注', () {
      const coarseEndpoint = RouteEndpointInfo(
        queryAddress: '示例县351国道示例镇示例垄路段',
        formattedAddress: '示例省示例市示例县351国道示例镇示例垄路段',
        precision: 'coarse',
        precisionLevel: '乡镇',
        precisionDegraded: true,
        resolvedAddress: '示例省示例市示例县示例镇',
        location: AmapLocation(lat: 28.9, lon: 119.11, coordinate: 'gcj02'),
      );
      expect(coarseEndpoint.isCoarse, isTrue);

      final parsed = RouteEndpointInfo.fromJson({
        'queryAddress': '示例县351国道示例镇示例垄路段',
        'formattedAddress': '示例省示例市示例县351国道示例镇示例垄路段',
        'precision': 'coarse',
        'precisionLevel': '乡镇',
        'precisionDegraded': true,
        'resolvedAddress': '示例省示例市示例县示例镇',
        'location': {'lat': 28.9, 'lon': 119.11, 'coordinate': 'gcj02'},
      });
      expect(parsed, isNotNull);
      expect(parsed!.isCoarse, isTrue);
      expect(parsed.precisionLevel, '乡镇');
      expect(parsed.resolvedAddress, '示例省示例市示例县示例镇');

      final parsedDefault = RouteEndpointInfo.fromJson({
        'queryAddress': '示例路1号',
        'formattedAddress': '示例县示例路1号',
      });
      expect(parsedDefault!.isCoarse, isFalse);
      expect(parsedDefault.precision, 'exact');

      const coarseRoute = RouteTrafficInfo(destination: coarseEndpoint);
      expect(coarseRoute.amapSearchWebUri?.host, 'uri.amap.com');
      expect(coarseRoute.amapSearchWebUri?.path, '/search');
      expect(
        coarseRoute.amapSearchWebUri?.queryParameters['keyword'],
        '示例县351国道示例镇示例垄路段',
      );
      expect(coarseRoute.nativeAndroidAmapSearchUri?.scheme, 'androidamap');
      expect(coarseRoute.nativeAndroidAmapSearchUri?.host, 'poi');
      expect(
        coarseRoute.nativeAndroidAmapSearchUri?.queryParameters['keywords'],
        '示例县351国道示例镇示例垄路段',
      );
      expect(
        coarseRoute.toSummaryText(incidentName: '货车轮胎起火'),
        contains('当前仅定位至乡镇级，请核对具体路段'),
      );
    });
  });

  group('RouteTrafficPage 界面测试', () {
    testWidgets('未选警情时显示空状态并触发选择警情回调', (tester) async {
      var selectCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: RouteTrafficPage(
            gateway: _makeGateway(
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
            ),
            readCurrentIncident: () => null,
            onRequestIncidentSelection: () => selectCalled = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('尚未选择正在处置的警情'), findsOneWidget);
      await tester.tap(find.byKey(const Key('route-traffic-select-incident')));
      expect(selectCalled, isTrue);
    });

    testWidgets('警情无具体地点时提示完善警情信息并暴露编辑/导入入口', (tester) async {
      var editCalls = 0;
      var importCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: RouteTrafficPage(
            gateway: _makeGateway(
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
              fetchIncidentDetails: (_) async => {'data': {}},
            ),
            readCurrentIncident: () => const RouteTrafficIncidentContext(
              id: 'inc-1',
              displayName: '测试警情',
            ),
            onEditIncidentDetails: () async => editCalls++,
            onImportIncidentDetails: () async => importCalls++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('警情缺少事发地点'), findsOneWidget);
      await tester.tap(find.byKey(const Key('route-traffic-edit-details')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('route-traffic-import-details')));
      await tester.pumpAndSettle();
      expect(editCalls, 1);
      expect(importCalls, 1);
    });

    testWidgets('气象置顶、多策略切换、分段展开、复制简报与导航', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String? copiedText;
      Uri? launchedUri;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: RouteTrafficPage(
            gateway: _makeGateway(
              fix: const LocationFix(
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
                return mockRouteInfo;
              },
              copyText: (t) async => copiedText = t,
              launchNavigation: (uri) async {
                launchedUri = uri;
                return true;
              },
            ),
            readCurrentIncident: () => const RouteTrafficIncidentContext(
              id: 'inc-1',
              displayName: '示例县某厂火警',
              location: '示范东路1号',
              administrativeArea: '示例县',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final weatherTop = tester.getTopLeft(find.text('事发地气象与火场风向')).dy;
      final endpointsTop = tester
          .getTopLeft(find.text('示例省示例市示例县示例街道示范东路1号'))
          .dy;
      expect(weatherTop, lessThan(endpointsTop));

      expect(find.text('13 分钟'), findsOneWidget);
      expect(find.text('6.8 公里'), findsOneWidget);
      expect(find.text('红绿灯 6 个'), findsOneWidget);
      expect(find.text('路况：局部缓行'), findsOneWidget);
      expect(find.textContaining('风向：东南风 · ≤3级'), findsOneWidget);

      await tester.tap(find.text('备选路线'));
      await tester.pumpAndSettle();
      expect(find.text('15 分钟'), findsOneWidget);
      expect(find.text('7.5 公里'), findsOneWidget);

      await tester.tap(find.byKey(const Key('route-traffic-navigate')));
      await tester.pumpAndSettle();
      expect(launchedUri?.scheme, 'androidamap');

      await tester.tap(find.byKey(const Key('route-traffic-copy')));
      await tester.pumpAndSettle();
      expect(copiedText, contains('示例县某厂火警'));
    });

    testWidgets('定位被拒降级展示天气并提示授权；官方坐标直传', (tester) async {
      var appSettingsOpened = false;
      double? capturedDestLat;
      double? capturedDestLon;

      final noRouteInfo = RouteTrafficInfo(
        destination: mockRouteInfo.destination,
        weather: mockRouteInfo.weather,
        forecast: mockRouteInfo.forecast,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: RouteTrafficPage(
            gateway: _makeGateway(
              permitted: false,
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
                return noRouteInfo;
              },
              openAppSettings: () async => appSettingsOpened = true,
            ),
            readCurrentIncident: () => const RouteTrafficIncidentContext(
              id: 'inc-coords',
              displayName: '示例镇示范加油站附近',
              location: '示例镇示范加油站附近',
              administrativeArea: '示例区',
              officialLat: 28.869366,
              officialLon: 118.980502,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(capturedDestLat, 28.869366);
      expect(capturedDestLon, 118.980502);
      expect(find.text('未授予定位权限，暂无法计算本机至事发地耗时与路线'), findsOneWidget);
      await tester.tap(find.text('去授权'));
      expect(appSettingsOpened, isTrue);
      expect(find.text('事发地气象与火场风向'), findsOneWidget);
    });

    testWidgets('同名村歧义自动弹出候选底栏并支持点选重查', (tester) async {
      final ambiguousInfo = RouteTrafficInfo(
        destination: const RouteEndpointInfo(
          queryAddress: '东山村',
          formattedAddress: '示例省示例市甲县东山村',
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
          theme: buildCommandTheme(Brightness.light),
          home: RouteTrafficPage(
            gateway: _makeGateway(
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
            ),
            readCurrentIncident: () => const RouteTrafficIncidentContext(
              id: 'inc-amb',
              displayName: '东山村民房火灾',
              location: '东山村',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('发现多处同名地点，请确认目的地'), findsOneWidget);
      await tester.tap(find.byKey(const Key('route-candidate-item-1')));
      await tester.pumpAndSettle();
      expect(requestedDestLat, 28.581);
    });

    testWidgets(
      'Android 原生拉起失败回退高德 Web 导航链接',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        final launched = <Uri>[];
        var failAll = false;

        await tester.pumpWidget(
          MaterialApp(
            theme: buildCommandTheme(Brightness.light),
            home: RouteTrafficPage(
              gateway: _makeGateway(
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
                launchNavigation: (uri) async {
                  launched.add(uri);
                  if (failAll) return false;
                  if (uri.scheme == 'androidamap') return false;
                  return true;
                },
              ),
              readCurrentIncident: () => const RouteTrafficIncidentContext(
                id: 'inc-fb',
                displayName: '示例火警',
                location: '示例大道100号',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('route-traffic-navigate')));
        await tester.pumpAndSettle();
        expect(launched.map((u) => u.scheme).toList(), ['androidamap', 'https']);

        launched.clear();
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
        await tester.pumpWidget(
          MaterialApp(
            theme: buildCommandTheme(Brightness.light),
            home: RouteTrafficPage(
              gateway: _makeGateway(
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
                launchNavigation: (uri) async {
                  launched.add(uri);
                  return true;
                },
              ),
              readCurrentIncident: () => const RouteTrafficIncidentContext(
                id: 'inc-ios',
                displayName: '示例火警',
                location: '示例大道100号',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('route-traffic-navigate')));
        await tester.pumpAndSettle();
        expect(launched.single.scheme, 'https');
        expect(launched.single.host, 'uri.amap.com');
      },
    );

    testWidgets('360dp @ 130% 字号在昼白/暗曜下零溢出且空 strategy 兜底正确', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final emptyStrategyInfo = RouteTrafficInfo(
        destination: mockRouteInfo.destination,
        origin: mockRouteInfo.origin,
        weather: mockRouteInfo.weather,
        forecast: mockRouteInfo.forecast,
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

      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildCommandTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: RouteTrafficPage(
              key: ValueKey('rt-$brightness'),
              gateway: _makeGateway(
                fetchRouteTraffic: ({
                  required address,
                  city,
                  originLat,
                  originLon,
                  destLat,
                  destLon,
                  destName,
                  destAdcode,
                }) async => emptyStrategyInfo,
              ),
              readCurrentIncident: () => const RouteTrafficIncidentContext(
                id: 'inc-scale',
                displayName: '测试警情',
                location: '示范东路1号',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('时间最短'), findsOneWidget);
        expect(find.text('备选路线'), findsOneWidget);
        expect(find.textContaining('方案1'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets(
      '精度降级至乡镇时保留完整地址、展示预警横幅并支持高德搜原址（原生失败回退网页）',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final launched = <Uri>[];
        var allowNativeSearch = true;

        const coarseInfo = RouteTrafficInfo(
          destination: RouteEndpointInfo(
            queryAddress: '示例县351国道示例镇示例垄路段',
            formattedAddress: '示例省示例市示例县351国道示例镇示例垄路段',
            precision: 'coarse',
            precisionLevel: '乡镇',
            precisionDegraded: true,
            resolvedAddress: '示例省示例市示例县示例镇',
            location: AmapLocation(
              lat: 28.900000,
              lon: 119.110000,
              coordinate: 'gcj02',
            ),
          ),
          candidates: [
            RouteDestinationCandidate(
              name: '示例镇人民政府',
              formattedAddress: '示例省示例市示例县示例镇人民政府',
              district: '示例县',
              location: AmapLocation(
                lat: 28.900000,
                lon: 119.110000,
                coordinate: 'gcj02',
              ),
            ),
            RouteDestinationCandidate(
              name: '示例垄',
              formattedAddress: '示例省示例市示例县示例镇示例垄',
              district: '示例县',
              location: AmapLocation(
                lat: 28.864321,
                lon: 119.156789,
                coordinate: 'gcj02',
              ),
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: buildCommandTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: RouteTrafficPage(
              gateway: _makeGateway(
                fetchRouteTraffic: ({
                  required address,
                  city,
                  originLat,
                  originLon,
                  destLat,
                  destLon,
                  destName,
                  destAdcode,
                }) async => coarseInfo,
                launchNavigation: (uri) async {
                  launched.add(uri);
                  if (uri.scheme == 'androidamap') return allowNativeSearch;
                  return true;
                },
              ),
              readCurrentIncident: () => const RouteTrafficIncidentContext(
                id: 'inc-coarse-1',
                displayName: '货车轮胎起火',
                location: '示例县351国道示例镇示例垄路段',
                administrativeArea: '示例县',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('示例省示例市示例县351国道示例镇示例垄路段'), findsOneWidget);
        expect(find.byKey(const Key('route-traffic-coarse-banner')), findsOneWidget);
        expect(find.textContaining('定位精度降级：仅定位至乡镇级'), findsOneWidget);
        expect(find.byKey(const Key('route-traffic-amap-search')), findsOneWidget);
        expect(
          find.byKey(const Key('route-traffic-coarse-switch-candidate')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('route-traffic-amap-search')));
        await tester.pumpAndSettle();
        expect(launched.last.scheme, 'androidamap');
        expect(launched.last.host, 'poi');
        expect(
          launched.last.queryParameters['keywords'],
          '示例县351国道示例镇示例垄路段',
        );

        allowNativeSearch = false;
        await tester.tap(find.byKey(const Key('route-traffic-amap-search')));
        await tester.pumpAndSettle();
        expect(launched.last.scheme, 'https');
        expect(launched.last.host, 'uri.amap.com');
        expect(launched.last.path, '/search');
      },
    );

    testWidgets('编辑详情改址后强制拉取最新详情且清除旧坐标', (tester) async {
      var detailsCalls = 0;
      final routeCoords = <({double? lat, double? lon})>[];
      var edited = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: RouteTrafficPage(
            gateway: _makeGateway(
              fetchIncidentDetails: (id) async {
                detailsCalls++;
                return {
                  'data': edited
                      ? {
                          'location': '示例镇工业园8号',
                          'administrative_area': '示例县',
                          'latitude': '',
                          'longitude': '',
                        }
                      : {
                          'location': '示例路1号',
                          'administrative_area': '示例县',
                          'latitude': '29.100000',
                          'longitude': '119.200000',
                        },
                };
              },
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
                routeCoords.add((lat: destLat, lon: destLon));
                return mockRouteInfo;
              },
            ),
            readCurrentIncident: () => const RouteTrafficIncidentContext(
              id: 'inc-edit-clear',
              displayName: '厂房冒烟',
              location: '示例路1号',
              administrativeArea: '示例县',
              officialLat: 29.100000,
              officialLon: 119.200000,
            ),
            onEditIncidentDetails: () async {
              edited = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(detailsCalls, 0);
      expect(routeCoords.last, (lat: 29.100000, lon: 119.200000));

      await tester.tap(find.text('修改'));
      await tester.pumpAndSettle();
      expect(detailsCalls, 1);
      expect(routeCoords.last.lat, isNull);
      expect(routeCoords.last.lon, isNull);
    });
  });
}
