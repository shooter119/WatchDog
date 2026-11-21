import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/pages/scene_map_page.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/services/china_coord.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_palette.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

class _FakeController extends AppController {
  Incident? mockIncident;

  _FakeController({ApiClient? mockApi, this.mockIncident}) {
    api = mockApi;
  }

  @override
  Incident? get currentIncident => mockIncident;
}

class _StubApi extends ApiClient {
  _StubApi()
    : super(
        baseUrl: 'https://api.example.test',
        incidentId: 'inc-1',
        unitId: 'example-county-fire-rescue',
        sessionToken: 'sess-token',
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AppColors.reset();
  });

  group('ChinaCoord 坐标转换与测距', () {
    test('中国境内 WGS-84 转 GCJ-02 产生典型东偏北偏纠偏，境外原样返回', () {
      final gcj = ChinaCoord.wgs84ToGcj02(39.90923, 116.397428);
      // 北京附近 GCJ-02 相对 WGS-84 经度约 +0.006°、纬度约 +0.0014°
      expect(gcj.lon - 116.397428, inInclusiveRange(0.004, 0.009));
      expect(gcj.lat - 39.90923, inInclusiveRange(0.0005, 0.004));

      // 中国境外保持原值
      final outside = ChinaCoord.wgs84ToGcj02(35.681236, 139.767125);
      expect(outside.lat, 35.681236);
      expect(outside.lon, 139.767125);
    });

    test('distanceMeters 与 formatDistance 计算准确', () {
      // 同点距离为 0
      expect(ChinaCoord.distanceMeters(30.0, 120.0, 30.0, 120.0), 0.0);
      // 纬度差 0.01° 约 1111 米
      final d = ChinaCoord.distanceMeters(30.0, 120.0, 30.01, 120.0);
      expect(d, inInclusiveRange(1100, 1125));

      expect(ChinaCoord.formatDistance(420.4), '420 m');
      expect(ChinaCoord.formatDistance(1850), '1.9 km');
      expect(ChinaCoord.formatDistance(-1), '--');
    });

    test('bearingDegrees、cardinalDirection 与 shortenPinLabel 计算准确且安全', () {
      expect(ChinaCoord.bearingDegrees(30.0, 120.0, 31.0, 120.0), closeTo(0.0, 0.1));
      expect(ChinaCoord.bearingDegrees(0.0, 120.0, 0.0, 121.0), closeTo(90.0, 0.1));
      expect(ChinaCoord.bearingDegrees(30.0, 120.0, 29.0, 120.0), closeTo(180.0, 0.1));
      expect(ChinaCoord.bearingDegrees(0.0, 120.0, 0.0, 119.0), closeTo(270.0, 0.1));
      expect(ChinaCoord.bearingDegrees(30.0, 120.0, 30.0, 120.0), 0.0);
      expect(ChinaCoord.bearingDegrees(double.nan, 120.0, 30.0, 120.0), 0.0);

      expect(ChinaCoord.cardinalDirection(0), '正北');
      expect(ChinaCoord.cardinalDirection(350), '正北');
      expect(ChinaCoord.cardinalDirection(45), '东北');
      expect(ChinaCoord.cardinalDirection(90), '正东');
      expect(ChinaCoord.cardinalDirection(135), '东南');
      expect(ChinaCoord.cardinalDirection(180), '正南');
      expect(ChinaCoord.cardinalDirection(225), '西南');
      expect(ChinaCoord.cardinalDirection(270), '正西');
      expect(ChinaCoord.cardinalDirection(315), '西北');
      expect(ChinaCoord.cardinalDirection(double.infinity), '正北');

      expect(
        ChinaCoord.shortenPinLabel('  示例省示例市示例县示范大道88号  '),
        '示范大道88号',
      );
      expect(ChinaCoord.shortenPinLabel('示例县'), '示例县');
      expect(ChinaCoord.shortenPinLabel('示例小区3栋'), '示例小区3栋');
      expect(ChinaCoord.shortenPinLabel('示例县示范开发区示范路25号'), '示范开发区示范路25号');
      expect(
        ChinaCoord.shortenPinLabel(
          '示范乡镇工业园区一二三四五六七八九十路999号',
          maxChars: 12,
        ),
        '示范乡镇工业园区一二三…',
      );
      expect(ChinaCoord.shortenPinLabel('   '), '');
    });
  });

  group('SceneMapBootstrap 与 HTML 生成', () {
    test('SceneMapBootstrap 正确解析并拼合 serviceHost', () {
      final boot = SceneMapBootstrap.fromJson({
        'configured': true,
        'jsKey': 'test-js-key',
        'hasSecurityProxy': true,
        'proxyPath': '/api/amap-proxy/abc.def/_AMapService',
        'expiresInMs': 7200000,
      });
      expect(boot.configured, isTrue);
      expect(boot.jsKey, 'test-js-key');
      expect(
        boot.resolveServiceHost('https://api.example.test/'),
        'https://api.example.test/api/amap-proxy/abc.def/_AMapService',
      );
    });

    test('buildSceneMapHtml 注入 _AMapSecurityConfig、靶心箭头与屏外指引并防闭合脚本标签', () {
      final html = buildSceneMapHtml(
        jsKey: 'demo-key&1',
        serviceHost: 'https://api.example.test/api/amap-proxy/t/_AMapService',
        initialLayer: SceneMapLayerMode.hybrid,
        initialMyGcj: (lat: 29.501, lon: 119.302, accuracy: 12, bearing: 45),
        initialIncidentGcj: (
          lat: 29.512,
          lon: 119.315,
          title: '示例镇</script><script>alert(1)',
        ),
      );
      expect(html, contains('window._AMapSecurityConfig'));
      expect(
        html,
        contains(
          '"https://api.example.test/api/amap-proxy/t/_AMapService"',
        ),
      );
      expect(html, contains('https://webapi.amap.com/maps?v=2.0&key=demo-key%261'));
      expect(html, contains('new AMap.TileLayer.Satellite'));
      expect(html, contains('new AMap.TileLayer.RoadNet'));
      expect(html, contains('"hybrid"'));
      expect(html, contains('wd-incident-halo'));
      expect(html, contains('wd-incident-core'));
      expect(html, contains('wd-incident-stem'));
      expect(html, contains('wd-offscreen-guide'));
      expect(html, contains('focusIncidentFromGuide'));
      expect(html, contains('showDir: true'));
      expect(html, isNot(contains('AMap.Scale')));
      expect(html, isNot(contains('示例镇</script>')));

      // 无 JS Key 时自动降级内置高德瓦片滑块地图引擎（含 HiDPI 视网膜分级、靶心箭头与屏外指引）
      final fallbackHtml = buildSceneMapHtml(
        jsKey: '',
        initialLayer: SceneMapLayerMode.hybrid,
        initialMyGcj: (lat: 29.501, lon: 119.302, accuracy: 12, bearing: 45),
        initialIncidentGcj: (lat: 29.512, lon: 119.315, title: '示例省示例市示例县示范路88号'),
      );
      expect(fallbackHtml, contains('appmaptile?style=6'));
      expect(fallbackHtml, contains('appmaptile?style=8'));
      expect(fallbackHtml, contains('webrd0'));
      expect(fallbackHtml, contains('retinaOffset'));
      expect(fallbackHtml, contains('window.watchdogMap'));
      expect(fallbackHtml, contains('#overlay-svg { z-index: 10; }'));
      expect(fallbackHtml, contains('wd-incident-halo'));
      expect(fallbackHtml, contains('wd-incident-core'));
      expect(fallbackHtml, contains('wd-incident-stem'));
      expect(fallbackHtml, contains('wd-dest-arrow'));
      expect(fallbackHtml, contains('wd-offscreen-guide'));
      expect(fallbackHtml, contains('focusIncidentFromGuide'));
      expect(fallbackHtml, isNot(contains('wd-scale-wrap')));
      expect(fallbackHtml, isNot(contains('webapi.amap.com/maps?v=2.0')));
    });
  });

  group('SceneMapPage 组件与交互', () {
    testWidgets('默认卫星+路网、图层切换、连续定位跟踪、事发地联动与导航', (
      tester,
    ) async {
      final api = _StubApi();
      addTearDown(api.dispose);
      final controller = _FakeController(
        mockApi: api,
        mockIncident: const Incident(
          id: 'inc-1',
          number: '警情-01',
          title: '示例县仓储起火',
          status: 'active',
          createdAt: 1,
          lastActivityAt: 1,
          info: {
            'location': '示例镇人民路88号',
            'administrative_area': '示例县',
          },
        ),
      );
      addTearDown(controller.dispose);

      final locStream = StreamController<LocationFix>.broadcast();
      addTearDown(locStream.close);

      SceneMapSurfaceController? capturedSurface;
      void Function(String, Map<String, dynamic>)? capturedBridge;
      final launchedUris = <Uri>[];
      var allowNativeNav = true;
      var regeoCalls = 0;
      var currentTime = DateTime(2026, 11, 20, 10, 0, 0);

      final gateway = SceneMapGateway(
        requestPermission: () async => true,
        locationServiceEnabled: () async => true,
        currentLocation: () async => const LocationFix(
          lat: 29.500000,
          lon: 119.300000,
          accuracyMeters: 15,
          provider: 'gps',
          ageMs: 200,
          bearingDegrees: 90,
        ),
        watchLocation: () => locStream.stream,
        fetchMapBootstrap: () async => const SceneMapBootstrap(
          configured: true,
          jsKey: 'demo-js-key',
          hasSecurityProxy: true,
          proxyPath: '/api/amap-proxy/ticket1/_AMapService',
        ),
        fetchWeather: (lat, lon) async {
          regeoCalls++;
          return WeatherInfo(
            address: regeoCalls == 1
                ? '示例省示例市示例县示范大道10号'
                : '示例省示例市示例县示范大道99号',
          );
        },
        fetchIncidentRouteInfo: ({
          required String address,
          String? city,
          double? destLat,
          double? destLon,
        }) async => const RouteTrafficInfo(
          destination: RouteEndpointInfo(
            queryAddress: '示例镇人民路88号',
            formattedAddress: '示例省示例市示例县示例镇人民路88号',
            location: AmapLocation(
              lat: 29.510000,
              lon: 119.310000,
              coordinate: 'gcj02',
            ),
          ),
        ),
        openAppSettings: () async {},
        openLocationSettings: () async {},
        launchNavigation: (uri) async {
          launchedUris.add(uri);
          if (uri.scheme == 'androidamap') return allowNativeNav;
          return true;
        },
        now: () => currentTime,
        mapSurfaceBuilder: (context, surface, onBridgeEvent) {
          capturedSurface = surface;
          capturedBridge = onBridgeEvent;
          return const SizedBox.expand(key: Key('fake-map-surface'));
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SceneMapPage(controller: controller, gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();

      // 1. HTML 已加载且默认选中「卫星+路网」
      expect(find.byKey(const Key('fake-map-surface')), findsOneWidget);
      expect(capturedSurface?.lastLoadedHtml, contains('"hybrid"'));
      expect(
        capturedSurface?.lastLoadedHtml,
        contains('https://api.example.test/api/amap-proxy/ticket1/_AMapService'),
      );
      expect(find.text('示例省示例市示例县示范大道10号'), findsOneWidget);
      expect(find.text('±15 m'), findsOneWidget);
      expect(find.textContaining('WGS84 29.500000, 119.300000'), findsOneWidget);
      expect(find.text('示例省示例市示例县示例镇人民路88号'), findsOneWidget);
      expect(find.textContaining(' · 直线距离 '), findsOneWidget);
      expect(capturedSurface?.lastLoadedHtml, contains('示例镇人民路88号'));
      expect(regeoCalls, 1);

      // 2. 切换图层：「纯卫星」与「标准图」
      await tester.tap(find.byKey(const Key('scene-map-layer-satellite')));
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains('setLayerMode("satellite")'),
      );

      await tester.tap(find.byKey(const Key('scene-map-layer-standard')));
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains('setLayerMode("standard")'),
      );

      // 3. 连续定位推送（20秒后位移超 80m 触发一次新逆地理查询）
      currentTime = currentTime.add(const Duration(seconds: 20));
      locStream.add(
        const LocationFix(
          lat: 29.505000,
          lon: 119.305000,
          accuracyMeters: 8,
          provider: 'gps',
          ageMs: 50,
          bearingDegrees: 180,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('±8 m'), findsOneWidget);
      expect(find.textContaining('29.505000, 119.305000'), findsOneWidget);
      expect(find.text('示例省示例市示例县示范大道99号'), findsOneWidget);
      expect(regeoCalls, 2);

      // 4. 用户拖拽或从边缘指引跳转关闭自动跟随；点击视角按钮及底部事发地卡片
      capturedBridge?.call('userDragged', {});
      await tester.pump();
      await tester.tap(find.byKey(const Key('scene-map-focus-incident')));
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains('focusIncident()'),
      );

      await tester.tap(find.byKey(const Key('scene-map-fit-both')));
      await tester.pump();
      expect(capturedSurface!.evaluatedScripts.last, contains('fitBoth()'));

      await tester.tap(find.byKey(const Key('scene-map-focus-me')));
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains('focusMyLocation()'),
      );

      // 点击屏外方向指引跳到事发地时同步关闭自动跟随
      capturedBridge?.call('focusIncidentFromGuide', {});
      await tester.pump();
      locStream.add(
        const LocationFix(
          lat: 29.505100,
          lon: 119.305100,
          accuracyMeters: 8,
          provider: 'gps',
          ageMs: 50,
          bearingDegrees: 180,
        ),
      );
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains(', false);'),
      );

      // 点击底部遥测卡事发地文本也可直接聚焦事发地
      await tester.tap(find.byKey(const Key('scene-map-telemetry-incident')));
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains('focusIncident()'),
      );

      // 5. 一键导航：Android 优先拉起原生高德，失败时自动回退网页版高德导航
      await tester.tap(find.byKey(const Key('scene-map-navigate')));
      await tester.pump();
      expect(launchedUris, isNotEmpty);
      expect(launchedUris.last.scheme, 'androidamap');
      expect(launchedUris.last.host, 'navi');
      expect(launchedUris.last.queryParameters['lat'], '29.510000');

      allowNativeNav = false;
      await tester.tap(find.byKey(const Key('scene-map-navigate')));
      await tester.pump();
      expect(launchedUris.last.host, 'uri.amap.com');
      expect(launchedUris.last.queryParameters['mode'], 'car');
    });

    testWidgets('权限拒绝、定位关闭、引导异常、未配置 JS Key 自动降级栅格引擎、三套主题与大字号横屏无溢出', (
      tester,
    ) async {
      final api = _StubApi();
      addTearDown(api.dispose);
      final controller = _FakeController(mockApi: api);
      addTearDown(controller.dispose);

      var openAppSettingsCalled = false;
      final deniedGateway = SceneMapGateway(
        requestPermission: () async => false,
        locationServiceEnabled: () async => true,
        currentLocation: () async => null,
        watchLocation: () => const Stream.empty(),
        fetchMapBootstrap: () async => throw Exception('服务暂不可达'),
        fetchWeather: (_, __) async => WeatherInfo.empty,
        fetchIncidentRouteInfo: ({
          required String address,
          String? city,
          double? destLat,
          double? destLon,
        }) async => const RouteTrafficInfo(),
        openAppSettings: () async {
          openAppSettingsCalled = true;
        },
        openLocationSettings: () async {},
        launchNavigation: (_) async => false,
        now: DateTime.now,
      );

      tester.view.physicalSize = const Size(900, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final palette in AppPalette.values) {
        AppColors.use(palette);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(palette),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: SceneMapPage(controller: controller, gateway: deniedGateway),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('scene-map-unavailable-card')), findsOneWidget);
        expect(find.byKey(const Key('scene-map-focus-me')), findsNothing);
        expect(find.text('未授予定位权限，无法实时标记当前位置'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      await tester.tap(find.text('去授权'));
      await tester.pump();
      expect(openAppSettingsCalled, isTrue);

      // 服务端未配置 JS Key 时自动降级内置高德瓦片地图，不阻塞用户看卫星图
      SceneMapSurfaceController? fallbackSurface;
      final fallbackGateway = SceneMapGateway(
        requestPermission: () async => true,
        locationServiceEnabled: () async => true,
        currentLocation: () async => const LocationFix(
          lat: 29.500000,
          lon: 119.300000,
          accuracyMeters: 10,
          provider: 'gps',
          ageMs: 100,
        ),
        watchLocation: () => const Stream.empty(),
        fetchMapBootstrap: () async => const SceneMapBootstrap(
          configured: false,
          code: 'AMAP_JS_NOT_CONFIGURED',
          message: '服务端尚未配置高德 Web 端 (JS API) Key',
        ),
        fetchWeather: (_, __) async => WeatherInfo.empty,
        fetchIncidentRouteInfo: ({
          required String address,
          String? city,
          double? destLat,
          double? destLon,
        }) async => const RouteTrafficInfo(),
        openAppSettings: () async {},
        openLocationSettings: () async {},
        launchNavigation: (_) async => false,
        now: DateTime.now,
        mapSurfaceBuilder: (context, surface, _) {
          fallbackSurface = surface;
          return const SizedBox.expand(key: Key('fake-map-surface'));
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: SceneMapPage(
            key: const ValueKey('scene-map-fallback'),
            controller: controller,
            gateway: fallbackGateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fake-map-surface')), findsOneWidget);
      expect(find.byKey(const Key('scene-map-focus-me')), findsOneWidget);
      expect(find.byKey(const Key('scene-map-layer-hybrid')), findsOneWidget);
      expect(fallbackSurface?.lastLoadedHtml, contains('appmaptile?style=6'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('首页点击「现场地图」跳转到 SceneMapPage', (tester) async {
      final controller = AppController();
      controller.enterGuestMode();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HomePage(controller: controller))),
      );
      await tester.pumpAndSettle();

      final mapTile = find.byKey(const ValueKey('tool-现场地图'));
      await tester.ensureVisible(mapTile);
      await tester.tap(mapTile);
      await tester.pumpAndSettle();

      expect(find.byType(SceneMapPage), findsOneWidget);
      expect(find.text('请先完成单位认证后加载高德在线卫星图'), findsOneWidget);
    });
  });
}
