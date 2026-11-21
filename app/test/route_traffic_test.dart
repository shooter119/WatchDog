import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';

void main() {
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
      expect(
        emptyNameRoute.navigationUri?.queryParameters['to'],
        '119.300000,29.500000',
      );
      expect(
        emptyNameRoute.nativeAndroidNavigationUri?.queryParameters['poiname'],
        '事发地点',
      );

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
}
