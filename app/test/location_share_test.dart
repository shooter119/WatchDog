import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/location_share_service.dart';

DateTime get _now => DateTime(2026, 10, 21, 10, 30);

const _amapLocation = AmapLocation(
  lat: 30.25678,
  lon: 120.12345,
  coordinate: 'gcj02',
);

LocationShareDraft _draft({double accuracy = 8, int ageMinutes = 0}) {
  return LocationShareDraft(
    incidentName: '示例仓库火灾',
    unitName: '示例县消防救援大队',
    address: '示例省示例市示例县示范路1号',
    locatedAt: _now.subtract(Duration(minutes: ageMinutes)),
    lat: 30.25,
    lon: 120.12,
    accuracyMeters: accuracy,
    amapLocation: _amapLocation,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('分享链接使用正确经纬度顺序、callnative=1 与降级规则', () {
    final draft = _draft();
    expect(draft.hasAmapLocation, isTrue);
    expect(draft.markerUri.host, 'uri.amap.com');
    expect(draft.markerUri.path, '/marker');
    expect(draft.markerUri.queryParameters, {
      'position': '120.123450,30.256780',
      'name': '示例仓库火灾',
      'src': 'watchdog',
      'coordinate': 'gaode',
      'callnative': '1',
    });

    final degraded = LocationShareDraft(
      incidentName: '',
      unitName: draft.unitName,
      address: '',
      locatedAt: draft.locatedAt,
      lat: draft.lat,
      lon: draft.lon,
      accuracyMeters: draft.accuracyMeters,
      amapLocation: null,
    );
    expect(degraded.hasAmapLocation, isFalse);
    expect(degraded.markerUri.queryParameters, {
      'position': '120.120000,30.250000',
      'name': '现场位置',
      'src': 'watchdog',
      'coordinate': 'wgs84',
      'callnative': '1',
    });
  });

  test('分享文案仅保留单个查看位置链接、固定顺序输出且不包含发送人', () {
    final draft = _draft();
    final text = draft.toShareText(now: _now);
    final fields = [
      '警情：示例仓库火灾',
      '单位：示例县消防救援大队',
      '位置：示例省示例市示例县示范路1号',
      '时间：2026-10-21 10:30',
      '精度：约 8.0 米',
      'WGS84：30.250000, 120.120000',
      '查看位置：',
      draft.markerUri.toString(),
    ];
    var previous = -1;
    for (final field in fields) {
      final index = text.indexOf(field);
      expect(index, greaterThan(previous), reason: field);
      previous = index;
    }
    expect(text, contains('src=watchdog'));
    expect(text, contains('callnative=1'));
    expect(text, contains('coordinate=gaode'));
    expect(text, isNot(contains('驾车导航：')));
    expect(text, isNot(contains('/navigation')));
    expect(text, isNot(contains('发送人')));
    expect(text, isNot(contains('姓名')));
  });

  test('天气响应防御性解析高德坐标字段', () {
    final info = WeatherInfo.fromJson({
      'address': '测试地址',
      'line': '晴 · 28℃',
      'amapLocation': {
        'lat': 30.25678,
        'lon': 120.12345,
        'coordinate': 'gcj02',
      },
      'coordinateDegraded': false,
      'degraded': false,
    });
    expect(info.address, '测试地址');
    expect(info.amapLocation?.lat, 30.25678);
    expect(info.amapLocation?.lon, 120.12345);
    expect(info.amapLocation?.coordinate, 'gcj02');
    expect(info.coordinateDegraded, isFalse);
    expect(WeatherInfo.fromJson({'amapLocation': 'bad'}).amapLocation, isNull);
  });
}
