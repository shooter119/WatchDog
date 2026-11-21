import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../services/camera_bridge.dart';
import '../../../services/china_coord.dart';
import '../../../services/screen_on.dart';
import '../data/models/water_source.dart';
import '../ui/water_sources_map_html.dart';
import '../ui/water_sources_map_surface.dart';
import 'water_sources_gateway.dart';

export '../data/models/water_source.dart';
export '../ui/water_sources_map_html.dart' show buildWaterSourcesMapHtml, waterSourceToJsPayload, waterSourcesSafeJsonEncode;
export '../ui/water_sources_map_surface.dart' show WaterSourcesMapBuilder, WaterSourcesMapState, WaterSourcesMapSurfaceController;
export 'water_sources_gateway.dart';

/// 大队级自建水源库状态容器。
class WaterSourcesStore extends ChangeNotifier {
  final WaterSourcesGateway gateway;
  final bool hasCustomMapBuilder;
  final WaterSourcesMapSurfaceController surfaceController;

  WaterSourcesStore({
    required this.gateway,
    this.hasCustomMapBuilder = false,
    WaterSourcesMapSurfaceController? surfaceController,
  }) : surfaceController =
           surfaceController ?? WaterSourcesMapSurfaceController();

  bool _loadingList = true;
  String? _listError;
  List<WaterSource> _items = const [];

  bool _loadingBootstrap = true;
  String? _bootstrapError;
  String? _scriptError;
  WaterMapBootstrap? _bootstrap;
  Timer? _ticketRenewTimer;
  int _ticketRenewAttempts = 0;

  WaterLocStatus _locStatus = WaterLocStatus.loading;
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
  bool _disposed = false;

  bool get loadingList => _loadingList;
  String? get listError => _listError;
  List<WaterSource> get items => _items;
  bool get loadingBootstrap => _loadingBootstrap;
  String? get bootstrapError => _bootstrapError;
  String? get scriptError => _scriptError;
  WaterLocStatus get locStatus => _locStatus;
  ({double lat, double lng, double accuracy})? get myGcj => _myGcj;
  WaterSourceCategory? get categoryFilter => _categoryFilter;
  bool get onlyAvailable => _onlyAvailable;
  String get searchQuery => _searchQuery;
  String? get selectedId => _selectedId;
  bool get pickingMode => _pickingMode;
  WaterSource? get editingCoordTarget => _editingCoordTarget;
  ({double lat, double lng})? get pickCenter => _pickCenter;

  WaterSourceSummary get summary => WaterSourceSummary.fromItems(_items);

  bool get canRenderMap =>
      hasCustomMapBuilder ||
      (_bootstrapError == null &&
          _scriptError == null &&
          _bootstrap != null &&
          _bootstrap!.configured &&
          _bootstrap!.jsKey.trim().isNotEmpty);

  WaterSource? get selectedItem =>
      _selectedId == null ? null : findById(_selectedId!);

  List<WaterSource> get filteredItems => filterAndSortWaterSources(
    items: _items,
    categoryFilter: _categoryFilter,
    onlyAvailable: _onlyAvailable,
    searchQuery: _searchQuery,
    myGcj: _myGcj,
  );

  double? distanceFor(WaterSource item) {
    final my = _myGcj;
    if (my == null) return null;
    return ChinaCoord.distanceMeters(my.lat, my.lng, item.lat, item.lng);
  }

