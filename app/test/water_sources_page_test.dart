import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/models/water_source.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/pages/water_sources_page.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/services/china_coord.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

class _FakeController extends AppController {
  _FakeController({ApiClient? mockApi}) {
    api = mockApi;
  }
}

class _StubApi extends ApiClient {
  _StubApi()
    : super(
        baseUrl: 'https://api.example.test',
        incidentId: '',
        unitId: 'example-unit-1',
        sessionToken: 'sess-token',
      );
}

WaterSource _sampleSource({
  required String id,
  required String name,
  WaterSourceCategory category = WaterSourceCategory.hydrant,
  WaterSourceStatus status = WaterSourceStatus.available,
  double lat = 30.2500,
  double lng = 120.1500,
  List<WaterIntakeMethod> intakeMethods = const [],
  String note = '',
  int updatedAt = 1730000000000,
  String updatedByName = '张三',
}) {
  return WaterSource(
    id: id,
    unitId: 'example-unit-1',
    category: category,
    name: name,
    lat: lat,
    lng: lng,
    status: status,
    intakeMethods: intakeMethods,
    note: note,
    createdBy: 'm-1',
    createdByName: '张三',
    createdAt: updatedAt - 1000,
    updatedBy: 'm-1',
    updatedByName: updatedByName,
    updatedAt: updatedAt,
  );
}

