import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../models/water_source.dart';
import '../services/camera_bridge.dart';
import '../services/china_coord.dart';
import '../services/screen_on.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 地图交互桥接控制器（支持真实 WebView 与测试注入）。
class WaterSourcesMapSurfaceController {
  String? lastLoadedHtml;
  String? lastBaseUrl;
  final List<String> evaluatedScripts = [];
  Future<void> Function(String baseUrl, String html)? _onLoadHtml;
  Future<void> Function(String script)? _onEvalJs;

  void attach({
    required Future<void> Function(String baseUrl, String html) onLoadHtml,
    required Future<void> Function(String script) onEvalJs,
  }) {
    _onLoadHtml = onLoadHtml;
    _onEvalJs = onEvalJs;
  }

  void detach() {
    _onLoadHtml = null;
    _onEvalJs = null;
  }

  Future<void> loadHtml(String baseUrl, String html) async {
    lastBaseUrl = baseUrl;
    lastLoadedHtml = html;
    final fn = _onLoadHtml;
    if (fn != null) {
      await fn(baseUrl, html);
    }
  }

  Future<void> evalJs(String script) async {
    evaluatedScripts.add(script);
    final fn = _onEvalJs;
    if (fn != null) {
      await fn(script);
    }
  }
}

/// 传给可选 `mapBuilder` 的只读地图状态快照与回调。
class WaterSourcesMapState {
  final WaterSourcesMapSurfaceController surfaceController;
  final List<WaterSource> items;
  final WaterSource? selected;
  final ({double lat, double lng, double accuracy})? myGcj;
  final bool pickingMode;
  final ({double lat, double lng})? pickCenter;
  final void Function(String eventType, Map<String, dynamic> data)
  onBridgeEvent;
  final void Function(String id) onSelectMarker;
  final void Function(double lat, double lng) onPickCenterChanged;

  const WaterSourcesMapState({
    required this.surfaceController,
    required this.items,
    required this.selected,
    required this.myGcj,
    required this.pickingMode,
    required this.pickCenter,
    required this.onBridgeEvent,
    required this.onSelectMarker,
    required this.onPickCenterChanged,
  });
}

/// 可选自定义地图视图构建器，便于单测在无真实 WebView 环境下注入占位组件。
typedef WaterSourcesMapBuilder =
    Widget Function(BuildContext context, WaterSourcesMapState mapState);

/// 可选外部依赖网关，便于单测隔离原生定位与网络请求。
class WaterSourcesGateway {
  final Future<bool> Function()? requestLocationPermission;
  final Future<bool> Function()? isLocationServiceEnabled;
  final Future<LocationFix?> Function()? currentLocation;
  final Future<void> Function()? openAppSettings;
  final Future<void> Function()? openLocationSettings;
  final Future<SceneMapBootstrap> Function()? fetchMapBootstrap;
  final Future<WaterSourceListResult> Function()? fetchWaterSources;
  final Future<WaterSource> Function({
    required WaterSourceCategory category,
    required String name,
    required double lat,
    required double lng,
    WaterSourceStatus status,
    List<WaterIntakeMethod> intakeMethods,
    String note,
  })?
  createWaterSource;
  final Future<WaterSource> Function(
    String id, {
    WaterSourceCategory? category,
    String? name,
    double? lat,
    double? lng,
    WaterSourceStatus? status,
    List<WaterIntakeMethod>? intakeMethods,
    String? note,
  })?
  updateWaterSource;
  final Future<int> Function(String id)? deleteWaterSource;
  final Future<WaterSource> Function(String id)? restoreWaterSource;

  const WaterSourcesGateway({
    this.requestLocationPermission,
    this.isLocationServiceEnabled,
    this.currentLocation,
    this.openAppSettings,
    this.openLocationSettings,
    this.fetchMapBootstrap,
    this.fetchWaterSources,
    this.createWaterSource,
    this.updateWaterSource,
    this.deleteWaterSource,
    this.restoreWaterSource,
  });
}

enum _WaterLocStatus {
  loading,
  ok,
  permissionDenied,
  serviceDisabled,
  fixFailed,
}

String _safeJsonEncode(Object? value) =>
    jsonEncode(value).replaceAll('</', '<\\/');

/// 构建「周边水源」高德 JS API 2.0 地图 HTML。
///
/// - 固定加载卫星+路网底图；
/// - 使用 `AMap.LabelsLayer` + `AMap.LabelMarker` 渲染 3 类图标 + 2 态配色 + 备注角标，图标右侧默认展示点位名称；
/// - 监听代理 401 响应通知端侧自动续签票据并重建底图；
/// - 不调用高德逆地理，不提供外部导航唤起。
@visibleForTesting
String buildWaterSourcesMapHtml({
  required String jsKey,
  String? serviceHost,
  ({double lat, double lng, double accuracy})? initialMyGcj,
  ({double lat, double lng})? initialCenter,
  double? initialZoom,
  List<WaterSource> initialItems = const [],
  String? selectedId,
}) {
  final trimmedKey = jsKey.trim();
  final encodedKey = Uri.encodeQueryComponent(trimmedKey);
  final trimmedHost = serviceHost?.trim() ?? '';
  final securityBlock = trimmedHost.isNotEmpty
      ? '''
<script>
window._AMapSecurityConfig = {
  serviceHost: ${_safeJsonEncode(trimmedHost)}
};
</script>'''
      : '';

  final centerLng =
      initialCenter?.lng ??
      initialMyGcj?.lng ??
      (initialItems.isNotEmpty ? initialItems.first.lng : 116.397428);
  final centerLat =
      initialCenter?.lat ??
      initialMyGcj?.lat ??
      (initialItems.isNotEmpty ? initialItems.first.lat : 39.90923);
  final zoom =
      initialZoom ??
      ((initialCenter != null ||
              initialMyGcj != null ||
              initialItems.isNotEmpty)
          ? 16.0
          : 5.0);

  final myJson = initialMyGcj == null
      ? 'null'
      : _safeJsonEncode({
          'lat': initialMyGcj.lat,
          'lng': initialMyGcj.lng,
          'accuracy': initialMyGcj.accuracy,
        });

  final itemsJson = _safeJsonEncode(
    initialItems.map(_waterSourceToJsPayload).toList(growable: false),
  );

  return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body, #map-container {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #0F172A;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
    }
    .wd-my-dot {
      width: 16px;
      height: 16px;
      border-radius: 50%;
      background: #2563EB;
      border: 3px solid #FFFFFF;
      box-shadow: 0 1px 6px rgba(0, 0, 0, 0.45);
    }
  </style>
