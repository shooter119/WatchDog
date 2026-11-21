import '../../../../core/models/amap_location.dart';
import 'route_models.dart';

class RouteTrafficInfo {
  final RouteEndpointInfo? destination;
  final RouteOriginInfo? origin;
  final RouteWeatherLive? weather;
  final String? weatherLine;
  final RouteWeatherForecast? forecast;
  final List<DrivingRoutePlan> routes;
  final bool routeAvailable;
  final bool degraded;
  final bool ambiguous;
  final List<RouteDestinationCandidate> candidates;

  const RouteTrafficInfo({
    this.destination,
    this.origin,
    this.weather,
    this.weatherLine,
    this.forecast,
    this.routes = const [],
    this.routeAvailable = false,
    this.degraded = false,
    this.ambiguous = false,
    this.candidates = const [],
  });

  AmapLocation? get _validDestinationLocation {
    final loc = destination?.location;
    if (loc == null ||
        loc.coordinate.toLowerCase() != 'gcj02' ||
        !loc.lat.isFinite ||
        !loc.lon.isFinite) {
      return null;
    }
    return loc;
  }

  Uri? get navigationUri {
    final loc = _validDestinationLocation;
    if (loc == null) return null;
    final destName = (destination?.displayAddress ?? '').trim();
    final coord =
        '${loc.lon.toStringAsFixed(6)},${loc.lat.toStringAsFixed(6)}';
    return Uri.https('uri.amap.com', '/navigation', {
      'to': destName.isNotEmpty ? '$coord,$destName' : coord,
      'mode': 'car',
      'src': 'watchdog',
      'callnative': '1',
    });
  }

  Uri? get nativeAndroidNavigationUri {
    final loc = _validDestinationLocation;
    if (loc == null) return null;
    final destName = (destination?.displayAddress ?? '').trim();
    return Uri(
      scheme: 'androidamap',
      host: 'navi',
      queryParameters: {
        'sourceApplication': 'watchdog',
        'poiname': destName.isNotEmpty ? destName : '事发地点',
        'lat': loc.lat.toStringAsFixed(6),
        'lon': loc.lon.toStringAsFixed(6),
        'dev': '0',
        'style': '2',
      },
    );
  }

  static String formatDuration(int durationSeconds) {
    final totalMinutes = durationSeconds <= 0
        ? 1
        : ((durationSeconds + 30) ~/ 60).clamp(1, 99999);
    if (totalMinutes < 60) {
      return '$totalMinutes 分钟';
    }
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    return mins == 0 ? '$hours小时' : '$hours小时$mins分';
  }

  static String formatDistance(int meters, {bool compactUnit = false}) {
    if (meters < 1000) {
      return compactUnit ? '$meters米' : '$meters 米';
    }
    final km = meters / 1000.0;
    return compactUnit
        ? '${km.toStringAsFixed(1)}公里'
        : '${km.toStringAsFixed(1)} 公里';
  }

  String toSummaryText({required String incidentName, int routeIndex = 0}) {
    final lines = <String>[];
    final cleanIncident = incidentName.trim();
    if (cleanIncident.isNotEmpty) {
      lines.add('警情：$cleanIncident');
    }
    final destAddr = destination?.displayAddress ?? '';
    if (destAddr.isNotEmpty) {
      lines.add('事发地点：$destAddr');
    }
    final originAddr = origin?.address.trim() ?? '';
    if (originAddr.isNotEmpty) {
      lines.add('出发位置：$originAddr');
    }
    if (routes.isNotEmpty) {
      final idx = routeIndex.clamp(0, routes.length - 1);
      final route = routes[idx];
      final durationText = formatDuration(route.durationSeconds);
      final distanceText = formatDistance(route.distanceMeters);
      lines.add(
        '预计行程：$durationText（$distanceText，红绿灯 ${route.trafficLights} 个）',
      );
      lines.add('整体路况：${route.overallStatus}');
      if (route.roads.isNotEmpty) {
        lines.add('途经道路：${route.roads.join(' → ')}');
      }
      if (route.congestedSegments.isNotEmpty) {
        final segText = route.congestedSegments
            .map(
              (s) =>
                  '${s.road} · ${s.status} ${formatDistance(s.distanceMeters, compactUnit: true)}',
            )
            .join('；');
        lines.add('拥堵提醒：$segText');
      } else {
        lines.add('拥堵提醒：当前路线全线畅通，无明显拥堵路段');
      }
    }
    final live = weather;
    if (live != null &&
        (live.text.isNotEmpty ||
            live.temperature.isNotEmpty ||
            live.windLabel.isNotEmpty)) {
      final weatherParts = <String>[
        if (live.text.isNotEmpty) live.text,
        if (live.temperature.isNotEmpty) '${live.temperature}℃',
        if (live.humidity.isNotEmpty) '湿度${live.humidity}%',
        if (live.windLabel.isNotEmpty) live.windLabel,
      ];
      lines.add('现场天气：${weatherParts.join(' · ')}');
    } else if ((weatherLine ?? '').trim().isNotEmpty) {
      lines.add('现场天气：${weatherLine!.trim()}');
    }
    final fc = forecast;
    if (fc != null &&
        (fc.dayWeather.isNotEmpty || fc.nightWeather.isNotEmpty)) {
      lines.add(
        '今日预报：白天${fc.dayWeather} ${fc.dayTemp}℃ / 夜间${fc.nightWeather} ${fc.nightTemp}℃',
      );
    }
    final nav = navigationUri;
    if (nav != null) {
      lines
        ..add('')
        ..add('高德驾车导航：')
        ..add(nav.toString());
    }
    return lines.join('\n');
  }

  factory RouteTrafficInfo.fromJson(Map<String, dynamic> json) {
    final rawRoutes = json['routes'] as List? ?? const [];
    final rawCandidates = json['candidates'] as List? ?? const [];
    return RouteTrafficInfo(
      destination: RouteEndpointInfo.fromJson(json['destination']),
      origin: RouteOriginInfo.fromJson(json['origin']),
      weather: RouteWeatherLive.fromJson(json['weather']),
      weatherLine: (json['weatherLine'] as String?)?.trim(),
      forecast: RouteWeatherForecast.fromJson(json['forecast']),
      routes: rawRoutes
          .whereType<Map>()
          .map((e) => DrivingRoutePlan.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      routeAvailable: json['routeAvailable'] == true,
      degraded: json['degraded'] == true,
      ambiguous: json['ambiguous'] == true,
      candidates: rawCandidates
          .whereType<Map>()
          .map((e) => RouteDestinationCandidate.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }
}
