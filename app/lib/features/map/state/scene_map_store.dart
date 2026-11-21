import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../services/camera_bridge.dart';
import '../../../services/china_coord.dart';
import '../data/models/route_traffic_info.dart';
import '../data/models/scene_map_bootstrap.dart';
import '../ui/scene_map_html_builder.dart';
import '../ui/scene_map_surface.dart';
import 'scene_map_gateway.dart';

export '../ui/scene_map_html_builder.dart'
    show SceneMapLayerMode, buildSceneMapHtml, sceneMapSafeJsonEncode;
export '../ui/scene_map_surface.dart' show SceneMapSurfaceController;
export 'scene_map_gateway.dart';

/// 现场卫星地图状态容器。
class SceneMapStore extends ChangeNotifier {
  final SceneMapGateway gateway;
  final SceneMapSurfaceController surfaceController;

  SceneMapStore({
    required this.gateway,
    SceneMapSurfaceController? surfaceController,
  }) : surfaceController = surfaceController ?? SceneMapSurfaceController();

  SceneMapLayerMode _layerMode = SceneMapLayerMode.hybrid;
  bool _trafficEnabled = false;
  bool _followMe = true;
  bool _loadingBootstrap = true;
  String? _bootstrapError;
  String? _scriptError;
  SceneMapBootstrap? _bootstrap;

  SceneMapLocStatus _locStatus = SceneMapLocStatus.unknown;
  LocationFix? _myWgsFix;
  ({double lat, double lon})? _myGcj;
  String? _myAddress;
  DateTime? _lastRegeoAt;
  double? _lastRegeoLat;
  double? _lastRegeoLon;
  bool _regeoInFlight = false;

  RouteTrafficInfo? _incidentInfo;
  String? _incidentDisplayLocation;
  ({double lat, double lon})? _incidentGcj;

  StreamSubscription<LocationFix>? _watchSub;
  int _generation = 0;
  bool _surfaceReady = false;
  bool _htmlLoaded = false;
  bool _disposed = false;

  SceneMapLayerMode get layerMode => _layerMode;
  bool get trafficEnabled => _trafficEnabled;
  bool get followMe => _followMe;
  bool get loadingBootstrap => _loadingBootstrap;
  String? get bootstrapError => _bootstrapError;
  String? get scriptError => _scriptError;
  SceneMapBootstrap? get bootstrap => _bootstrap;
  SceneMapLocStatus get locStatus => _locStatus;
  LocationFix? get myWgsFix => _myWgsFix;
  ({double lat, double lon})? get myGcj => _myGcj;
  String? get myAddress => _myAddress;
  RouteTrafficInfo? get incidentInfo => _incidentInfo;
  String? get incidentDisplayLocation => _incidentDisplayLocation;
  ({double lat, double lon})? get incidentGcj => _incidentGcj;
  String get incidentName => gateway.readCurrentIncident()?.displayName ?? '';

  bool get canRenderMapSurface =>
      !_loadingBootstrap &&
      _bootstrapError == null &&
      _bootstrap != null &&
      (_bootstrap!.configured || _bootstrap!.code == 'AMAP_JS_NOT_CONFIGURED');

  double? get distanceToIncidentMeters {
    final me = _myGcj;
    final dest = _incidentGcj;
    if (me == null || dest == null) return null;
    return ChinaCoord.distanceMeters(me.lat, me.lon, dest.lat, dest.lon);
  }