</head>
<body>
  <div id="map-container"></div>
  $securityBlock
  <script>
    function notifyBridge(type, data) {
      try {
        if (window.WatchdogMapBridge && window.WatchdogMapBridge.postMessage) {
          window.WatchdogMapBridge.postMessage(JSON.stringify({ type: type, data: data || {} }));
        }
      } catch (_) {}
    }

    (function installTicketWatcher() {
      var proxyHost = ${_safeJsonEncode(trimmedHost)};
      if (!proxyHost) return;
      var notified = false;
      function triggerExpired(url) {
        if (notified) return;
        if (typeof url === 'string' && url.indexOf(proxyHost) !== -1) {
          notified = true;
          notifyBridge('ticketExpired', { status: 401 });
        }
      }
      if (typeof window.fetch === 'function') {
        var origFetch = window.fetch;
        window.fetch = function(input, init) {
          var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
          return origFetch.apply(this, arguments).then(function(resp) {
            if (resp && resp.status === 401) triggerExpired(url);
            return resp;
          });
        };
      }
      if (typeof XMLHttpRequest !== 'undefined') {
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
          this._wdUrl = typeof url === 'string' ? url : '';
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
          var xhr = this;
          xhr.addEventListener('load', function() {
            if (xhr.status === 401) triggerExpired(xhr._wdUrl || '');
          });
          return origSend.apply(this, arguments);
        };
      }
    })();

    window.onAmapScriptError = function() {
      notifyBridge('scriptError', { message: '高德地图脚本加载失败，请检查网络连接' });
    };
  </script>
  <script
    src="https://webapi.amap.com/maps?v=2.0&key=$encodedKey"
    onerror="window.onAmapScriptError()"
  ></script>
  <script>
    (function() {
      if (typeof AMap === 'undefined') {
        notifyBridge('scriptError', { message: '高德地图引擎未就绪，请检查网络后重试' });
        return;
      }

      var state = {
        my: $myJson,
        items: $itemsJson,
        selectedId: ${_safeJsonEncode(selectedId)},
        pickingMode: false,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };

      var map = new AMap.Map('map-container', {
        zoom: ${zoom.toStringAsFixed(1)},
        center: [${centerLng.toStringAsFixed(6)}, ${centerLat.toStringAsFixed(6)}],
        viewMode: '2D',
        rotateEnable: false,
        pitchEnable: false,
        resizeEnable: true
      });

      var satelliteLayer = new AMap.TileLayer.Satellite({ zIndex: 1 });
      var roadNetLayer = new AMap.TileLayer.RoadNet({ zIndex: 2 });
      map.setLayers([satelliteLayer, roadNetLayer]);

      var labelsLayer = new AMap.LabelsLayer({
        zooms: [3, 20],
        zIndex: 120,
        collision: true,
        allowCollision: false
      });
      map.add(labelsLayer);

      var iconCache = {};
      function buildMarkerIcon(category, available, hasNote, selected) {
        var key = category + ':' + (available ? '1' : '0') + ':' + (hasNote ? '1' : '0') + ':' + (selected ? '1' : '0');
        if (iconCache[key]) return iconCache[key];

        var fill = '#2563EB';
        var stroke = '#FFFFFF';
        if (!available) {
          fill = '#6B7280';
          stroke = '#DC2626';
        } else if (category === 'natural') {
          fill = '#0D9488';
        } else if (category === 'pump_connector') {
          fill = '#D97706';
        }

        var glyph = '';
        if (category === 'natural') {
          glyph = '<path d="M18 9 C18 9 12 16 12 20.5 C12 23.8 14.7 26.5 18 26.5 C21.3 26.5 24 23.8 24 20.5 C24 16 18 9 18 9 Z" fill="#FFFFFF"/>';
        } else if (category === 'pump_connector') {
          glyph = '<path d="M11 16 H25 V20 H11 Z M15 11 H21 V25 H15 Z" fill="#FFFFFF"/>';
        } else {
          glyph = '<rect x="14.5" y="11" width="7" height="14" rx="2" fill="#FFFFFF"/><rect x="11.5" y="15" width="13" height="3.2" rx="1" fill="#FFFFFF"/><circle cx="18" cy="10" r="2.2" fill="#FFFFFF"/>';
        }

        var slash = available ? '' : '<line x1="9" y1="9" x2="27" y2="27" stroke="#DC2626" stroke-width="3" stroke-linecap="round"/>';
        var ring = selected ? '<circle cx="18" cy="18" r="16.5" fill="none" stroke="#FACC15" stroke-width="3"/>' : '';
        var noteBadge = hasNote ? '<circle cx="29" cy="7" r="4.5" fill="#F59E0B" stroke="#FFFFFF" stroke-width="1.6"/>' : '';

        var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36">' +
          ring +
          '<circle cx="18" cy="18" r="13.5" fill="' + fill + '" stroke="' + stroke + '" stroke-width="2.4"/>' +
          glyph +
          slash +
          noteBadge +
          '</svg>';
        var uri = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
        iconCache[key] = uri;
        return uri;
      }

      function shortLabel(name) {
        var s = String(name || '').trim();
        if (s.length <= 12) return s;
        return s.slice(0, 11) + '…';
      }

      function renderItems() {
        labelsLayer.clear();
        var markers = [];
        for (var i = 0; i < state.items.length; i++) {
          var item = state.items[i];
          if (typeof item.lng !== 'number' || typeof item.lat !== 'number') continue;
          var isSel = state.selectedId && item.id === state.selectedId;
          var available = item.status !== 'unavailable';
          var size = isSel ? [36, 36] : [30, 30];
          var marker = new AMap.LabelMarker({
            name: item.id,
            position: [item.lng, item.lat],
            zIndex: isSel ? 200 : (available ? 120 : 100),
            rank: isSel ? 10 : (available ? 5 : 1),
            icon: {
              type: 'image',
              image: buildMarkerIcon(item.category, available, !!item.hasNote, isSel),
              size: size,
              anchor: 'center'
            },
            text: {
              content: shortLabel(item.name),
              direction: 'right',
              offset: [4, 0],
              style: {
                fontSize: isSel ? 13 : 12,
                fontWeight: 'bold',
                fillColor: available ? '#FFFFFF' : '#FCA5A5',
                strokeColor: '#0F172A',
                strokeWidth: 3.5
              }
            }
          });
          (function(id) {
            marker.on('click', function() {
              notifyBridge('markerClick', { id: id });
            });
          })(item.id);
          markers.push(marker);
        }
        if (markers.length > 0) {
          labelsLayer.add(markers);
        }
      }

      var myMarker = null;
      var accuracyCircle = null;
      function renderMyLocation() {
        if (!state.my) return;
        var pos = [state.my.lng, state.my.lat];
        if (!myMarker) {
          var el = document.createElement('div');
          el.className = 'wd-my-dot';
          myMarker = new AMap.Marker({
            position: pos,
            content: el,
            offset: new AMap.Pixel(-11, -11),
            zIndex: 250
          });
          map.add(myMarker);
        } else {
          myMarker.setPosition(pos);
        }
        var acc = typeof state.my.accuracy === 'number' && state.my.accuracy > 0 ? state.my.accuracy : 0;
        if (acc > 0) {
          if (!accuracyCircle) {
            accuracyCircle = new AMap.Circle({
              center: pos,
              radius: Math.min(acc, 500),
              fillColor: '#2563EB',
              fillOpacity: 0.14,
              strokeColor: '#3B82F6',
              strokeOpacity: 0.45,
              strokeWeight: 1.5,
              zIndex: 90
            });
            map.add(accuracyCircle);
          } else {
            accuracyCircle.setCenter(pos);
            accuracyCircle.setRadius(Math.min(acc, 500));
          }
        }
      }

      function emitCenter() {
        var c = map.getCenter();
        if (!c) return;
        notifyBridge('centerChanged', { lat: c.getLat(), lng: c.getLng(), zoom: map.getZoom() });
      }

      map.on('moveend', function() {
        emitCenter();
      });
      map.on('mapmove', function() {
        if (state.pickingMode) emitCenter();
      });

      renderMyLocation();
      renderItems();

      window.watchdogWaterMap = {
        setItems: function(items, selectedId) {
          state.items = Array.isArray(items) ? items : [];
          state.selectedId = selectedId || null;
          renderItems();
        },
        setMyLocation: function(my, autoCenter) {
          state.my = my || null;
          renderMyLocation();
          if (autoCenter && state.my && !state.hasCenteredMy) {
            state.hasCenteredMy = true;
            map.setZoomAndCenter(16, [state.my.lng, state.my.lat]);
          }
        },
        focusItem: function(id, lng, lat) {
          state.selectedId = id || null;
          renderItems();
          if (typeof lng === 'number' && typeof lat === 'number') {
            map.setZoomAndCenter(Math.max(map.getZoom() || 16, 17), [lng, lat]);
          }
        },
        centerOn: function(lng, lat, zoom) {
          if (typeof lng === 'number' && typeof lat === 'number') {
            map.setZoomAndCenter(zoom || 17, [lng, lat]);
          }
        },
        setPickingMode: function(enabled) {
          state.pickingMode = !!enabled;
          if (state.pickingMode) emitCenter();
        }
      };

      notifyBridge('mapReady', {});
    })();
  </script>
