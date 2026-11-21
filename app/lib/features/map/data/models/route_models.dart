import '../../../../core/models/amap_location.dart';

class RouteEndpointInfo {
  final String queryAddress;
  final String formattedAddress;
  final String province;
  final String city;
  final String district;
  final String adcode;
  final AmapLocation? location;

  const RouteEndpointInfo({
    required this.queryAddress,
    required this.formattedAddress,
    this.province = '',
    this.city = '',
    this.district = '',
    this.adcode = '',
    this.location,
  });

  String get displayAddress =>
      formattedAddress.trim().isNotEmpty ? formattedAddress.trim() : queryAddress.trim();

  static RouteEndpointInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteEndpointInfo(
      queryAddress: json['queryAddress']?.toString().trim() ?? '',
      formattedAddress: json['formattedAddress']?.toString().trim() ?? '',
      province: json['province']?.toString().trim() ?? '',
      city: json['city']?.toString().trim() ?? '',
      district: json['district']?.toString().trim() ?? '',
      adcode: json['adcode']?.toString().trim() ?? '',
      location: AmapLocation.fromJson(json['location']),
    );
  }
}

class RouteOriginInfo {
  final String address;
  final AmapLocation? location;
  final bool coordinateDegraded;

  const RouteOriginInfo({
    this.address = '',
    this.location,
    this.coordinateDegraded = false,
  });

  static RouteOriginInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteOriginInfo(
      address: json['address']?.toString().trim() ?? '',
      location: AmapLocation.fromJson(json['location']),
      coordinateDegraded: json['coordinateDegraded'] == true,
    );
  }
}

class RouteWeatherLive {
  final String text;
  final String temperature;
  final String humidity;
  final String windDirection;
  final String windPower;
  final String observedAt;
  final String city;

  const RouteWeatherLive({
    this.text = '',
    this.temperature = '',
    this.humidity = '',
    this.windDirection = '',
    this.windPower = '',
    this.observedAt = '',
    this.city = '',
  });

  String get windLabel {
    final dir = windDirection.trim();
    final power = windPower.trim();
    final parts = <String>[];
    if (dir.isNotEmpty) {
      parts.add(dir.endsWith('风') || dir.contains('风向') ? dir : '$dir风');
    }
    if (power.isNotEmpty) {
      parts.add(power.endsWith('级') ? power : '$power级');
    }
    return parts.join(' · ');
  }

  static RouteWeatherLive? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteWeatherLive(
      text: json['text']?.toString().trim() ?? '',
      temperature: json['temperature']?.toString().trim() ?? '',
      humidity: json['humidity']?.toString().trim() ?? '',
      windDirection: json['windDirection']?.toString().trim() ?? '',
      windPower: json['windPower']?.toString().trim() ?? '',
      observedAt: json['observedAt']?.toString().trim() ?? '',
      city: json['city']?.toString().trim() ?? '',
    );
  }
}

class RouteWeatherForecast {
  final String date;
  final String dayWeather;
  final String nightWeather;
  final String dayTemp;
  final String nightTemp;
  final String dayWind;
  final String nightWind;
  final String dayPower;
  final String nightPower;

  const RouteWeatherForecast({
    this.date = '',
    this.dayWeather = '',
    this.nightWeather = '',
    this.dayTemp = '',
    this.nightTemp = '',
    this.dayWind = '',
    this.nightWind = '',
    this.dayPower = '',
    this.nightPower = '',
  });

  static RouteWeatherForecast? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteWeatherForecast(
      date: json['date']?.toString().trim() ?? '',
      dayWeather: json['dayWeather']?.toString().trim() ?? '',
      nightWeather: json['nightWeather']?.toString().trim() ?? '',
      dayTemp: json['dayTemp']?.toString().trim() ?? '',
      nightTemp: json['nightTemp']?.toString().trim() ?? '',
      dayWind: json['dayWind']?.toString().trim() ?? '',
      nightWind: json['nightWind']?.toString().trim() ?? '',
      dayPower: json['dayPower']?.toString().trim() ?? '',
      nightPower: json['nightPower']?.toString().trim() ?? '',
    );
  }
}

class TrafficSummary {
  final int smoothMeters;
  final int slowMeters;
  final int jamMeters;
  final int severeJamMeters;
  final int unknownMeters;

  const TrafficSummary({
    this.smoothMeters = 0,
    this.slowMeters = 0,
    this.jamMeters = 0,
    this.severeJamMeters = 0,
    this.unknownMeters = 0,
  });

  int get totalMeters =>
      smoothMeters + slowMeters + jamMeters + severeJamMeters + unknownMeters;

  factory TrafficSummary.fromJson(Object? raw) {
    if (raw is! Map) return const TrafficSummary();
    final json = Map<String, dynamic>.from(raw);
    return TrafficSummary(
      smoothMeters: (json['smoothMeters'] as num?)?.toInt() ?? 0,
      slowMeters: (json['slowMeters'] as num?)?.toInt() ?? 0,
      jamMeters: (json['jamMeters'] as num?)?.toInt() ?? 0,
      severeJamMeters: (json['severeJamMeters'] as num?)?.toInt() ?? 0,
      unknownMeters: (json['unknownMeters'] as num?)?.toInt() ?? 0,
    );
  }
}