  double? get bearingToIncidentDegrees {
    final me = _myGcj;
    final dest = _incidentGcj;
    if (me == null || dest == null) return null;
    return ChinaCoord.bearingDegrees(me.lat, me.lon, dest.lat, dest.lon);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _eval(String js) => unawaited(surfaceController.evalJs(js));

  Future<void> initialize() async {
    final gen = ++_generation;
    await _stopWatching();
    if (_disposed) return;
    _loadingBootstrap = true;
    _bootstrapError = null;
    _scriptError = null;
    _htmlLoaded = false;
    _notify();
    await Future.wait([
      _loadBootstrap(gen),
      _initLocation(gen),
      _loadIncidentPoint(gen),
    ]);
  }

  void pauseWatching() => unawaited(_stopWatching());

  void resumeWatching() {
    if (_locStatus == SceneMapLocStatus.ok ||
        _locStatus == SceneMapLocStatus.fixFailed) {
      unawaited(_startWatching());
    }
  }

  Future<void> _stopWatching() async {
    final sub = _watchSub;
    _watchSub = null;
    if (sub != null) await sub.cancel();
  }

  Future<void> _loadBootstrap(int gen) async {
    if (!gateway.isAuthenticated()) {
      if (_disposed || gen != _generation) return;
      _loadingBootstrap = false;
      _bootstrap = null;
      _bootstrapError = '请先完成单位认证后加载高德在线卫星图';
      _notify();
      return;
    }
    try {
      final boot = await gateway.fetchMapBootstrap();
      if (_disposed || gen != _generation) return;
      _loadingBootstrap = false;
      _bootstrap = boot;
      _bootstrapError =
          (boot.configured || boot.code == 'AMAP_JS_NOT_CONFIGURED')
          ? null
          : (boot.message ?? '现场地图服务暂不可用');
      _notify();
      tryLoadHtmlIntoSurface();
    } catch (e) {
      if (_disposed || gen != _generation) return;
      _loadingBootstrap = false;
      _bootstrapError = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      _notify();
    }
  }

  Future<void> retryLocation() => _initLocation(_generation);

  Future<void> _initLocation(int gen) async {
    try {
      final permitted = await gateway.requestPermission();
      if (_disposed || gen != _generation) return;
      if (!permitted) {
        _locStatus = SceneMapLocStatus.permissionDenied;
        _notify();
        return;
      }
      final enabled = await gateway.locationServiceEnabled();
      if (_disposed || gen != _generation) return;
      if (!enabled) {
        _locStatus = SceneMapLocStatus.serviceDisabled;
        _notify();
        return;
      }
      final quickFix = await gateway.currentLocation();
      if (_disposed || gen != _generation) return;
      if (quickFix != null) {
        _applyLocationFix(quickFix);
      } else {
        _locStatus = SceneMapLocStatus.fixFailed;
        _notify();
      }
      await _startWatching(gen);
    } catch (_) {
      if (_disposed || gen != _generation) return;
      _locStatus = SceneMapLocStatus.fixFailed;
      _notify();
    }
  }

  Future<void> _startWatching([int? expectedGen]) async {
    final gen = expectedGen ?? _generation;
    await _stopWatching();
    if (_disposed || gen != _generation) return;
    _watchSub = gateway.watchLocation().listen((fix) {
      if (_disposed || gen != _generation) return;
      _applyLocationFix(fix);
    }, onError: (_) {});
  }

  void _applyLocationFix(LocationFix fix) {
    final gcj = ChinaCoord.wgs84ToGcj02(fix.lat, fix.lon);
    _locStatus = SceneMapLocStatus.ok;
    _myWgsFix = fix;
    _myGcj = gcj;
    _notify();
    if (_htmlLoaded) _eval(SceneMapJsCommands.updateMyLocation(gcj, fix, _followMe));
    _maybeRefreshAddress(fix);
  }

  void _maybeRefreshAddress(LocationFix fix) {
    if (!gateway.isAuthenticated() || _regeoInFlight) return;
    final now = gateway.now();
    final shouldFetch =
        _lastRegeoAt == null ||
        (now.difference(_lastRegeoAt!) >= const Duration(seconds: 15) &&
            _lastRegeoLat != null &&
            _lastRegeoLon != null &&
            ChinaCoord.distanceMeters(
                  _lastRegeoLat!,
                  _lastRegeoLon!,
                  fix.lat,
                  fix.lon,
                ) >=
                80.0);
    if (!shouldFetch) return;

    _regeoInFlight = true;
    _lastRegeoAt = now;
    _lastRegeoLat = fix.lat;
    _lastRegeoLon = fix.lon;
    final gen = _generation;

    unawaited(
      gateway
          .fetchAddress(fix.lat, fix.lon)
          .then((result) {
            if (_disposed || gen != _generation) return;
            final addr = (result.address ?? '').trim();
            if (addr.isNotEmpty) {
              _myAddress = addr;
              _notify();
            }
          })
          .catchError((_) {})
          .whenComplete(() => _regeoInFlight = false),
    );
  }

  Future<void> _loadIncidentPoint(int gen) async {
    final incident = gateway.readCurrentIncident();
    if (incident == null) {
      if (_disposed || gen != _generation) return;
      _incidentInfo = null;
      _incidentDisplayLocation = null;
      _incidentGcj = null;
      _notify();
      return;
    }

    var location = incident.effectiveLocation.trim();
    var city = incident.administrativeArea.trim();
    var officialLat = incident.officialLat;
    var officialLon = incident.officialLon;

    if ((location.isEmpty ||
            city.isEmpty ||
            officialLat == null ||
            officialLon == null) &&
        gateway.fetchIncidentDetails != null &&
        gateway.isAuthenticated()) {
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

    if (_disposed || gen != _generation) return;
    if (location.isEmpty && (officialLat == null || officialLon == null)) return;

    if (officialLat != null && officialLon != null) {
      _incidentDisplayLocation = location.isNotEmpty
          ? location
          : incident.displayName;
      _incidentGcj = (lat: officialLat, lon: officialLon);
      _notify();
      _pushIncidentToMap();
    }

    if (!gateway.isAuthenticated() || location.isEmpty) return;
    try {
      final info = await gateway.fetchIncidentRouteInfo(
        address: location,
        city: city.isNotEmpty ? city : null,
        destLat: officialLat,
        destLon: officialLon,
      );
      if (_disposed || gen != _generation) return;
      final loc = info.destination?.location;
      _incidentInfo = info;
      _incidentDisplayLocation =
          info.destination?.displayAddress.isNotEmpty == true
          ? info.destination!.displayAddress
          : (location.isNotEmpty ? location : incident.displayName);
      _incidentGcj = (loc != null && loc.lat.isFinite && loc.lon.isFinite)
          ? (lat: loc.lat, lon: loc.lon)
          : _incidentGcj;
      _notify();
      _pushIncidentToMap();
    } catch (_) {}
  }

  String _incidentPinTitle() {
    final raw = (_incidentDisplayLocation ?? '').trim();
    if (raw.isEmpty) return '事发地点';
    final shortened = ChinaCoord.shortenPinLabel(raw);
    return shortened.isNotEmpty ? shortened : raw;
  }

  void _pushIncidentToMap() {
    final gcj = _incidentGcj;
    if (!_htmlLoaded || gcj == null) return;
    _eval(SceneMapJsCommands.updateIncident(gcj, _incidentPinTitle()));
  }

  void markSurfaceReady() {
    _surfaceReady = true;
    tryLoadHtmlIntoSurface();
  }

  void tryLoadHtmlIntoSurface() {
    final boot = _bootstrap;
    if (!_surfaceReady ||
        boot == null ||
        (!boot.configured && boot.code != 'AMAP_JS_NOT_CONFIGURED') ||
        _htmlLoaded) {
      return;
    }
    final apiBase = gateway.readBaseUrl();
    final myGcj = _myGcj;
    final fix = _myWgsFix;
    final html = buildSceneMapHtml(
      jsKey: boot.jsKey,
      serviceHost: boot.resolveServiceHost(apiBase),
      initialLayer: _layerMode,
      initialTrafficEnabled: _trafficEnabled,
      initialMyGcj: myGcj == null
          ? null
          : (
              lat: myGcj.lat,
              lon: myGcj.lon,
              accuracy: (fix != null && fix.accuracyMeters > 0)
                  ? fix.accuracyMeters
                  : 0.0,
              bearing: fix?.bearingDegrees,
            ),
      initialIncidentGcj: _incidentGcj == null
          ? null
          : (
              lat: _incidentGcj!.lat,
              lon: _incidentGcj!.lon,
              title: _incidentPinTitle(),
            ),
    );
    _htmlLoaded = true;
    final baseUrl = apiBase.trim().isNotEmpty
        ? apiBase.trim()
        : 'https://fireman119.xyz';
    unawaited(surfaceController.loadHtml(baseUrl, html));
  }

  void setLayerMode(SceneMapLayerMode mode) {
    if (_layerMode == mode) return;
    _layerMode = mode;
    _notify();
    if (_htmlLoaded) _eval(SceneMapJsCommands.setLayerMode(mode));
  }

  void toggleTraffic() {
    _trafficEnabled = !_trafficEnabled;
    _notify();
    if (_htmlLoaded) _eval(SceneMapJsCommands.setTrafficEnabled(_trafficEnabled));
  }

  void focusMyLocation() {
    if (_locStatus == SceneMapLocStatus.permissionDenied ||
        _locStatus == SceneMapLocStatus.serviceDisabled ||
        _myGcj == null) {
      unawaited(_initLocation(_generation));
      return;
    }
    _followMe = true;
    _notify();
    if (_htmlLoaded) _eval(SceneMapJsCommands.focusMyLocation);
  }

  void focusIncident() {
    if (_incidentGcj == null) return;
    _followMe = false;
    _notify();
    if (_htmlLoaded) _eval(SceneMapJsCommands.focusIncident);
  }

  void fitBoth() {
    _followMe = false;
    _notify();
    if (_htmlLoaded) _eval(SceneMapJsCommands.fitBoth);
  }

  void handleBridgeEvent(String type, Map<String, dynamic> data) {
    if (_disposed) return;
    if (type == 'userDragged' || type == 'focusIncidentFromGuide') {
      if (_followMe) {
        _followMe = false;
        _notify();
      }
    } else if (type == 'scriptError' || type == 'loadError') {
      final msg = data['message']?.toString().trim();
      _scriptError = (msg != null && msg.isNotEmpty)
          ? msg
          : '地图底图加载失败，请检查网络后重试';
      _notify();
    } else if (type == 'mapReady') {
      if (_scriptError != null) {
        _scriptError = null;
        _notify();
      }
      _syncAllStateToMap();
    }
  }

  void _syncAllStateToMap() {
    if (!_htmlLoaded) return;
    _eval(SceneMapJsCommands.setLayerMode(_layerMode));
    _eval(SceneMapJsCommands.setTrafficEnabled(_trafficEnabled));
    final fix = _myWgsFix;
    final myGcj = _myGcj;
    if (fix != null && myGcj != null) {
      _eval(SceneMapJsCommands.updateMyLocation(myGcj, fix, _followMe));
    }
    _pushIncidentToMap();
  }

  Future<String?> startNavigation() async {
    final destName =
        (_incidentDisplayLocation ??
                _incidentInfo?.destination?.displayAddress ??
                '')
            .trim();
    final uris = resolveSceneMapNavigationUris(
      info: _incidentInfo,
      coord: _incidentGcj,
      destName: destName,
    );
    if (uris.webUri == null) return '未获取到事发地点坐标，无法导航';

    var ok = false;
    if (defaultTargetPlatform == TargetPlatform.android &&
        uris.nativeUri != null) {
      try {
        ok = await gateway.launchNavigation(uris.nativeUri!);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      try {
        ok = await gateway.launchNavigation(uris.webUri!);
      } catch (_) {
        ok = false;
      }
    }
    return ok ? null : '无法打开外部地图导航应用';
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_stopWatching());
    surfaceController.detach();
    super.dispose();
  }
}