</body>
</html>''';
}

Map<String, dynamic> _waterSourceToJsPayload(WaterSource item) => {
  'id': item.id,
  'category': item.category.apiValue,
  'name': item.name,
  'lat': item.lat,
  'lng': item.lng,
  'status': item.status.apiValue,
  'hasNote': item.hasNote,
};

/// 大队级自建水源库「周边水源」独立查询与维护页面。
class WaterSourcesPage extends StatefulWidget {
  final AppController controller;
  final WaterSourcesGateway? gateway;
  final WaterSourcesMapBuilder? mapBuilder;

  const WaterSourcesPage({
    super.key,
    required this.controller,
    this.gateway,
    this.mapBuilder,
  });

  @override
  State<WaterSourcesPage> createState() => _WaterSourcesPageState();
}

class _WaterSourcesPageState extends State<WaterSourcesPage> {
  final WaterSourcesMapSurfaceController _surfaceController =
      WaterSourcesMapSurfaceController();
  final TextEditingController _searchController = TextEditingController();

  bool _loadingList = true;
  String? _listError;
  List<WaterSource> _items = const [];

  bool _loadingBootstrap = true;
  String? _bootstrapError;
  String? _scriptError;
  SceneMapBootstrap? _bootstrap;
  Timer? _ticketRenewTimer;
  int _ticketRenewAttempts = 0;

  _WaterLocStatus _locStatus = _WaterLocStatus.loading;
  ({double lat, double lng, double accuracy})? _myGcj;

  WaterSourceCategory? _categoryFilter;
  bool _onlyAvailable = false;
  String _searchQuery = '';
  String? _selectedId;

  bool _pickingMode = false;
  WaterSource? _editingCoordTarget;
  ({double lat, double lng})? _pickCenter;
  ({double lat, double lng})? _lastMapCenter;
  double? _lastMapZoom;

  bool _surfaceReady = false;
  bool _htmlLoaded = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _generation++;
    _ticketRenewTimer?.cancel();
    _searchController.dispose();
    _surfaceController.detach();
    super.dispose();
  }

  ApiClient? get _api => widget.controller.api;

  Future<bool> _requestLocationPermission() {
    final fn = widget.gateway?.requestLocationPermission;
    if (fn != null) return fn();
    return CameraBridge.requestLocationPermission();
  }

  Future<bool> _isLocationServiceEnabled() {
    final fn = widget.gateway?.isLocationServiceEnabled;
    if (fn != null) return fn();
    return CameraBridge.isLocationServiceEnabled();
  }

  Future<LocationFix?> _fetchCurrentLocation() {
    final fn = widget.gateway?.currentLocation;
    if (fn != null) return fn();
    return CameraBridge.currentLocation(timeout: const Duration(seconds: 8));
  }

  Future<void> _openAppSettings() {
    final fn = widget.gateway?.openAppSettings;
    if (fn != null) return fn();
    return ScreenOn.openAppSettings();
  }

  Future<void> _openLocationSettings() {
    final fn = widget.gateway?.openLocationSettings;
    if (fn != null) return fn();
    return CameraBridge.openLocationSettings();
  }

  Future<SceneMapBootstrap> _fetchMapBootstrap() {
    final fn = widget.gateway?.fetchMapBootstrap;
    if (fn != null) return fn();
    final api = _api;
    if (api == null) throw Exception('未连接服务端');
    return api.fetchSceneMapBootstrap();
  }

  Future<WaterSourceListResult> _fetchWaterSources() {
    final fn = widget.gateway?.fetchWaterSources;
    if (fn != null) return fn();
    final api = _api;
    if (api == null) throw Exception('未连接服务端');
    return api.fetchWaterSources();
  }

  Future<WaterSource> _createWaterSource({
    required WaterSourceCategory category,
    required String name,
    required double lat,
    required double lng,
    required WaterSourceStatus status,
    required List<WaterIntakeMethod> intakeMethods,
    required String note,
  }) {
    final fn = widget.gateway?.createWaterSource;
    if (fn != null) {
      return fn(
        category: category,
        name: name,
        lat: lat,
        lng: lng,
        status: status,
        intakeMethods: intakeMethods,
        note: note,
      );
    }
    final api = _api;
    if (api == null) throw Exception('未连接服务端');
    return api.createWaterSource(
      category: category,
      name: name,
      lat: lat,
      lng: lng,
      status: status,
      intakeMethods: intakeMethods,
      note: note,
    );
  }

  Future<WaterSource> _updateWaterSource(
    String id, {
    WaterSourceCategory? category,
    String? name,
    double? lat,
    double? lng,
    WaterSourceStatus? status,
    List<WaterIntakeMethod>? intakeMethods,
    String? note,
  }) {
    final fn = widget.gateway?.updateWaterSource;
    if (fn != null) {
      return fn(
        id,
        category: category,
        name: name,
        lat: lat,
        lng: lng,
        status: status,
        intakeMethods: intakeMethods,
        note: note,
      );
    }
    final api = _api;
    if (api == null) throw Exception('未连接服务端');
    return api.updateWaterSource(
      id,
      category: category,
      name: name,
      lat: lat,
      lng: lng,
      status: status,
      intakeMethods: intakeMethods,
      note: note,
    );
  }

  Future<int> _deleteWaterSource(String id) {
    final fn = widget.gateway?.deleteWaterSource;
    if (fn != null) return fn(id);
    final api = _api;
    if (api == null) throw Exception('未连接服务端');
    return api.deleteWaterSource(id);
  }

  Future<WaterSource> _restoreWaterSource(String id) {
    final fn = widget.gateway?.restoreWaterSource;
    if (fn != null) return fn(id);
    final api = _api;
    if (api == null) throw Exception('未连接服务端');
    return api.restoreWaterSource(id);
  }

  Future<void> _initialize() async {
    final gen = ++_generation;
    _ticketRenewTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _loadingList = true;
      _listError = null;
      _loadingBootstrap = true;
      _bootstrapError = null;
      _scriptError = null;
      _locStatus = _WaterLocStatus.loading;
      _htmlLoaded = false;
      _ticketRenewAttempts = 0;
    });

    await Future.wait([
      _loadWaterSources(gen),
      _loadBootstrap(gen),
      _initLocation(gen),
    ]);
  }

  Future<void> _refreshData() async {
    final gen = _generation;
    setState(() {
      _loadingList = true;
      _listError = null;
    });
    await Future.wait([_loadWaterSources(gen), _initLocation(gen)]);
  }

  Future<void> _loadWaterSources(int gen) async {
    if (widget.gateway?.fetchWaterSources == null &&
        (_api == null || widget.controller.isGuest)) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingList = false;
        _listError = '请先完成单位登录后查看本单位水源库';
      });
      return;
    }

    try {
      final result = await _fetchWaterSources();
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingList = false;
        _listError = null;
        _items = result.items;
      });
      _syncMapItems();
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingList = false;
        _listError = _friendlyError(e);
      });
    }
  }

  Future<void> _loadBootstrap(int gen, {bool forceReloadHtml = false}) async {
    if (widget.gateway?.fetchMapBootstrap == null &&
        (_api == null || widget.controller.isGuest)) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingBootstrap = false;
        _bootstrap = null;
        _bootstrapError = '请先完成单位登录后加载高德底图';
      });
      return;
    }

    try {
      final boot = await _fetchMapBootstrap();
      if (!mounted || gen != _generation) return;
      final configured = boot.configured && boot.jsKey.trim().isNotEmpty;
      setState(() {
        _loadingBootstrap = false;
        _bootstrap = boot;
        _bootstrapError = configured
            ? null
            : (boot.message ?? '服务端尚未配置高德底图服务，已切换为纯列表查水');
        _scriptError = null;
        if (forceReloadHtml) _htmlLoaded = false;
      });
      if (configured) {
        _scheduleTicketRenewal(gen, boot);
        _tryLoadHtmlIntoSurface();
      }
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingBootstrap = false;
        _bootstrapError = _friendlyError(e);
      });
    }
  }

  void _scheduleTicketRenewal(int gen, SceneMapBootstrap boot) {
    _ticketRenewTimer?.cancel();
    if (boot.expiresInMs <= 0) return;
    final delayMs = math.max(30000, boot.expiresInMs - 60000);
    _ticketRenewTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted || gen != _generation) return;
      unawaited(_loadBootstrap(gen, forceReloadHtml: true));
    });
  }

  Future<void> _initLocation(int gen) async {
    try {
      final permitted = await _requestLocationPermission();
      if (!mounted || gen != _generation) return;
      if (!permitted) {
        setState(() {
          _locStatus = _WaterLocStatus.permissionDenied;
          _myGcj = null;
        });
        return;
      }
      final enabled = await _isLocationServiceEnabled();
      if (!mounted || gen != _generation) return;
      if (!enabled) {
        setState(() {
          _locStatus = _WaterLocStatus.serviceDisabled;
          _myGcj = null;
        });
        return;
      }
      final fix = await _fetchCurrentLocation();
      if (!mounted || gen != _generation) return;
      if (fix == null) {
        setState(() {
          _locStatus = _WaterLocStatus.fixFailed;
          _myGcj = null;
        });
        return;
      }
      final gcj = ChinaCoord.wgs84ToGcj02(fix.lat, fix.lon);
      // 显式映射 ChinaCoord 的 lon 字段为后端统一的 lng 字段
      final mapped = (lat: gcj.lat, lng: gcj.lon, accuracy: fix.accuracyMeters);
      setState(() {
        _locStatus = _WaterLocStatus.ok;
        _myGcj = mapped;
      });
      _syncMyLocationToMap(autoCenter: true);
    } catch (_) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _locStatus = _WaterLocStatus.fixFailed;
        _myGcj = null;
      });
    }
  }

  bool get _canRenderMap =>
      widget.mapBuilder != null ||
      (_bootstrapError == null &&
          _scriptError == null &&
          _bootstrap != null &&
          _bootstrap!.configured &&
          _bootstrap!.jsKey.trim().isNotEmpty);

  void _tryLoadHtmlIntoSurface() {
    if (!_surfaceReady || _htmlLoaded) return;
    final boot = _bootstrap;
    if (boot == null || !boot.configured || boot.jsKey.trim().isEmpty) return;
    final apiBase = _api?.baseUrl ?? 'https://fireman119.xyz';
    final serviceHost = boot.resolveServiceHost(apiBase);
    final html = buildWaterSourcesMapHtml(
      jsKey: boot.jsKey,
      serviceHost: serviceHost,
      initialMyGcj: _myGcj,
      initialCenter: _pickCenter ?? _lastMapCenter,
      initialZoom: _lastMapZoom,
      initialItems: _filteredItems,
      selectedId: _selectedId,
    );
    _htmlLoaded = true;
    unawaited(_surfaceController.loadHtml(apiBase, html));
  }

  void _onBridgeEvent(String type, Map<String, dynamic> data) {
    if (!mounted) return;
    switch (type) {
      case 'mapReady':
        _ticketRenewAttempts = 0;
        _syncMapItems();
        _syncMyLocationToMap(autoCenter: _lastMapCenter == null);
        if (_pickingMode) {
          unawaited(
            _surfaceController.evalJs(
              'window.watchdogWaterMap && window.watchdogWaterMap.setPickingMode(true);',
            ),
          );
        }
      case 'markerClick':
        final id = data['id']?.toString() ?? '';
        if (id.isNotEmpty) _handleSelectMarker(id);
      case 'centerChanged':
        final lat = (data['lat'] as num?)?.toDouble();
        final lng = (data['lng'] as num?)?.toDouble();
        final zoom = (data['zoom'] as num?)?.toDouble();
        if (lat != null && lng != null && lat.isFinite && lng.isFinite) {
          _lastMapCenter = (lat: lat, lng: lng);
          if (zoom != null && zoom.isFinite) _lastMapZoom = zoom;
          if (_pickingMode) {
            setState(() => _pickCenter = (lat: lat, lng: lng));
          }
        }
      case 'ticketExpired':
        if (_ticketRenewAttempts < 2) {
          _ticketRenewAttempts++;
          unawaited(_loadBootstrap(_generation, forceReloadHtml: true));
        } else {
          setState(() {
            _scriptError = '地图票据已过期，请点击重试刷新底图';
          });
        }
      case 'scriptError':
      case 'loadError':
        setState(() {
          _scriptError =
              data['message']?.toString() ?? '底图加载失败，已切换为纯列表查水模式';
        });
    }
  }

  void _syncMapItems() {
    if (!_htmlLoaded && widget.mapBuilder == null) return;
    final payload = _safeJsonEncode(
      _filteredItems.map(_waterSourceToJsPayload).toList(growable: false),
    );
    final selected = _safeJsonEncode(_selectedId);
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogWaterMap && window.watchdogWaterMap.setItems($payload, $selected);',
      ),
    );
  }

  void _syncMyLocationToMap({bool autoCenter = false}) {
    final my = _myGcj;
    if (my == null) return;
    final payload = _safeJsonEncode({
      'lat': my.lat,
      'lng': my.lng,
      'accuracy': my.accuracy,
    });
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogWaterMap && window.watchdogWaterMap.setMyLocation($payload, ${autoCenter ? 'true' : 'false'});',
      ),
    );
  }

  void _centerOnMyLocation() {
    final my = _myGcj;
    if (my == null) {
      unawaited(_initLocation(_generation));
      return;
    }
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogWaterMap && window.watchdogWaterMap.centerOn(${my.lng}, ${my.lat}, 17);',
      ),
    );
  }

  double? _distanceFor(WaterSource item) {
    final my = _myGcj;
    if (my == null) return null;
    return ChinaCoord.distanceMeters(my.lat, my.lng, item.lat, item.lng);
  }

  List<WaterSource> get _filteredItems {
    final q = _searchQuery.trim().toLowerCase();
    final filtered = _items
        .where((item) {
          if (_categoryFilter != null && item.category != _categoryFilter) {
            return false;
          }
          if (_onlyAvailable && !item.isAvailable) {
            return false;
          }
          if (q.isNotEmpty) {
            final inName = item.name.toLowerCase().contains(q);
            final inNote = item.note.toLowerCase().contains(q);
            if (!inName && !inNote) return false;
          }
          return true;
        })
        .toList(growable: true);

    final my = _myGcj;
    if (my != null) {
      filtered.sort((a, b) {
        final da = ChinaCoord.distanceMeters(my.lat, my.lng, a.lat, a.lng);
        final db = ChinaCoord.distanceMeters(my.lat, my.lng, b.lat, b.lng);
        final cmp = da.compareTo(db);
        if (cmp != 0) return cmp;
        final timeCmp = b.updatedAt.compareTo(a.updatedAt);
        if (timeCmp != 0) return timeCmp;
        return a.name.compareTo(b.name);
      });
    } else {
      filtered.sort((a, b) {
        final timeCmp = b.updatedAt.compareTo(a.updatedAt);
        if (timeCmp != 0) return timeCmp;
        return a.name.compareTo(b.name);
      });
    }
    return filtered;
  }

  WaterSource? get _selectedItem {
    final id = _selectedId;
    if (id == null) return null;
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _handleSelectMarker(String id) {
    WaterSource? found;
    for (final item in _items) {
      if (item.id == id) {
        found = item;
        break;
      }
    }
    if (found == null) return;
    setState(() => _selectedId = found!.id);
    _syncMapItems();
    unawaited(
      _showDetailSheet(found).whenComplete(() {
        if (!mounted || _selectedId != found!.id) return;
        setState(() => _selectedId = null);
        _syncMapItems();
      }),
    );
  }

  void _handleSelectCard(WaterSource item) {
    setState(() => _selectedId = item.id);
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogWaterMap && window.watchdogWaterMap.focusItem(${_safeJsonEncode(item.id)}, ${item.lng}, ${item.lat});',
      ),
    );
    unawaited(_showDetailSheet(item));
  }

  void _startAddFlow() {
    if (_canRenderMap) {
      final start = _myGcj != null
          ? (lat: _myGcj!.lat, lng: _myGcj!.lng)
          : (_lastMapCenter ??
                (_items.isNotEmpty
                    ? (lat: _items.first.lat, lng: _items.first.lng)
                    : (lat: 30.0, lng: 120.0)));
      setState(() {
        _pickingMode = true;
        _editingCoordTarget = null;
        _pickCenter = start;
      });
      unawaited(
        _surfaceController.evalJs(
          'window.watchdogWaterMap && window.watchdogWaterMap.centerOn(${start.lng}, ${start.lat}, 17);',
        ),
      );
      unawaited(
        _surfaceController.evalJs(
          'window.watchdogWaterMap && window.watchdogWaterMap.setPickingMode(true);',
        ),
      );
      return;
    }

    // 底图不可用降级：直接打开新增表单，允许使用当前定位或手填坐标
    unawaited(
      _showFormSheet(
        initialLat: _myGcj?.lat,
        initialLng: _myGcj?.lng,
        allowManualCoords: true,
      ),
    );
  }

  void _startRepositionFlow(WaterSource target) {
    final start = (lat: target.lat, lng: target.lng);
    setState(() {
      _pickingMode = true;
      _editingCoordTarget = target;
      _pickCenter = start;
    });
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogWaterMap && window.watchdogWaterMap.centerOn(${start.lng}, ${start.lat}, 18);',
      ),
    );
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogWaterMap && window.watchdogWaterMap.setPickingMode(true);',
      ),
    );
  }

  void _cancelPickingMode() {
    setState(() {
      _pickingMode = false;
      _editingCoordTarget = null;
    });
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogWaterMap && window.watchdogWaterMap.setPickingMode(false);',
      ),
    );
  }

  Future<void> _confirmPickPosition() async {
    final pos = _pickCenter;
    if (pos == null) return;
    final target = _editingCoordTarget;
    _cancelPickingMode();

    if (target != null) {
      try {
        final updated = await _updateWaterSource(
          target.id,
          lat: pos.lat,
          lng: pos.lng,
        );
        if (!mounted) return;
        _replaceLocalItem(updated);
        _showToast('已更新「${updated.name}」坐标');
      } catch (e) {
        if (!mounted) return;
        _showToast(_friendlyError(e));
      }
      return;
    }

    await _showFormSheet(initialLat: pos.lat, initialLng: pos.lng);
  }

  void _replaceLocalItem(WaterSource updated) {
    setState(() {
      final idx = _items.indexWhere((e) => e.id == updated.id);
      if (idx >= 0) {
        final next = List<WaterSource>.from(_items);
        next[idx] = updated;
        _items = next;
      } else {
        _items = [updated, ..._items];
      }
      _selectedId = updated.id;
    });
    _syncMapItems();
  }

  Future<void> _quickToggleStatus(WaterSource item) async {
    final nextStatus = item.isAvailable
        ? WaterSourceStatus.unavailable
        : WaterSourceStatus.available;
    try {
      final updated = await _updateWaterSource(item.id, status: nextStatus);
      if (!mounted) return;
      _replaceLocalItem(updated);
      _showToast('已标记为「${updated.status.label}」');
    } catch (e) {
      if (!mounted) return;
      _showToast(_friendlyError(e));
    }
  }

  Future<void> _confirmAndDelete(WaterSource item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除水源点位'),
        content: Text('确定删除「${item.name}」吗？删除后 60 秒内可在底部提示条一键撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.destructive,
              foregroundColor: AppColors.onPrimary,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _deleteWaterSource(item.id);
      if (!mounted) return;
      setState(() {
        _items = _items.where((e) => e.id != item.id).toList(growable: false);
        if (_selectedId == item.id) _selectedId = null;
      });
      _syncMapItems();

      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 60),
          content: Text('已删除「${item.name}」'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              unawaited(_undoDelete(item));
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showToast(_friendlyError(e));
    }
  }

  Future<void> _undoDelete(WaterSource item) async {
    try {
      final restored = await _restoreWaterSource(item.id);
      if (!mounted) return;
      _replaceLocalItem(restored);
      _showToast('已恢复「${restored.name}」');
    } catch (e) {
      if (!mounted) return;
      _showToast(_friendlyError(e));
    }
  }

  Future<void> _showDetailSheet(WaterSource initialItem) async {
    var current = initialItem;
    var toggling = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final dist = _distanceFor(current);
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s4,
                  AppSpacing.s3,
                  AppSpacing.s4,
                  AppSpacing.s4,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CategoryIconBadge(
                          category: current.category,
                          available: current.isAvailable,
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                current.name,
                                style: AppTextStyles.title.copyWith(
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: AppSpacing.s2,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    current.category.label,
                                    style: AppTextStyles.caption.copyWith(
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                  if (dist != null)
                                    Text(
                                      '直线 ${ChinaCoord.formatDistance(dist)}',
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.actionPrimary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s2),
                        _WaterStatusBadge(status: current.status),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    AppCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s3,
                        vertical: AppSpacing.s2,
                      ),
                      color: AppColors.surfaceSubtle,
                      side: BorderSide(color: AppColors.border, width: 1),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              current.isAvailable
                                  ? '当前状态：可用（点击可快速标为不可用）'
                                  : '当前状态：不可用（点击可快速恢复可用）',
                              style: AppTextStyles.label.copyWith(
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.s2),
                          FilledButton.tonal(
                            key: const Key('water-detail-toggle-status'),
                            onPressed: toggling
                                ? null
                                : () async {
                                    setSheetState(() => toggling = true);
                                    final nextStatus = current.isAvailable
                                        ? WaterSourceStatus.unavailable
                                        : WaterSourceStatus.available;
                                    try {
                                      final updated = await _updateWaterSource(
                                        current.id,
                                        status: nextStatus,
                                      );
                                      if (!mounted) return;
                                      _replaceLocalItem(updated);
                                      setSheetState(() {
                                        current = updated;
                                        toggling = false;
                                      });
                                      _showToast(
                                        '已标记为「${updated.status.label}」',
                                      );
                                    } catch (e) {
                                      if (!mounted) return;
                                      setSheetState(() => toggling = false);
                                      _showToast(_friendlyError(e));
                                    }
                                  },
                            child: Text(
                              current.isAvailable ? '标为不可用' : '标为可用',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (current.category == WaterSourceCategory.natural &&
                        current.intakeMethods.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.s3),
                      Wrap(
                        spacing: AppSpacing.s2,
                        runSpacing: AppSpacing.s1,
                        children: [
                          for (final m in current.intakeMethods)
                            Chip(
                              label: Text(m.label),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: AppSpacing.s3),
                    Text(
                      current.hasNote ? current.note : '暂无备注',
                      style: AppTextStyles.bodyMd.copyWith(
                        color: current.hasNote
                            ? AppColors.textPrimary
                            : AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    Text(
                      'GCJ-02: ${current.lat.toStringAsFixed(6)}, ${current.lng.toStringAsFixed(6)}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '最近维护：${current.latestActorName} · ${_formatTimestamp(current.updatedAt > 0 ? current.updatedAt : current.createdAt)}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('water-detail-edit'),
                            onPressed: () {
                              Navigator.pop(ctx);
                              unawaited(
                                _showFormSheet(
                                  existing: current,
                                  allowManualCoords: !_canRenderMap,
                                ),
                              );
                            },
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('编辑'),
                          ),
                        ),
                        if (_canRenderMap) ...[
                          const SizedBox(width: AppSpacing.s2),
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const Key('water-detail-reposition'),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _startRepositionFlow(current);
                              },
                              icon: const Icon(
                                Icons.my_location_outlined,
                                size: 18,
                              ),
                              label: const Text('调坐标'),
                            ),
                          ),
                        ],
                        const SizedBox(width: AppSpacing.s2),
                        OutlinedButton.icon(
                          key: const Key('water-detail-delete'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.destructive,
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            unawaited(_confirmAndDelete(current));
                          },
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showFormSheet({
    WaterSource? existing,
    double? initialLat,
    double? initialLng,
    bool allowManualCoords = false,
  }) async {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    final latCtrl = TextEditingController(
      text: (initialLat ?? existing?.lat)?.toStringAsFixed(6) ?? '',
    );
    final lngCtrl = TextEditingController(
      text: (initialLng ?? existing?.lng)?.toStringAsFixed(6) ?? '',
    );

    var category = existing?.category ?? WaterSourceCategory.hydrant;
    var status = existing?.status ?? WaterSourceStatus.available;
    final selectedMethods = <WaterIntakeMethod>{
      ...(existing?.intakeMethods ?? const []),
    };
    String? inlineError;
    var saving = false;

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        builder: (sheetCtx) {
          return StatefulBuilder(
            builder: (ctx, setSheetState) {
              final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
              return SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.s4,
                    AppSpacing.s3,
                    AppSpacing.s4,
                    AppSpacing.s4 + bottomInset,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                isEdit ? '编辑水源点位' : '新增水源点位',
                                style: AppTextStyles.h2.copyWith(
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(ctx),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        TextField(
                          key: const Key('water-form-name'),
                          controller: nameCtrl,
                          maxLength: 120,
                          decoration: const InputDecoration(
                            labelText: '点位简称 *',
                            hintText: '例如：示范路北口消火栓、示例水厂消防水池',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) {
                            if (inlineError != null) {
                              setSheetState(() => inlineError = null);
                            }
                          },
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        const SectionTitle(text: '水源类别'),
                        Wrap(
                          spacing: AppSpacing.s2,
                          runSpacing: AppSpacing.s1,
                          children: [
                            for (final c in WaterSourceCategory.values)
                              ChoiceChip(
                                key: Key('water-form-cat-${c.apiValue}'),
                                label: Text(c.label),
                                selected: category == c,
                                onSelected: (_) {
                                  setSheetState(() {
                                    category = c;
                                    inlineError = null;
                                  });
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        const SectionTitle(text: '可用状态'),
                        Wrap(
                          spacing: AppSpacing.s2,
                          children: [
                            for (final s in WaterSourceStatus.values)
                              ChoiceChip(
                                key: Key('water-form-status-${s.apiValue}'),
                                label: Text(s.label),
                                selected: status == s,
                                onSelected: (_) {
                                  setSheetState(() => status = s);
                                },
                              ),
                          ],
                        ),
                        if (category == WaterSourceCategory.natural) ...[
                          const SizedBox(height: AppSpacing.s2),
                          const SectionTitle(text: '取水方式（至少选 1 项）'),
                          Wrap(
                            spacing: AppSpacing.s2,
                            runSpacing: AppSpacing.s1,
                            children: [
                              for (final m in WaterIntakeMethod.values)
                                FilterChip(
                                  key: Key('water-form-intake-${m.apiValue}'),
                                  label: Text(m.label),
                                  selected: selectedMethods.contains(m),
                                  onSelected: (checked) {
                                    setSheetState(() {
                                      if (checked) {
                                        selectedMethods.add(m);
                                      } else {
                                        selectedMethods.remove(m);
                                      }
                                      inlineError = null;
                                    });
                                  },
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: AppSpacing.s3),
                        TextField(
                          key: const Key('water-form-note'),
                          controller: noteCtrl,
                          maxLines: 3,
                          maxLength: 500,
                          decoration: const InputDecoration(
                            labelText: '备注（选填）',
                            hintText: '可填写缺闷盖、水压偏低、水池容量、对应楼栋等',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        if (allowManualCoords) ...[
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const Key('water-form-lat'),
                                  controller: latCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: '纬度 (GCJ-02)',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.s2),
                              Expanded(
                                child: TextField(
                                  key: const Key('water-form-lng'),
                                  controller: lngCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: '经度 (GCJ-02)',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ] else ...[
                          Text(
                            '选定坐标 (GCJ-02)：${latCtrl.text}, ${lngCtrl.text}',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                        if (inlineError != null) ...[
                          const SizedBox(height: AppSpacing.s2),
                          AppNotice(
                            text: inlineError!,
                            kind: AppNoticeKind.error,
                          ),
                        ],
                        const SizedBox(height: AppSpacing.s4),
                        FilledButton(
                          key: const Key('water-form-submit'),
                          onPressed: saving
                              ? null
                              : () async {
                                  final trimmedName = nameCtrl.text.trim();
                                  if (trimmedName.isEmpty) {
                                    setSheetState(
                                      () => inlineError = '请填写点位简称',
                                    );
                                    return;
                                  }
                                  if (category == WaterSourceCategory.natural &&
                                      selectedMethods.isEmpty) {
                                    setSheetState(
                                      () => inlineError = '天然水源至少选择一项取水方式',
                                    );
                                    return;
                                  }
                                  final lat = double.tryParse(
                                    latCtrl.text.trim(),
                                  );
                                  final lng = double.tryParse(
                                    lngCtrl.text.trim(),
                                  );
                                  if (lat == null ||
                                      lng == null ||
                                      lat < 3 ||
                                      lat > 55 ||
                                      lng < 73 ||
                                      lng > 136) {
                                    setSheetState(
                                      () => inlineError = '坐标无效，请先在地图选点或填写有效经纬度',
                                    );
                                    return;
                                  }

                                  final normalizedMethods =
                                      category == WaterSourceCategory.natural
                                      ? WaterIntakeMethod.values
                                            .where(selectedMethods.contains)
                                            .toList(growable: false)
                                      : const <WaterIntakeMethod>[];

                                  setSheetState(() {
                                    saving = true;
                                    inlineError = null;
                                  });

                                  try {
                                    final saved = isEdit
                                        ? await _updateWaterSource(
                                            existing.id,
                                            category: category,
                                            name: trimmedName,
                                            lat: lat,
                                            lng: lng,
                                            status: status,
                                            intakeMethods: normalizedMethods,
                                            note: noteCtrl.text.trim(),
                                          )
                                        : await _createWaterSource(
                                            category: category,
                                            name: trimmedName,
                                            lat: lat,
                                            lng: lng,
                                            status: status,
                                            intakeMethods: normalizedMethods,
                                            note: noteCtrl.text.trim(),
                                          );
                                    if (!mounted) return;
                                    _replaceLocalItem(saved);
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    _showToast(
                                      isEdit
                                          ? '已更新「${saved.name}」'
                                          : '已新增「${saved.name}」',
                                    );
                                  } catch (e) {
                                    if (!mounted) return;
                                    setSheetState(() {
                                      saving = false;
                                      inlineError = _friendlyError(e);
                                    });
                                  }
                                },
                          child: Text(
                            saving ? '保存中...' : (isEdit ? '保存修改' : '保存点位'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        nameCtrl.dispose();
        noteCtrl.dispose();
        latCtrl.dispose();
        lngCtrl.dispose();
      });
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  String _friendlyError(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  String _formatTimestamp(int ms) {
    if (ms <= 0) return '未知时间';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    final filtered = _filteredItems;
    final summary = WaterSourceSummary.fromItems(_items);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: const Text('周边水源'),
        actions: [
          IconButton(
            key: const Key('water-sources-refresh'),
            tooltip: '刷新水源与定位',
            visualDensity: VisualDensity.compact,
            onPressed: _refreshData,
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s2),
            child: FilledButton.icon(
              key: const Key('water-sources-add'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3,
                  vertical: 0,
                ),
                minimumSize: const Size(0, 36),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _pickingMode ? null : _startAddFlow,
              icon: const Icon(Icons.add_location_alt_outlined, size: 17),
              label: const Text('新增'),
            ),
          ),
        ],
      ),
      body: _canRenderMap
          ? _buildFullScreenMapBody(context, filtered, summary)
          : _buildDegradedBody(filtered, summary),
    );
  }

  Widget _buildFullScreenMapBody(
    BuildContext context,
    List<WaterSource> filtered,
    WaterSourceSummary summary,
  ) {
    final mapState = WaterSourcesMapState(
      surfaceController: _surfaceController,
      items: filtered,
      selected: _selectedItem,
      myGcj: _myGcj,
      pickingMode: _pickingMode,
      pickCenter: _pickCenter,
      onBridgeEvent: _onBridgeEvent,
      onSelectMarker: _handleSelectMarker,
      onPickCenterChanged: (lat, lng) {
        if (!mounted) return;
        setState(() => _pickCenter = (lat: lat, lng: lng));
      },
    );

    final mapWidget = widget.mapBuilder != null
        ? widget.mapBuilder!(context, mapState)
        : _AndroidWaterMapSurface(
            surfaceController: _surfaceController,
            backgroundColor: AppColors.heroBackground.toARGB32(),
            onReady: () {
              _surfaceReady = true;
              _tryLoadHtmlIntoSurface();
            },
            onBridgeEvent: _onBridgeEvent,
          );

    return SafeArea(
      top: false,
      child: Stack(
        children: [
          Positioned.fill(child: mapWidget),
          Positioned(
            top: AppSpacing.s2,
            left: AppSpacing.s3,
            right: AppSpacing.s3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_pickingMode) _buildMapFilterOverlay(summary),
                if (_locStatus != _WaterLocStatus.ok &&
                    _locStatus != _WaterLocStatus.loading) ...[
                  const SizedBox(height: AppSpacing.s2),
                  _buildLocationDegradedBanner(inOverlay: true),
                ],
                if (_listError != null && _items.isEmpty) ...[
                  const SizedBox(height: AppSpacing.s2),
                  AppNotice(
                    text: _listError!,
                    kind: AppNoticeKind.error,
                    action: TextButton(
                      key: const Key('water-list-retry'),
                      onPressed: _refreshData,
                      child: const Text('重试'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_loadingList && _items.isEmpty)
            const Positioned(
              top: 64,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            ),
          if (!_pickingMode)
            Positioned(
              right: AppSpacing.s3,
              bottom: AppSpacing.s4,
              child: AppCard(
                radius: AppRadius.md,
                padding: EdgeInsets.zero,
                onTap: _centerOnMyLocation,
                child: SizedBox(
                  key: const Key('water-map-center-me'),
                  width: 48,
                  height: 48,
                  child: Tooltip(
                    message: '回到当前位置',
                    child: Icon(
                      Icons.my_location,
                      size: 22,
                      color: AppColors.actionPrimary,
                    ),
                  ),
                ),
              ),
            ),
          if (_pickingMode) ...[
            const IgnorePointer(
              child: Center(
                child: _CrosshairReticle(key: Key('water-map-crosshair')),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildPickingPanel(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMapFilterOverlay(WaterSourceSummary summary) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _overlayFilterChip(
            key: const Key('water-filter-all'),
            label: '全部 (${summary.total})',
            selected: _categoryFilter == null,
            onTap: () {
              setState(() => _categoryFilter = null);
              _syncMapItems();
            },
          ),
          const SizedBox(width: AppSpacing.s2),
          _overlayFilterChip(
            key: const Key('water-filter-hydrant'),
            label: '消火栓 (${summary.hydrant})',
            selected: _categoryFilter == WaterSourceCategory.hydrant,
            onTap: () {
              setState(() => _categoryFilter = WaterSourceCategory.hydrant);
              _syncMapItems();
            },
          ),
          const SizedBox(width: AppSpacing.s2),
          _overlayFilterChip(
            key: const Key('water-filter-natural'),
            label: '天然水源 (${summary.natural})',
            selected: _categoryFilter == WaterSourceCategory.natural,
            onTap: () {
              setState(() => _categoryFilter = WaterSourceCategory.natural);
              _syncMapItems();
            },
          ),
          const SizedBox(width: AppSpacing.s2),
          _overlayFilterChip(
            key: const Key('water-filter-pump_connector'),
            label: '接合器 (${summary.pumpConnector})',
            selected: _categoryFilter == WaterSourceCategory.pumpConnector,
            onTap: () {
              setState(
                () => _categoryFilter = WaterSourceCategory.pumpConnector,
              );
              _syncMapItems();
            },
          ),
          const SizedBox(width: AppSpacing.s2),
          _overlayFilterChip(
            key: const Key('water-filter-only-available'),
            label: '仅看可用',
            selected: _onlyAvailable,
            onTap: () {
              setState(() => _onlyAvailable = !_onlyAvailable);
              _syncMapItems();
            },
          ),
        ],
      ),
    );
  }

  Widget _overlayFilterChip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected
          ? AppColors.actionPrimary
          : AppColors.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      elevation: 1,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: selected ? AppColors.onPrimary : AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDegradedBody(
    List<WaterSource> filtered,
    WaterSourceSummary summary,
  ) {
    return Column(
      children: [
        if (!_loadingBootstrap) _buildMapDegradedBanner(),
        if (_locStatus != _WaterLocStatus.ok &&
            _locStatus != _WaterLocStatus.loading)
          _buildLocationDegradedBanner(),
        _buildFilterBar(summary),
        Expanded(child: _buildListSection(filtered)),
      ],
    );
  }

  Widget _buildPickingPanel() {
    final pos = _pickCenter;
    final isReposition = _editingCoordTarget != null;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: AppCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              text: isReposition
                  ? '调整「${_editingCoordTarget!.name}」坐标'
                  : '拖动卫星图微调中心十字准星',
            ),
            Text(
              pos != null
                  ? '当前准星 (GCJ-02)：${pos.lat.toStringAsFixed(6)}, ${pos.lng.toStringAsFixed(6)}'
                  : '正在读取地图中心坐标...',
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              '确认位置后手填点位简称即可保存，有效修正 GPS 漂移。',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('water-pick-cancel'),
                    onPressed: _cancelPickingMode,
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: FilledButton(
                    key: const Key('water-pick-confirm'),
                    onPressed: pos == null ? null : _confirmPickPosition,
                    child: Text(isReposition ? '保存新坐标' : '确认此位置'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapDegradedBanner() {
    final reason = _scriptError ?? _bootstrapError ?? '底图加载失败，已切换为纯列表查水模式';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.s2,
        AppSpacing.pageMargin,
        0,
      ),
      child: AppNotice(
        text: reason,
        kind: AppNoticeKind.warning,
        action: TextButton(
          key: const Key('water-map-retry'),
          onPressed: () =>
              unawaited(_loadBootstrap(_generation, forceReloadHtml: true)),
          child: const Text('重试底图'),
        ),
      ),
    );
  }

  Widget _buildLocationDegradedBanner({bool inOverlay = false}) {
    final String message;
    final VoidCallback? secondaryAction;
    final String? secondaryLabel;
    switch (_locStatus) {
      case _WaterLocStatus.permissionDenied:
        message = inOverlay ? '未授予定位权限，无法自动定位到当前位置' : '未授予精确定位权限，已降级按更新时间展示水源列表';
        secondaryAction = _openAppSettings;
        secondaryLabel = '去授权';
      case _WaterLocStatus.serviceDisabled:
        message = inOverlay ? '系统定位服务未开启，请开启后重试' : '系统定位服务未开启，已降级按更新时间展示水源列表';
        secondaryAction = _openLocationSettings;
        secondaryLabel = '去开启';
      case _WaterLocStatus.fixFailed:
      case _WaterLocStatus.loading:
      case _WaterLocStatus.ok:
        message = inOverlay ? '当前位置获取失败，可手动拖动地图查看' : '当前位置获取失败，已降级按更新时间展示水源列表';
        secondaryAction = null;
        secondaryLabel = null;
    }

    final notice = AppNotice(
      key: const Key('water-location-degraded-banner'),
      text: message,
      kind: AppNoticeKind.warning,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (secondaryAction != null && secondaryLabel != null)
            TextButton(
              onPressed: secondaryAction,
              child: Text(secondaryLabel),
            ),
          TextButton(
            key: const Key('water-location-retry'),
            onPressed: () => unawaited(_initLocation(_generation)),
            child: const Text('重试定位'),
          ),
        ],
      ),
    );
    if (inOverlay) return notice;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.s2,
        AppSpacing.pageMargin,
        0,
      ),
      child: notice,
    );
  }

  Widget _buildFilterBar(WaterSourceSummary summary) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.s2,
        AppSpacing.pageMargin,
        AppSpacing.s1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('water-search-input'),
            controller: _searchController,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索点位名称或备注（如水池、闷盖、楼栋）',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                        _syncMapItems();
                      },
                      icon: const Icon(Icons.clear, size: 18),
                    )
                  : null,
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(color: AppColors.border),
              ),
            ),
            onChanged: (value) {
              setState(() => _searchQuery = value);
              _syncMapItems();
            },
          ),
          const SizedBox(height: AppSpacing.s2),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  key: const Key('water-filter-all'),
                  label: Text('全部 (${summary.total})'),
                  selected: _categoryFilter == null,
                  onSelected: (_) {
                    setState(() => _categoryFilter = null);
                    _syncMapItems();
                  },
                ),
                const SizedBox(width: AppSpacing.s2),
                ChoiceChip(
                  key: const Key('water-filter-hydrant'),
                  label: Text('消火栓 (${summary.hydrant})'),
                  selected: _categoryFilter == WaterSourceCategory.hydrant,
                  onSelected: (_) {
                    setState(
                      () => _categoryFilter = WaterSourceCategory.hydrant,
                    );
                    _syncMapItems();
                  },
                ),
                const SizedBox(width: AppSpacing.s2),
                ChoiceChip(
                  key: const Key('water-filter-natural'),
                  label: Text('天然水源 (${summary.natural})'),
                  selected: _categoryFilter == WaterSourceCategory.natural,
                  onSelected: (_) {
                    setState(
                      () => _categoryFilter = WaterSourceCategory.natural,
                    );
                    _syncMapItems();
                  },
                ),
                const SizedBox(width: AppSpacing.s2),
                ChoiceChip(
                  key: const Key('water-filter-pump_connector'),
                  label: Text('接合器 (${summary.pumpConnector})'),
                  selected:
                      _categoryFilter == WaterSourceCategory.pumpConnector,
                  onSelected: (_) {
                    setState(
                      () => _categoryFilter = WaterSourceCategory.pumpConnector,
                    );
                    _syncMapItems();
                  },
                ),
                const SizedBox(width: AppSpacing.s2),
                FilterChip(
                  key: const Key('water-filter-only-available'),
                  label: const Text('仅看可用'),
                  selected: _onlyAvailable,
                  onSelected: (checked) {
                    setState(() => _onlyAvailable = checked);
                    _syncMapItems();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListSection(List<WaterSource> filtered) {
    if (_loadingList && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_listError != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppNotice(text: _listError!, kind: AppNoticeKind.error),
              const SizedBox(height: AppSpacing.s3),
              FilledButton(
                key: const Key('water-list-retry'),
                onPressed: _refreshData,
                child: const Text('重试加载'),
              ),
            ],
          ),
        ),
      );
    }

    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: Text(
            _items.isEmpty ? '本单位暂未录入水源点位，点击右上角「新增」开始采集' : '当前筛选条件下暂无匹配水源',
            style: AppTextStyles.bodyMd.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: const Key('water-sources-list'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.s1,
        AppSpacing.pageMargin,
        AppSpacing.s6,
      ),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s2),
      itemBuilder: (context, index) {
        final item = filtered[index];
        final dist = _distanceFor(item);
        final isSelected = item.id == _selectedId;
        return AppCard(
          key: Key('water-card-${item.id}'),
          padding: const EdgeInsets.all(AppSpacing.s3),
          side: isSelected
              ? BorderSide(color: AppColors.actionPrimary, width: 1.5)
              : null,
          onTap: () => _handleSelectCard(item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _CategoryIconBadge(
                    category: item.category,
                    available: item.isAvailable,
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyLg.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          dist != null
                              ? '${item.category.shortLabel} · ${ChinaCoord.formatDistance(dist)}'
                              : item.category.label,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  _WaterStatusBadge(status: item.status),
                  const SizedBox(width: AppSpacing.s1),
                  IconButton(
                    key: Key('water-card-toggle-${item.id}'),
                    tooltip: item.isAvailable ? '快捷标为不可用' : '快捷标为可用',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(_quickToggleStatus(item)),
                    icon: Icon(
                      item.isAvailable
                          ? Icons.toggle_on
                          : Icons.toggle_off_outlined,
                      color: item.isAvailable
                          ? AppColors.safeText
                          : AppColors.alarmText,
                      size: 26,
                    ),
                  ),
                ],
              ),
              if (item.category == WaterSourceCategory.natural &&
                  item.intakeMethods.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  spacing: AppSpacing.s1,
                  runSpacing: AppSpacing.s1,
                  children: [
                    for (final m in item.intakeMethods)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSubtle,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          m.shortLabel,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (item.firstNoteLine.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s2),
                Text(
                  item.firstNoteLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 水源可用/不可用状态胶囊（遵循 StatusBadge 微圆点自适应高度规范）。
class _WaterStatusBadge extends StatelessWidget {
  final WaterSourceStatus status;

  const _WaterStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    final available = status == WaterSourceStatus.available;
    final fg = available ? AppColors.safeText : AppColors.onStatus;
    final bg = available ? AppColors.safeSurface : AppColors.alarm;
    final dot = available ? AppColors.safe : AppColors.onStatus;

    return Container(
      constraints: const BoxConstraints(minHeight: 26),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(
          color: available
              ? AppColors.safe.withValues(alpha: 0.28)
              : Colors.transparent,
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            status.label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryIconBadge extends StatelessWidget {
  final WaterSourceCategory category;
  final bool available;

  const _CategoryIconBadge({required this.category, required this.available});

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    final IconData icon;
    final Color color;
    switch (category) {
      case WaterSourceCategory.hydrant:
        icon = Icons.fire_hydrant_alt_outlined;
        color = available ? AppColors.noteInfo : AppColors.alarmText;
      case WaterSourceCategory.natural:
        icon = Icons.water_drop_outlined;
        color = available ? AppColors.safeText : AppColors.alarmText;
      case WaterSourceCategory.pumpConnector:
        icon = Icons.plumbing_outlined;
        color = available ? AppColors.cautionText : AppColors.alarmText;
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 20, color: color),
    );
  }
}

class _CrosshairReticle extends StatelessWidget {
  const _CrosshairReticle({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: CustomPaint(painter: _CrosshairPainter()),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    final strokePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()
      ..color = const Color(0xFFDC2626)
      ..style = PaintingStyle.fill;

    for (final paint in [shadowPaint, strokePaint]) {
      canvas.drawCircle(center, 14, paint);
      canvas.drawLine(
        Offset(center.dx - 20, center.dy),
        Offset(center.dx - 7, center.dy),
        paint,
      );
      canvas.drawLine(
        Offset(center.dx + 7, center.dy),
        Offset(center.dx + 20, center.dy),
        paint,
      );
      canvas.drawLine(
        Offset(center.dx, center.dy - 20),
        Offset(center.dx, center.dy - 7),
        paint,
      );
      canvas.drawLine(
        Offset(center.dx, center.dy + 7),
        Offset(center.dx, center.dy + 20),
        paint,
      );
    }
    canvas.drawCircle(center, 3.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AndroidWaterMapSurface extends StatefulWidget {
  final WaterSourcesMapSurfaceController surfaceController;
  final int backgroundColor;
  final VoidCallback onReady;
  final void Function(String type, Map<String, dynamic> data) onBridgeEvent;

  const _AndroidWaterMapSurface({
    required this.surfaceController,
    required this.backgroundColor,
    required this.onReady,
    required this.onBridgeEvent,
  });

  @override
  State<_AndroidWaterMapSurface> createState() =>
      _AndroidWaterMapSurfaceState();
}

class _AndroidWaterMapSurfaceState extends State<_AndroidWaterMapSurface> {
  MethodChannel? _channel;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    widget.surfaceController.detach();
    super.dispose();
  }

  void _onPlatformViewCreated(int viewId) {
    final channel = MethodChannel('watchdog/amap_view_$viewId');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onBridgeMessage') {
        final raw = call.arguments as String? ?? '';
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map) {
            final type = parsed['type']?.toString() ?? '';
            final data = parsed['data'] is Map
                ? Map<String, dynamic>.from(parsed['data'] as Map)
                : const <String, dynamic>{};
            widget.onBridgeEvent(type, data);
          }
        } catch (_) {}
      }
      return null;
    });

    widget.surfaceController.attach(
      onLoadHtml: (baseUrl, html) => channel.invokeMethod<void>('loadHtml', {
        'baseUrl': baseUrl,
        'html': html,
      }),
      onEvalJs: (script) =>
          channel.invokeMethod<void>('evalJs', {'script': script}),
    );
    widget.onReady();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return Center(
        child: Text(
          '当前平台暂不支持内置地图视图',
          style: AppTextStyles.bodyMd.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    return AndroidView(
      viewType: 'watchdog/amap_view',
      creationParams: {'backgroundColor': widget.backgroundColor},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}