class CongestedSegment {
  final String road;
  final String status;
  final int distanceMeters;

  const CongestedSegment({
    required this.road,
    required this.status,
    required this.distanceMeters,
  });

  factory CongestedSegment.fromJson(Map<String, dynamic> json) =>
      CongestedSegment(
        road: json['road']?.toString().trim() ?? '',
        status: json['status']?.toString().trim() ?? '',
        distanceMeters: (json['distanceMeters'] as num?)?.toInt() ?? 0,
      );
}

class RouteStepInfo {
  final String instruction;
  final String road;
  final int distanceMeters;
  final int durationSeconds;
  final String action;
  final String status;

  const RouteStepInfo({
    required this.instruction,
    this.road = '',
    this.distanceMeters = 0,
    this.durationSeconds = 0,
    this.action = '',
    this.status = '',
  });

  factory RouteStepInfo.fromJson(Map<String, dynamic> json) => RouteStepInfo(
    instruction: json['instruction']?.toString().trim() ?? '',
    road: json['road']?.toString().trim() ?? '',
    distanceMeters: (json['distanceMeters'] as num?)?.toInt() ?? 0,
    durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
    action: json['action']?.toString().trim() ?? '',
    status: json['status']?.toString().trim() ?? '',
  );
}

class DrivingRoutePlan {
  final String strategy;
  final int distanceMeters;
  final int durationSeconds;
  final int trafficLights;
  final int tolls;
  final int tollDistanceMeters;
  final String overallStatus;
  final List<String> roads;
  final TrafficSummary trafficSummary;
  final List<CongestedSegment> congestedSegments;
  final List<RouteStepInfo> steps;

  const DrivingRoutePlan({
    this.strategy = '',
    this.distanceMeters = 0,
    this.durationSeconds = 0,
    this.trafficLights = 0,
    this.tolls = 0,
    this.tollDistanceMeters = 0,
    this.overallStatus = '畅通',
    this.roads = const [],
    this.trafficSummary = const TrafficSummary(),
    this.congestedSegments = const [],
    this.steps = const [],
  });

  factory DrivingRoutePlan.fromJson(Map<String, dynamic> json) {
    final rawRoads = json['roads'] as List? ?? const [];
    final rawCongested = json['congestedSegments'] as List? ?? const [];
    final rawSteps = json['steps'] as List? ?? const [];
    return DrivingRoutePlan(
      strategy: json['strategy']?.toString().trim() ?? '',
      distanceMeters: (json['distanceMeters'] as num?)?.toInt() ??
          (json['distance'] as num?)?.toInt() ??
          0,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ??
          (json['duration'] as num?)?.toInt() ??
          0,
      trafficLights: (json['trafficLights'] as num?)?.toInt() ?? 0,
      tolls: (json['tolls'] as num?)?.round() ?? 0,
      tollDistanceMeters: (json['tollDistanceMeters'] as num?)?.toInt() ?? 0,
      overallStatus: json['overallStatus']?.toString().trim().isNotEmpty == true
          ? json['overallStatus'].toString().trim()
          : '畅通',
      roads: rawRoads
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      trafficSummary: TrafficSummary.fromJson(json['trafficSummary']),
      congestedSegments: rawCongested
          .whereType<Map>()
          .map((e) => CongestedSegment.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      steps: rawSteps
          .whereType<Map>()
          .map((e) => RouteStepInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }
}

class RouteDestinationCandidate {
  final String name;
  final String formattedAddress;
  final String province;
  final String city;
  final String district;
  final String adcode;
  final AmapLocation? location;

  const RouteDestinationCandidate({
    required this.name,
    required this.formattedAddress,
    this.province = '',
    this.city = '',
    this.district = '',
    this.adcode = '',
    this.location,
  });

  String get displayAddress =>
      formattedAddress.trim().isNotEmpty ? formattedAddress.trim() : name.trim();

  factory RouteDestinationCandidate.fromJson(Map<String, dynamic> json) {
    return RouteDestinationCandidate(
      name: (json['name']?.toString() ?? '').trim(),
      formattedAddress: (json['formattedAddress']?.toString() ?? '').trim(),
      province: (json['province']?.toString() ?? '').trim(),
      city: (json['city']?.toString() ?? '').trim(),
      district: (json['district']?.toString() ?? '').trim(),
      adcode: (json['adcode']?.toString() ?? '').trim(),
      location: AmapLocation.fromJson(json['location']),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'formattedAddress': formattedAddress,
    'province': province,
    'city': city,
    'district': district,
    'adcode': adcode,
    if (location != null)
      'location': {
        'lat': location!.lat,
        'lon': location!.lon,
        'coordinate': location!.coordinate,
      },
  };
}
