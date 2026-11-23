import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/models/amap_location.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/map/data/models/route_models.dart';
import 'package:watchdog/features/map/data/models/route_traffic_info.dart';
import 'package:watchdog/features/map/data/models/scene_map_bootstrap.dart';
import 'package:watchdog/features/map/ui/scene_map_page.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/services/china_coord.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChinaCoord 坐标转换与测距', () {
    test('中国境内 WGS-84 转 GCJ-02 产生典型东偏北偏纠偏，境外原样返回', () {
      final gcj = ChinaCoord.wgs84ToGcj02(39.90923, 116.397428);
      expect(gcj.lon - 116.397428, inInclusiveRange(0.004, 0.009));
      expect(gcj.lat - 39.90923, inInclusiveRange(0.0005, 0.004));

      final outside = ChinaCoord.wgs84ToGcj02(35.681236, 139.767125);
      expect(outside.lat, 35.681236);
      expect(outside.lon, 139.767125);
    });

    test('distanceMeters 与 formatDistance 计算准确', () {
      expect(ChinaCoord.distanceMeters(30.0, 120.0, 30.0, 120.0), 0.0);
      final d = ChinaCoord.distanceMeters(30.0, 120.0, 30.01, 120.0);
      expect(d, inInclusiveRange(1100, 1125));
      expect(ChinaCoord.formatDistance(420.4), '420 m');
      expect(ChinaCoord.formatDistance(1850), '1.9 km');
      expect(ChinaCoord.formatDistance(-1), '--');
    });

    test('bearingDegrees、cardinalDirection 与 shortenPinLabel 计算准确且安全', () {
      expect(
        ChinaCoord.bearingDegrees(30.0, 120.0, 31.0, 120.0),
        closeTo(0.0, 0.1),
      );
      expect(
        ChinaCoord.bearingDegrees(0.0, 120.0, 0.0, 121.0),
        closeTo(90.0, 0.1),
      );
      expect(
        ChinaCoord.bearingDegrees(30.0, 120.0, 29.0, 120.0),
        closeTo(180.0, 0.1),
      );
      expect(
        ChinaCoord.bearingDegrees(0.0, 120.0, 0.0, 119.0),
        closeTo(270.0, 0.1),
      );
      expect(ChinaCoord.bearingDegrees(30.0, 120.0, 30.0, 120.0), 0.0);
      expect(ChinaCoord.bearingDegrees(double.nan, 120.0, 30.0, 120.0), 0.0);

      expect(ChinaCoord.cardinalDirection(0), '正北');
      expect(ChinaCoord.cardinalDirection(45), '东北');
      expect(ChinaCoord.cardinalDirection(90), '正东');
      expect(ChinaCoord.cardinalDirection(135), '东南');
      expect(ChinaCoord.cardinalDirection(180), '正南');
      expect(ChinaCoord.cardinalDirection(225), '西南');
      expect(ChinaCoord.cardinalDirection(270), '正西');
      expect(ChinaCoord.cardinalDirection(315), '西北');
      expect(ChinaCoord.cardinalDirection(double.infinity), '正北');

      expect(ChinaCoord.shortenPinLabel('  示例省示例市示例县示范大道88号  '), '示范大道88号');
      expect(ChinaCoord.shortenPinLabel('示例县'), '示例县');
      expect(ChinaCoord.shortenPinLabel('示例小区3栋'), '示例小区3栋');
      expect(
        ChinaCoord.shortenPinLabel('示例县示范开发区示范路25号'),
        '示范开发区示范路25号',
      );
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

    test('buildSceneMapHtml 注入 _AMapSecurityConfig、图层、靶心箭头与屏外指引并防闭合脚本标签', () {
      final html = buildSceneMapHtml(
        jsKey: 'demo-key&1',
        serviceHost: 'https://api.example.test/api/amap-proxy/t/_AMapService',
        initialLayer: SceneMapLayerMode.hybrid,
        initialTrafficEnabled: true,
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
        contains('"https://api.example.test/api/amap-proxy/t/_AMapService"'),
      );
      expect(
        html,
        contains('https://webapi.amap.com/maps?v=2.0&key=demo-key%261'),
      );
      expect(html, contains('new AMap.TileLayer.Satellite'));
      expect(html, contains('new AMap.TileLayer.RoadNet'));
      expect(html, contains('new AMap.TileLayer.Traffic'));
      expect(html, contains('"hybrid"'));
      expect(html, contains('wd-incident-halo'));
      expect(html, contains('wd-incident-core'));
      expect(html, contains('wd-incident-stem'));
      expect(html, contains('wd-offscreen-guide'));
      expect(html, contains('focusIncidentFromGuide'));
      expect(html, contains('showDir: true'));
      expect(html, isNot(contains('AMap.Scale')));
      expect(html, isNot(contains('示例镇</script>')));

      final fallbackHtml = buildSceneMapHtml(
        jsKey: '',
        initialLayer: SceneMapLayerMode.hybrid,
        initialMyGcj: (lat: 29.501, lon: 119.302, accuracy: 12, bearing: 45),
        initialIncidentGcj: (
          lat: 29.512,
          lon: 119.315,
          title: '示例省示例市示例县示范路88号',
        ),
      );
      expect(fallbackHtml, contains('appmaptile?style=6'));
      expect(fallbackHtml, contains('appmaptile?style=8'));
      expect(fallbackHtml, contains('webrd0'));
      expect(fallbackHtml, contains('retinaOffset'));
      expect(fallbackHtml, contains('window.watchdogMap'));
      expect(fallbackHtml, contains('#overlay-svg { z-index: 10; }'));
      expect(fallbackHtml, contains('wd-dest-arrow'));
      expect(fallbackHtml, contains('wd-offscreen-guide'));
      expect(fallbackHtml, isNot(contains('webapi.amap.com/maps?v=2.0')));
    });
  });

  group('SceneMapPage 组件与交互', () {
    testWidgets('默认卫星+路网、图层/路况切换、连续定位跟踪、事发地联动与导航', (tester) async {
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
        fetchAddress: (lat, lon) async {
          regeoCalls++;
          return SceneMapAddressResult(
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
        isAuthenticated: () => true,
        readBaseUrl: () => 'https://api.example.test',
        readCurrentIncident: () => const SceneMapIncidentContext(
          id: 'inc-1',
          displayName: '示例县仓储起火',
          effectiveLocation: '示例镇人民路88号',
          administrativeArea: '示例县',
        ),
        mapSurfaceBuilder: (context, surface, onBridgeEvent) {
          capturedSurface = surface;
          capturedBridge = onBridgeEvent;
          return const SizedBox.expand(key: Key('fake-map-surface'));
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: SceneMapPage(gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();

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
      expect(regeoCalls, 1);

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

      await tester.tap(find.byKey(const Key('scene-map-layer-traffic')));
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains('setTrafficEnabled(true)'),
      );

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
      expect(find.text('示例省示例市示例县示范大道99号'), findsOneWidget);
      expect(regeoCalls, 2);

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
      expect(capturedSurface!.evaluatedScripts.last, contains(', false);'));

      await tester.tap(find.byKey(const Key('scene-map-telemetry-incident')));
      await tester.pump();
      expect(
        capturedSurface!.evaluatedScripts.last,
        contains('focusIncident()'),
      );

      await tester.tap(find.byKey(const Key('scene-map-navigate')));
      await tester.pump();
      expect(launchedUris.last.scheme, 'androidamap');

      allowNativeNav = false;
      await tester.tap(find.byKey(const Key('scene-map-navigate')));
      await tester.pump();
      expect(launchedUris.last.host, 'uri.amap.com');
    });

    testWidgets('权限拒绝、未认证、降级栅格引擎，以及昼白/暗曜 360dp @ 130% 字号零溢出', (
      tester,
    ) async {
      var openAppSettingsCalled = false;
      final deniedGateway = SceneMapGateway(
        requestPermission: () async => false,
        locationServiceEnabled: () async => true,
        currentLocation: () async => null,
        watchLocation: () => const Stream.empty(),
        fetchMapBootstrap: () async => throw Exception('服务暂不可达'),
        fetchAddress: (_, _) async => SceneMapAddressResult.empty,
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
        isAuthenticated: () => true,
        readBaseUrl: () => 'https://api.example.test',
        readCurrentIncident: () => null,
      );

      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
            home: SceneMapPage(
              key: ValueKey('denied-$brightness'),
              gateway: deniedGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('scene-map-unavailable-card')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('scene-map-focus-me')), findsNothing);
        expect(find.text('未授予定位权限，无法实时标记当前位置'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      await tester.tap(find.text('去授权'));
      await tester.pump();
      expect(openAppSettingsCalled, isTrue);

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
        fetchAddress: (_, _) async => SceneMapAddressResult.empty,
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
        isAuthenticated: () => true,
        readBaseUrl: () => 'https://api.example.test',
        readCurrentIncident: () => null,
        mapSurfaceBuilder: (context, surface, _) {
          fallbackSurface = surface;
          return const SizedBox.expand(key: Key('fake-map-surface'));
        },
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
          home: SceneMapPage(
            key: const ValueKey('fallback'),
            gateway: fallbackGateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fake-map-surface')), findsOneWidget);
      expect(find.byKey(const Key('scene-map-focus-me')), findsOneWidget);
      expect(fallbackSurface?.lastLoadedHtml, contains('appmaptile?style=6'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '粗粒度降级时展示预警与完整地址，支持高德搜原址与候选点切换重定位',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        final launched = <Uri>[];
        final candidateRequests = <
          ({double? lat, double? lon, String? name, String? adcode})
        >[];
        SceneMapSurfaceController? surfaceCtrl;

        final gateway = SceneMapGateway(
          requestPermission: () async => true,
          locationServiceEnabled: () async => true,
          currentLocation: () async => const LocationFix(
            lat: 29.020000,
            lon: 119.170000,
            accuracyMeters: 10,
            provider: 'gps',
            ageMs: 100,
          ),
          watchLocation: () => const Stream.empty(),
          fetchMapBootstrap: () async => const SceneMapBootstrap(
            configured: false,
            code: 'AMAP_JS_NOT_CONFIGURED',
          ),
          fetchAddress: (_, _) async =>
              const SceneMapAddressResult(address: '示例省示例市示例县示例路1号'),
          fetchIncidentRouteInfo: ({
            required String address,
            String? city,
            double? destLat,
            double? destLon,
          }) async => const RouteTrafficInfo(),
          fetchIncidentRouteInfoWithCandidate: ({
            required String address,
            String? city,
            double? destLat,
            double? destLon,
            String? destName,
            String? destAdcode,
          }) async {
            candidateRequests.add((
              lat: destLat,
              lon: destLon,
              name: destName,
              adcode: destAdcode,
            ));
            if (destLat != null &&
                destLon != null &&
                (destLat - 28.864321).abs() < 0.001) {
              return RouteTrafficInfo(
                destination: RouteEndpointInfo(
                  queryAddress: address,
                  formattedAddress: '示例省示例市示例县示例镇示例垄路段',
                  precision: 'exact',
                  precisionLevel: '兴趣点',
                  precisionDegraded: false,
                  location: const AmapLocation(
                    lat: 28.864321,
                    lon: 119.156789,
                    coordinate: 'gcj02',
                  ),
                ),
              );
            }
            return RouteTrafficInfo(
              destination: RouteEndpointInfo(
                queryAddress: address,
                formattedAddress: '示例省示例市示例县351国道示例镇示例垄路段',
                precision: 'coarse',
                precisionLevel: '乡镇',
                precisionDegraded: true,
                resolvedAddress: '示例省示例市示例县示例镇',
                location: const AmapLocation(
                  lat: 28.900000,
                  lon: 119.110000,
                  coordinate: 'gcj02',
                ),
              ),
              candidates: const [
                RouteDestinationCandidate(
                  name: '示例镇人民政府',
                  formattedAddress: '示例省示例市示例县示例镇人民政府',
                  district: '示例县',
                  adcode: '330825',
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
                  adcode: '330825',
                  location: AmapLocation(
                    lat: 28.864321,
                    lon: 119.156789,
                    coordinate: 'gcj02',
                  ),
                ),
              ],
            );
          },
          openAppSettings: () async {},
          openLocationSettings: () async {},
          launchNavigation: (uri) async {
            launched.add(uri);
            return true;
          },
          now: DateTime.now,
          isAuthenticated: () => true,
          readBaseUrl: () => 'https://api.example.test',
          readCurrentIncident: () => const SceneMapIncidentContext(
            id: 'inc-coarse-map',
            displayName: '货车轮胎起火',
            effectiveLocation: '示例县351国道示例镇示例垄路段',
            administrativeArea: '示例县',
          ),
          mapSurfaceBuilder: (context, surface, _) {
            surfaceCtrl = surface;
            return const SizedBox.expand(key: Key('fake-map-surface'));
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: buildCommandTheme(Brightness.light),
            home: SceneMapPage(gateway: gateway),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('示例省示例市示例县351国道示例镇示例垄路段'), findsOneWidget);
        expect(find.byKey(const Key('scene-map-coarse-warning')), findsOneWidget);
        expect(find.text('仅定位至乡镇级，坐标可能偏移'), findsOneWidget);
        expect(find.byKey(const Key('scene-map-amap-search')), findsOneWidget);
        expect(find.byKey(const Key('scene-map-switch-candidate')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('scene-map-amap-search')));
        await tester.pumpAndSettle();
        expect(launched.last.scheme, 'androidamap');
        expect(launched.last.host, 'poi');
        expect(launched.last.queryParameters['keywords'], '示例县351国道示例镇示例垄路段');

        await tester.tap(find.byKey(const Key('scene-map-switch-candidate')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('scene-map-candidate-item-1')), findsOneWidget);

        await tester.tap(find.byKey(const Key('scene-map-candidate-item-1')));
        await tester.pumpAndSettle();

        expect(candidateRequests.last.lat, closeTo(28.864321, 0.0001));
        expect(candidateRequests.last.lon, closeTo(119.156789, 0.0001));
        expect(candidateRequests.last.name, '示例垄');
        expect(find.byKey(const Key('scene-map-coarse-warning')), findsNothing);
        expect(surfaceCtrl!.evaluatedScripts.last, contains('119.156789, 28.864321'));
      },
    );
  });
}
