import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/features/map/state/scene_map_store.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/china_coord.dart';

void main() {
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
}