  WaterSource? findById(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  String friendlyError(Object error) => error is ApiException
      ? error.message
      : error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  void _notify() { if (!_disposed) notifyListeners(); }
  void _eval(String js) => unawaited(surfaceController.evalJs(js));
  bool get _isAuthenticated => gateway.isAuthenticated?.call() ?? true;

  Future<void> initialize() async {
    final gen = ++_generation;
    _ticketRenewTimer?.cancel();
    if (_disposed) return;
    _loadingList = true;
    _listError = null;
    _loadingBootstrap = true;
    _bootstrapError = null;
    _scriptError = null;
    _locStatus = WaterLocStatus.loading;
    _htmlLoaded = false;
    _ticketRenewAttempts = 0;
    _notify();
    await Future.wait([
      _loadWaterSources(gen),
      _loadBootstrap(gen),
      _initLocation(gen),
    ]);
  }

  Future<void> refreshData() async {
    final gen = _generation;
    _loadingList = true;
    _listError = null;
    _notify();
    await Future.wait([_loadWaterSources(gen), _initLocation(gen)]);
  }

  Future<void> retryMapBootstrap() =>
      _loadBootstrap(_generation, forceReloadHtml: true);

  Future<void> retryLocation() => _initLocation(_generation);

  Future<void> openAppSettings() =>
      (gateway.openAppSettings ?? ScreenOn.openAppSettings)();

  Future<void> openLocationSettings() =>
      (gateway.openLocationSettings ?? CameraBridge.openLocationSettings)();

  Future<void> _loadWaterSources(int gen) async {
    final fetchFn = gateway.fetchWaterSources;
    if (fetchFn == null || !_isAuthenticated) {
      if (_disposed || gen != _generation) return;
      _loadingList = false;
      _listError = '请先完成单位登录后查看本单位水源库';
      return _notify();
    }
    try {
      final result = await fetchFn();
      if (_disposed || gen != _generation) return;
      _loadingList = false;
      _listError = null;
      _items = result.items;
      _notify();
      syncMapItems();
    } catch (e) {
      if (_disposed || gen != _generation) return;
      _loadingList = false;
      _listError = friendlyError(e);
      _notify();
    }
  }

  Future<void> _loadBootstrap(int gen, {bool forceReloadHtml = false}) async {
    final fetchFn = gateway.fetchMapBootstrap;
    if (fetchFn == null || !_isAuthenticated) {
      if (_disposed || gen != _generation) return;
      _loadingBootstrap = false;
      _bootstrap = null;
      _bootstrapError = '请先完成单位登录后加载高德底图';
      return _notify();
    }
    try {
      final boot = await fetchFn();
      if (_disposed || gen != _generation) return;
      final configured = boot.configured && boot.jsKey.trim().isNotEmpty;
      _loadingBootstrap = false;
      _bootstrap = boot;
      _bootstrapError = configured
          ? null
          : (boot.message ?? '服务端尚未配置高德底图服务，已切换为纯列表查水');
      _scriptError = null;
      if (forceReloadHtml) _htmlLoaded = false;
      _notify();
      if (configured) {
        _scheduleTicketRenewal(gen, boot);
        tryLoadHtmlIntoSurface();
      }
    } catch (e) {
      if (_disposed || gen != _generation) return;
      _loadingBootstrap = false;
      _bootstrapError = friendlyError(e);
      _notify();
    }
  }

  void _scheduleTicketRenewal(int gen, WaterMapBootstrap boot) {
    _ticketRenewTimer?.cancel();
    if (boot.expiresInMs <= 0) return;
    final delayMs = math.max(30000, boot.expiresInMs - 60000);
    _ticketRenewTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_disposed || gen != _generation) return;
      unawaited(_loadBootstrap(gen, forceReloadHtml: true));
    });
  }

  Future<void> _initLocation(int gen) async {
    try {
      final permitted = await (gateway.requestLocationPermission ??
          CameraBridge.requestLocationPermission)();
      if (_disposed || gen != _generation) return;
      if (!permitted) return _setLocFailed(WaterLocStatus.permissionDenied);
      final enabled = await (gateway.isLocationServiceEnabled ??
          CameraBridge.isLocationServiceEnabled)();
      if (_disposed || gen != _generation) return;
      if (!enabled) return _setLocFailed(WaterLocStatus.serviceDisabled);
      final fix = await (gateway.currentLocation ??
          () => CameraBridge.currentLocation(
            timeout: const Duration(seconds: 8),
          ))();
      if (_disposed || gen != _generation) return;
      if (fix == null) return _setLocFailed(WaterLocStatus.fixFailed);
      final gcj = ChinaCoord.wgs84ToGcj02(fix.lat, fix.lon);
      _locStatus = WaterLocStatus.ok;
      _myGcj = (lat: gcj.lat, lng: gcj.lon, accuracy: fix.accuracyMeters);
      _notify();
      _syncMyLocationToMap(autoCenter: true);
    } catch (_) {
      if (_disposed || gen != _generation) return;
      _setLocFailed(WaterLocStatus.fixFailed);
    }
  }

  void _setLocFailed(WaterLocStatus status) {
    _locStatus = status;
    _myGcj = null;
    _notify();
  }

  void markSurfaceReady() {
    _surfaceReady = true;
    tryLoadHtmlIntoSurface();
  }

  void tryLoadHtmlIntoSurface() {
    if (!_surfaceReady || _htmlLoaded) return;
    final boot = _bootstrap;
    if (boot == null || !boot.configured || boot.jsKey.trim().isEmpty) return;
    final apiBase = gateway.readBaseUrl?.call().trim().isNotEmpty == true
        ? gateway.readBaseUrl!().trim()
        : 'https://fireman119.xyz';
    final html = buildWaterSourcesMapHtml(
      jsKey: boot.jsKey,
      serviceHost: boot.resolveServiceHost(apiBase),
      initialMyGcj: _myGcj,
      initialCenter: _pickCenter ?? _lastMapCenter,
      initialZoom: _lastMapZoom,
      initialItems: filteredItems,
      selectedId: _selectedId,
    );
    _htmlLoaded = true;
    unawaited(surfaceController.loadHtml(apiBase, html));
  }

  void handleBridgeEvent(
    String type,
    Map<String, dynamic> data, {
    required void Function(String id) onMarkerClick,
  }) {
    if (_disposed) return;
    switch (type) {
      case 'mapReady':
        _ticketRenewAttempts = 0;
        syncMapItems();
        _syncMyLocationToMap(autoCenter: _lastMapCenter == null);
        if (_pickingMode) _eval(WaterMapJsCommands.setPickingMode(true));
      case 'markerClick':
        final id = data['id']?.toString() ?? '';
        if (id.isNotEmpty) onMarkerClick(id);
      case 'centerChanged':
        final lat = (data['lat'] as num?)?.toDouble();
        final lng = (data['lng'] as num?)?.toDouble();
        final zoom = (data['zoom'] as num?)?.toDouble();
        if (lat != null && lng != null && lat.isFinite && lng.isFinite) {
          _lastMapCenter = (lat: lat, lng: lng);
          if (zoom != null && zoom.isFinite) _lastMapZoom = zoom;
          if (_pickingMode) {
            _pickCenter = (lat: lat, lng: lng);
            _notify();
          }
        }
      case 'ticketExpired':
        if (_ticketRenewAttempts < 2) {
          _ticketRenewAttempts++;
          unawaited(_loadBootstrap(_generation, forceReloadHtml: true));
        } else {
          _scriptError = '地图票据已过期，请点击重试刷新底图';
          _notify();
        }
      case 'scriptError':
      case 'loadError':
        _scriptError = data['message']?.toString() ?? '底图加载失败，已切换为纯列表查水模式';
        _notify();
    }
  }

  void syncMapItems() {
    if (!_htmlLoaded && !hasCustomMapBuilder) return;
    _eval(WaterMapJsCommands.setItems(filteredItems, _selectedId));
  }

  void _syncMyLocationToMap({bool autoCenter = false}) {
    final my = _myGcj;
    if (my != null) _eval(WaterMapJsCommands.setMyLocation(my, autoCenter: autoCenter));
  }

  void centerOnMyLocation() {
    final my = _myGcj;
    if (my == null) {
      unawaited(_initLocation(_generation));
    } else {
      _eval(WaterMapJsCommands.centerOn(my.lng, my.lat, 17));
    }
  }

  void setCategoryFilter(WaterSourceCategory? category) {
    _categoryFilter = category;
    _notify();
    syncMapItems();
  }

  void setOnlyAvailable(bool value) {
    _onlyAvailable = value;
    _notify();
    syncMapItems();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    _notify();
    syncMapItems();
  }

  void selectItem(String? id, {bool focusMap = false}) {
    _selectedId = id;
    _notify();
    final item = (focusMap && id != null) ? findById(id) : null;
    if (item != null) return _eval(WaterMapJsCommands.focusItem(item));
    syncMapItems();
  }

  void startAddPicking() {
    final start = _myGcj != null
        ? (lat: _myGcj!.lat, lng: _myGcj!.lng)
        : (_lastMapCenter ??
              (_items.isNotEmpty
                  ? (lat: _items.first.lat, lng: _items.first.lng)
                  : (lat: 30.0, lng: 120.0)));
    _enterPicking(target: null, start: start, zoom: 17);
  }

  void startRepositionPicking(WaterSource target) => _enterPicking(
    target: target,
    start: (lat: target.lat, lng: target.lng),
    zoom: 18,
  );

  void _enterPicking({
    required WaterSource? target,
    required ({double lat, double lng}) start,
    required int zoom,
  }) {
    _pickingMode = true;
    _editingCoordTarget = target;
    _pickCenter = start;
    _notify();
    _eval(WaterMapJsCommands.centerOn(start.lng, start.lat, zoom));
    _eval(WaterMapJsCommands.setPickingMode(true));
  }

  void updatePickCenter(double lat, double lng) {
    _pickCenter = (lat: lat, lng: lng);
    _notify();
  }

  void cancelPicking() {
    _pickingMode = false;
    _editingCoordTarget = null;
    _notify();
    _eval(WaterMapJsCommands.setPickingMode(false));
  }

  void replaceLocalItem(WaterSource updated) {
    final idx = _items.indexWhere((e) => e.id == updated.id);
    if (idx >= 0) {
      final next = List<WaterSource>.from(_items);
      next[idx] = updated;
      _items = next;
    } else {
      _items = [updated, ..._items];
    }
    _selectedId = updated.id;
    _notify();
    syncMapItems();
  }

  Future<WaterSource> createWaterSource({
    required WaterSourceCategory category,
    required String name,
    required double lat,
    required double lng,
    required WaterSourceStatus status,
    required List<WaterIntakeMethod> intakeMethods,
    required String note,
  }) async {
    final fn = gateway.createWaterSource;
    if (fn == null) throw Exception('未连接服务端');
    final saved = await fn(
      category: category, name: name, lat: lat, lng: lng,
      status: status, intakeMethods: intakeMethods, note: note,
    );
    if (!_disposed) replaceLocalItem(saved);
    return saved;
  }

  Future<WaterSource> updateWaterSource(
    String id, {
    WaterSourceCategory? category,
    String? name,
    double? lat,
    double? lng,
    WaterSourceStatus? status,
    List<WaterIntakeMethod>? intakeMethods,
    String? note,
  }) async {
    final fn = gateway.updateWaterSource;
    if (fn == null) throw Exception('未连接服务端');
    final updated = await fn(
      id, category: category, name: name, lat: lat, lng: lng,
      status: status, intakeMethods: intakeMethods, note: note,
    );
    if (!_disposed) replaceLocalItem(updated);
    return updated;
  }

  Future<void> deleteWaterSource(String id) async {
    final fn = gateway.deleteWaterSource;
    if (fn == null) throw Exception('未连接服务端');
    await fn(id);
    if (_disposed) return;
    _items = _items.where((e) => e.id != id).toList(growable: false);
    if (_selectedId == id) _selectedId = null;
    _notify();
    syncMapItems();
  }

  Future<WaterSource> restoreWaterSource(String id) async {
    final fn = gateway.restoreWaterSource;
    if (fn == null) throw Exception('未连接服务端');
    final restored = await fn(id);
    if (!_disposed) replaceLocalItem(restored);
    return restored;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _ticketRenewTimer?.cancel();
    surfaceController.detach();
    super.dispose();
  }
}
