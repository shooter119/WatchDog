import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../services/camera_bridge.dart';
import '../data/models/route_models.dart';
import '../data/models/route_traffic_info.dart';

export '../data/models/route_models.dart';
export '../data/models/route_traffic_info.dart';

/// 路况查询本机定位降级状态（失败时不阻断终点与天气展示）。
enum RouteTrafficLocationStatus {
  ok,
  permissionDenied,
  serviceDisabled,
  fixFailed,
}

/// 路况查询所需的轻量警情上下文（隔离 `features/incident/`，零跨 Feature 依赖）。
@immutable
class RouteTrafficIncidentContext {
  final String id;
  final String displayName;
  final String location;
  final String administrativeArea;
  final double? officialLat;
  final double? officialLon;

  const RouteTrafficIncidentContext({
    required this.id,
    required this.displayName,
    this.location = '',
    this.administrativeArea = '',
    this.officialLat,
    this.officialLon,
  });
}

/// 路况查询外部依赖网关（便于单元测试与自动化注入）。
class RouteTrafficGateway {
  final Future<bool> Function() requestPermission;
  final Future<bool> Function() locationServiceEnabled;
  final Future<LocationFix?> Function() currentLocation;
  final Future<RouteTrafficInfo> Function({
    required String address,
    String? city,
    double? originLat,
    double? originLon,
    double? destLat,
    double? destLon,
    String? destName,
    String? destAdcode,
  })
  fetchRouteTraffic;
  final Future<Map<String, dynamic>> Function(String incidentId)?
  fetchIncidentDetails;
  final Future<void> Function() openAppSettings;
  final Future<void> Function() openLocationSettings;
  final Future<void> Function(String text) copyText;
  final Future<bool> Function(Uri uri) launchNavigation;

  const RouteTrafficGateway({
    required this.requestPermission,
    required this.locationServiceEnabled,
    required this.currentLocation,
    required this.fetchRouteTraffic,
    this.fetchIncidentDetails,
    required this.openAppSettings,
    required this.openLocationSettings,
    required this.copyText,
    required this.launchNavigation,
  });
}

/// 路况查询状态容器。
class RouteTrafficStore extends ChangeNotifier {
  final RouteTrafficGateway gateway;
  final RouteTrafficIncidentContext? Function() readCurrentIncident;

  RouteTrafficStore({
    required this.gateway,
    required this.readCurrentIncident,
  });

  bool _loading = false;
  String? _error;
  RouteTrafficInfo? _info;
  int _selectedRouteIndex = 0;
  bool _stepsExpanded = false;
  RouteTrafficLocationStatus _locStatus = RouteTrafficLocationStatus.ok;
  String _targetLocation = '';
  String _targetCity = '';
  bool _missingLocation = false;
  int _loadGeneration = 0;
  RouteDestinationCandidate? _selectedCandidate;
  bool _candidateDialogPrompted = false;
  bool _pendingCandidatePrompt = false;
  bool _disposed = false;

  bool get loading => _loading;
  String? get error => _error;
  RouteTrafficInfo? get info => _info;
  int get selectedRouteIndex => _selectedRouteIndex;
  bool get stepsExpanded => _stepsExpanded;
  RouteTrafficLocationStatus get locStatus => _locStatus;
  String get targetLocation => _targetLocation;
  String get targetCity => _targetCity;
  bool get missingLocation => _missingLocation;
  RouteDestinationCandidate? get selectedCandidate => _selectedCandidate;
  bool get hasIncident => readCurrentIncident() != null;
  String get incidentName => readCurrentIncident()?.displayName ?? '';

  DrivingRoutePlan? get selectedRoute {
    final routes = _info?.routes ?? const <DrivingRoutePlan>[];
    if (routes.isEmpty || _selectedRouteIndex >= routes.length) return null;
    return routes[_selectedRouteIndex];
  }