Widget _wrapApp(Widget home) {
  return MaterialApp(theme: buildAppTheme(), home: home);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AppColors.reset();
  });

  group('WaterSource 数据模型与编解码', () {
    test('snake_case JSON 往返一致，firstNoteLine 正确提取首行非空备注', () {
      final raw = {
        'id': 'ws-1',
        'unit_id': 'example-unit-1',
        'category': 'natural',
        'name': '示范公园消防水池',
        'lat': 30.251234,
        'lng': 120.152345,
        'status': 'available',
        'intake_methods': ['fire_truck', 'portable_pump', 'invalid_ignored'],
        'note': '\n  容量 200 立方米\n东侧可停靠消防车',
        'created_by': 'u-1',
        'created_by_name': '张三',
        'created_at': 1730000001000,
        'updated_by': 'u-2',
        'updated_by_name': '李四',
        'updated_at': 1730000002000,
        'deleted_at': null,
        'deleted_by': null,
        'deleted_by_name': null,
      };

      final parsed = WaterSource.fromJson(raw);
      expect(parsed.id, 'ws-1');
      expect(parsed.category, WaterSourceCategory.natural);
      expect(parsed.status, WaterSourceStatus.available);
      expect(parsed.isAvailable, isTrue);
      expect(parsed.intakeMethods, [
        WaterIntakeMethod.fireTruck,
        WaterIntakeMethod.portablePump,
      ]);
      expect(parsed.firstNoteLine, '容量 200 立方米');
      expect(parsed.latestActorName, '李四');

      final encoded = parsed.toJson();
      expect(encoded['unit_id'], 'example-unit-1');
      expect(encoded['category'], 'natural');
      expect(encoded['intake_methods'], ['fire_truck', 'portable_pump']);
      expect(encoded['lng'], 120.152345);
    });

    test('WaterSourceListResult 解析摘要与列表', () {
      final listResult = WaterSourceListResult.fromJson({
        'items': [
          _sampleSource(id: '1', name: '示范路消火栓').toJson(),
          _sampleSource(
            id: '2',
            name: '示例楼接合器',
            category: WaterSourceCategory.pumpConnector,
            status: WaterSourceStatus.unavailable,
          ).toJson(),
        ],
        'summary': {
          'total': 2,
          'available': 1,
          'unavailable': 1,
          'by_category': {'hydrant': 1, 'natural': 0, 'pump_connector': 1},
        },
      });
      expect(listResult.items.length, 2);
      expect(listResult.summary.total, 2);
      expect(listResult.summary.available, 1);
      expect(listResult.summary.unavailable, 1);
      expect(listResult.summary.pumpConnector, 1);
    });
  });

  group('高德 JS 2.0 地图 HTML 契约', () {
    test('固定卫星+路网、图标旁默认显示名称、含安全代理与 401 续签监听，不含逆地理与外部导航', () {
      final html = buildWaterSourcesMapHtml(
        jsKey: 'test-amap-key',
        serviceHost: 'https://api.example.test/api/amap-proxy/tkt',
        initialItems: [
          _sampleSource(id: 'ws-1', name: '示范路1号栓', note: '水压充足'),
        ],
      );
      expect(html, contains('AMap.LabelsLayer'));
      expect(html, contains('AMap.LabelMarker'));
      expect(html, contains('AMap.TileLayer.Satellite'));
      expect(html, contains('AMap.TileLayer.RoadNet'));
      expect(html, isNot(contains('createDefaultLayer')));
      expect(html, contains("direction: 'right'"));
      expect(html, contains('window._AMapSecurityConfig'));
      expect(html, contains('ticketExpired'));
      expect(html, isNot(contains('regeo')));
      expect(html, isNot(contains('androidamap://')));
      expect(html, isNot(contains('iosamap://')));
    });
  });

  group('WaterSourcesPage 交互与降级测试', () {
    testWidgets('正常进入全屏地图展示，不展示底部列表与图层切换，支持类别/仅看可用筛选', (tester) async {
      tester.view.physicalSize = const Size(420, 960);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const wgsLat = 30.2500;
      const wgsLon = 120.1500;
      final myGcj = ChinaCoord.wgs84ToGcj02(wgsLat, wgsLon);

      final nearHydrant = _sampleSource(
        id: 'near',
        name: '近处示范消火栓',
        lat: myGcj.lat + 0.0005,
        lng: myGcj.lon,
        note: '压力正常',
      );
      final midNatural = _sampleSource(
        id: 'mid',
        name: '中距示例消防水池',
        category: WaterSourceCategory.natural,
        intakeMethods: const [WaterIntakeMethod.fireTruck],
        lat: myGcj.lat + 0.002,
        lng: myGcj.lon,
        note: '水池容量150方',
      );
      final farBroken = _sampleSource(
        id: 'far',
        name: '远处损坏接合器',
        category: WaterSourceCategory.pumpConnector,
        status: WaterSourceStatus.unavailable,
        lat: myGcj.lat + 0.01,
        lng: myGcj.lon,
        note: '闷盖缺失',
      );

      final controller = _FakeController(mockApi: _StubApi());
      final gateway = WaterSourcesGateway(
        requestLocationPermission: () async => true,
        isLocationServiceEnabled: () async => true,
        currentLocation: () async => const LocationFix(
          lat: wgsLat,
          lon: wgsLon,
          accuracyMeters: 15,
          provider: 'gps',
          ageMs: 0,
        ),
        fetchMapBootstrap: () async => const SceneMapBootstrap(
          configured: true,
          jsKey: 'test-key',
          hasSecurityProxy: true,
          proxyPath: '/api/amap-proxy/t1',
          expiresInMs: 600000,
        ),
        fetchWaterSources: () async => WaterSourceListResult(
          items: [farBroken, midNatural, nearHydrant],
          summary: WaterSourceSummary.fromItems([
            farBroken,
            midNatural,
            nearHydrant,
          ]),
        ),
      );

      var latestMapItems = const <WaterSource>[];
      await tester.pumpWidget(
        _wrapApp(
          WaterSourcesPage(
            controller: controller,
            gateway: gateway,
            mapBuilder: (ctx, state) {
              latestMapItems = state.items;
              return Container(
                key: const Key('fake-water-map'),
                alignment: Alignment.center,
                child: Text('mock-map:${state.items.length}'),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 全屏地图模式：不展示底部列表，不展示底图切换按钮
      expect(find.byKey(const Key('fake-water-map')), findsOneWidget);
      expect(find.byKey(const Key('water-sources-list')), findsNothing);
      expect(find.byKey(const Key('water-map-layer-toggle')), findsNothing);

      // 地图收到的点位按距离升序：near < mid < far
      expect(latestMapItems.map((e) => e.id).toList(), ['near', 'mid', 'far']);

      // 切换「仅看可用」后，不可用点位从地图隐藏
      final onlyAvailFinder = find.byKey(
        const Key('water-filter-only-available'),
      );
      await tester.ensureVisible(onlyAvailFinder);
      await tester.pumpAndSettle();
      await tester.tap(onlyAvailFinder);
      await tester.pumpAndSettle();
      expect(latestMapItems.map((e) => e.id).toList(), ['near', 'mid']);

      // 切换类别「天然水源」
      final naturalFilter = find.byKey(const Key('water-filter-natural'));
      await tester.ensureVisible(naturalFilter);
      await tester.pumpAndSettle();
      await tester.tap(naturalFilter);
      await tester.pumpAndSettle();
      expect(latestMapItems.map((e) => e.id).toList(), ['mid']);
    });

    testWidgets('十字准星新增天然水源时强校验多选取水方式，选中后成功保存', (tester) async {
      WaterSource? createdRecord;
      final controller = _FakeController(mockApi: _StubApi());
      final gateway = WaterSourcesGateway(
        requestLocationPermission: () async => true,
        isLocationServiceEnabled: () async => true,
        currentLocation: () async => const LocationFix(
          lat: 30.25,
          lon: 120.15,
          accuracyMeters: 10,
          provider: 'gps',
          ageMs: 0,
        ),
        fetchMapBootstrap: () async => const SceneMapBootstrap(
          configured: true,
          jsKey: 'test-key',
        ),
        fetchWaterSources: () async => const WaterSourceListResult(
          items: [],
          summary: WaterSourceSummary(),
        ),
        createWaterSource: ({
          required WaterSourceCategory category,
          required String name,
          required double lat,
          required double lng,
          WaterSourceStatus status = WaterSourceStatus.available,
          List<WaterIntakeMethod> intakeMethods = const [],
          String note = '',
        }) async {
          createdRecord = _sampleSource(
            id: 'ws-new',
            name: name,
            category: category,
            lat: lat,
            lng: lng,
            status: status,
            intakeMethods: intakeMethods,
            note: note,
          );
          return createdRecord!;
        },
      );

      await tester.pumpWidget(
        _wrapApp(
          WaterSourcesPage(
            controller: controller,
            gateway: gateway,
            mapBuilder: (ctx, state) => Container(
              key: const Key('fake-water-map'),
              child: state.pickingMode
                  ? TextButton(
                      key: const Key('simulate-pan'),
                      onPressed: () =>
                          state.onPickCenterChanged(30.261111, 120.162222),
                      child: const Text('模拟拖图'),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 点击新增进入十字准星选点模式
      await tester.tap(find.byKey(const Key('water-sources-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('water-map-crosshair')), findsOneWidget);

      // 模拟拖动地图微调准星坐标并确认位置
      await tester.tap(find.byKey(const Key('simulate-pan')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('water-pick-confirm')));
      await tester.pumpAndSettle();

      // 填写点位简称并选择「天然水源」但不选取水方式 -> 校验拦截
      await tester.enterText(
        find.byKey(const Key('water-form-name')),
        '示例河道取水点',
      );
      await tester.tap(find.byKey(const Key('water-form-cat-natural')));
      await tester.pumpAndSettle();

      final submitBtn = find.byKey(const Key('water-form-submit'));
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();
      expect(find.text('天然水源至少选择一项取水方式'), findsOneWidget);
      expect(createdRecord, isNull);

      // 勾选两项取水方式后提交成功
      await tester.tap(find.byKey(const Key('water-form-intake-portable_pump')));
      await tester.tap(find.byKey(const Key('water-form-intake-fire_truck')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      expect(createdRecord, isNotNull);
      expect(createdRecord!.name, '示例河道取水点');
      expect(createdRecord!.lat, closeTo(30.261111, 1e-6));
      expect(createdRecord!.lng, closeTo(120.162222, 1e-6));
      expect(createdRecord!.intakeMethods, [
        WaterIntakeMethod.portablePump,
        WaterIntakeMethod.fireTruck,
      ]);
      expect(find.text('全部 (1)'), findsOneWidget);
    });

    testWidgets('点击地图标记弹出详情窗口，支持快捷切状态与软删除后 60 秒撤销恢复', (tester) async {
      var item = _sampleSource(
        id: 'ws-toggle',
        name: '示例大道消火栓',
        status: WaterSourceStatus.available,
        note: '水压正常',
      );
      var deleteCalls = 0;
      var restoreCalls = 0;
      var latestMapItems = const <WaterSource>[];

      final controller = _FakeController(mockApi: _StubApi());
      final gateway = WaterSourcesGateway(
        requestLocationPermission: () async => false,
        fetchMapBootstrap: () async => const SceneMapBootstrap(
          configured: true,
          jsKey: 'test-key',
        ),
        fetchWaterSources: () async => WaterSourceListResult(
          items: [item],
          summary: WaterSourceSummary.fromItems([item]),
        ),
        updateWaterSource: (
          id, {
          category,
          name,
          lat,
          lng,
          status,
          intakeMethods,
          note,
        }) async {
          item = item.copyWith(status: status ?? item.status);
          return item;
        },
        deleteWaterSource: (id) async {
          deleteCalls++;
          return 1730000099000;
        },
        restoreWaterSource: (id) async {
          restoreCalls++;
          return item;
        },
      );

      await tester.pumpWidget(
        _wrapApp(
          WaterSourcesPage(
            controller: controller,
            gateway: gateway,
            mapBuilder: (ctx, state) {
              latestMapItems = state.items;
              return Center(
                key: const Key('fake-map'),
                child: state.items.isNotEmpty
                    ? TextButton(
                        key: const Key('simulate-marker-tap'),
                        onPressed: () =>
                            state.onSelectMarker(state.items.first.id),
                        child: const Text('点标记'),
                      )
                    : const SizedBox.shrink(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 点击地图标记弹出详情窗口，显示点位具体信息
      await tester.tap(find.byKey(const Key('simulate-marker-tap')));
      await tester.pumpAndSettle();
      expect(find.text('示例大道消火栓'), findsOneWidget);
      expect(find.text('水压正常'), findsOneWidget);

      // 快捷切换为不可用
      await tester.tap(find.byKey(const Key('water-detail-toggle-status')));
      await tester.pumpAndSettle();
      expect(item.status, WaterSourceStatus.unavailable);
      expect(find.text('不可用'), findsWidgets);

      // 点击删除并确认
      await tester.tap(find.byKey(const Key('water-detail-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(deleteCalls, 1);
      expect(latestMapItems, isEmpty);
      expect(find.text('撤销'), findsOneWidget);

      // 点击底部 60 秒撤销条恢复
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(restoreCalls, 1);
      expect(latestMapItems.length, 1);
      expect(latestMapItems.first.id, 'ws-toggle');
    });

    testWidgets('无定位权限且底图未配置时展示降级提示与重试按钮，保留可搜索列表', (tester) async {
      var locRetryCount = 0;
      final older = _sampleSource(
        id: 'old',
        name: '旧示例消火栓',
        updatedAt: 1730000001000,
      );
      final newer = _sampleSource(
        id: 'new',
        name: '新示例消火栓',
        updatedAt: 1730000009000,
      );

      final controller = _FakeController(mockApi: _StubApi());
      final gateway = WaterSourcesGateway(
        requestLocationPermission: () async {
          locRetryCount++;
          return false;
        },
        fetchMapBootstrap: () async => const SceneMapBootstrap(
          configured: false,
          message: '底图服务暂未配置',
        ),
        fetchWaterSources: () async => WaterSourceListResult(
          items: [older, newer],
          summary: WaterSourceSummary.fromItems([older, newer]),
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          WaterSourcesPage(controller: controller, gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('water-location-degraded-banner')),
        findsOneWidget,
      );
      expect(find.text('底图服务暂未配置'), findsOneWidget);
      expect(find.byKey(const Key('water-map-retry')), findsOneWidget);
      expect(find.byKey(const Key('water-location-retry')), findsOneWidget);

      // 无定位时按 updatedAt 降序展示
      final newY = tester.getTopLeft(find.byKey(const Key('water-card-new'))).dy;
      final oldY = tester.getTopLeft(find.byKey(const Key('water-card-old'))).dy;
      expect(newY, lessThan(oldY));

      // 点击重试定位触发重新请求权限
      await tester.tap(find.byKey(const Key('water-location-retry')));
      await tester.pumpAndSettle();
      expect(locRetryCount, 2);
    });
  });

  group('HomePage 现场工具入口', () {
    testWidgets('现场工具网格包含第 9 张「周边水源」卡片', (tester) async {
      final controller = _FakeController(mockApi: _StubApi());
      await tester.pumpWidget(
        _wrapApp(
          Scaffold(body: HomePage(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      final waterTile = find.byKey(const ValueKey('tool-周边水源'));
      expect(waterTile, findsOneWidget);
      expect(find.text('周边水源'), findsOneWidget);
    });
  });
}
