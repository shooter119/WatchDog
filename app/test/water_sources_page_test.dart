import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/features/water_sources/state/water_sources_store.dart';

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

void main() {
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
}