  /// 消费一次性同名地点歧义自动弹窗信号。
  List<RouteDestinationCandidate>? consumePendingCandidatePrompt() {
    if (!_pendingCandidatePrompt) return null;
    _pendingCandidatePrompt = false;
    final candidates = _info?.candidates;
    if (candidates == null || candidates.length <= 1) return null;
    return candidates;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final gen = ++_loadGeneration;
    final incident = readCurrentIncident();
    if (incident == null) {
      _loading = false;
      _error = null;
      _info = null;
      _missingLocation = false;
      _notify();
      return;
    }

    _loading = true;
    _error = null;
    _missingLocation = false;
    _notify();

    var location = incident.location.trim();
    var city = incident.administrativeArea.trim();
    var officialLat = incident.officialLat;
    var officialLon = incident.officialLon;

    if ((location.isEmpty ||
            city.isEmpty ||
            officialLat == null ||
            officialLon == null) &&
        gateway.fetchIncidentDetails != null) {
      try {
        final details = await gateway.fetchIncidentDetails!(incident.id);
        if (details['data'] is Map) {
          final data = Map<String, dynamic>.from(details['data'] as Map);
          if (location.isEmpty) {
            location = (data['location']?.toString() ?? '').trim();
          }
          if (city.isEmpty) {
            city = (data['administrative_area']?.toString() ?? '').trim();
          }
          officialLat ??= double.tryParse(data['latitude']?.toString() ?? '');
          officialLon ??= double.tryParse(data['longitude']?.toString() ?? '');
        }
      } catch (_) {}
    }

    if (_disposed || gen != _loadGeneration) return;

    if (location.isEmpty) {
      _loading = false;
      _missingLocation = true;
      _targetLocation = '';
      _targetCity = '';
      _notify();
      return;
    }

    _targetLocation = location;
    _targetCity = city;

    var locStatus = RouteTrafficLocationStatus.ok;
    LocationFix? fix;
    try {
      final permitted = await gateway.requestPermission();
      if (!permitted) {
        locStatus = RouteTrafficLocationStatus.permissionDenied;
      } else {
        final enabled = await gateway.locationServiceEnabled();
        if (!enabled) {
          locStatus = RouteTrafficLocationStatus.serviceDisabled;
        } else {
          fix = await gateway.currentLocation();
          if (fix == null) {
            locStatus = RouteTrafficLocationStatus.fixFailed;
          }
        }
      }
    } catch (_) {
      locStatus = RouteTrafficLocationStatus.fixFailed;
    }

    if (_disposed || gen != _loadGeneration) return;
    _locStatus = locStatus;

    try {
      final fetched = await gateway.fetchRouteTraffic(
        address: _targetLocation,
        city: _targetCity.isNotEmpty ? _targetCity : null,
        originLat: fix?.lat,
        originLon: fix?.lon,
        destLat: _selectedCandidate?.location?.lat ?? officialLat,
        destLon: _selectedCandidate?.location?.lon ?? officialLon,
        destName: _selectedCandidate?.name,
        destAdcode: _selectedCandidate?.adcode,
      );

      if (_disposed || gen != _loadGeneration) return;
      _loading = false;
      _info = fetched;
      _selectedRouteIndex = 0;
      _stepsExpanded = false;
      _error = null;
      if (fetched.ambiguous &&
          fetched.candidates.length > 1 &&
          !_candidateDialogPrompted &&
          _selectedCandidate == null) {
        _candidateDialogPrompted = true;
        _pendingCandidatePrompt = true;
      }
      _notify();
    } catch (e) {
      if (_disposed || gen != _loadGeneration) return;
      final rawMsg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      _loading = false;
      _error = rawMsg.contains('404')
          ? '路况查询服务未就绪或正在升级（HTTP 404），请稍后重试'
          : rawMsg;
      _notify();
    }
  }

  void selectRouteIndex(int index) {
    final routes = _info?.routes ?? const <DrivingRoutePlan>[];
    if (index < 0 || index >= routes.length || index == _selectedRouteIndex) {
      return;
    }
    _selectedRouteIndex = index;
    _stepsExpanded = false;
    _notify();
  }

  void toggleStepsExpanded() {
    _stepsExpanded = !_stepsExpanded;
    _notify();
  }

  Future<void> selectCandidate(RouteDestinationCandidate candidate) async {
    _selectedCandidate = candidate;
    _notify();
    await load();
  }

  Future<String?> copySummary() async {
    final currentInfo = _info;
    if (currentInfo == null) return null;
    final text = currentInfo.toSummaryText(
      incidentName: incidentName,
      routeIndex: _selectedRouteIndex,
    );
    await gateway.copyText(text);
    return '路况简报已复制';
  }

  Future<String?> startNavigation() async {
    final webUri = _info?.navigationUri;
    final nativeUri = _info?.nativeAndroidNavigationUri;
    if (webUri == null) return '未获取到事发地点坐标，无法导航';

    var ok = false;
    if (defaultTargetPlatform == TargetPlatform.android && nativeUri != null) {
      try {
        ok = await gateway.launchNavigation(nativeUri);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      try {
        ok = await gateway.launchNavigation(webUri);
      } catch (_) {
        ok = false;
      }
    }
    return ok ? null : '无法打开外部地图导航应用';
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    super.dispose();
  }
}
