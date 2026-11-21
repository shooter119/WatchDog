import 'package:flutter/foundation.dart';

import '../../../services/camera_bridge.dart';
import '../../../services/china_coord.dart';
import '../data/models/water_source.dart';
import '../ui/water_sources_map_html.dart';

/// 周边水源高德底图引导配置（本 Feature 自包含，零跨 Feature 依赖）。
@immutable
class WaterMapBootstrap {
  final bool configured;
  final String jsKey;
  final bool hasSecurityProxy;
  final String? proxyPath;
  final int expiresInMs;
  final String? code;
  final String? message;

  const WaterMapBootstrap({
    required this.configured,
    this.jsKey = '',
    this.hasSecurityProxy = false,
    this.proxyPath,
    this.expiresInMs = 0,
    this.code,
    this.message,
  });

  String? resolveServiceHost(String baseUrl) {
    final path = proxyPath?.trim() ?? '';
    if (!hasSecurityProxy || path.isEmpty) return null;
    final cleanBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$cleanBase$path');
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri.toString();
  }
}

/// 周边水源本机定位状态。
enum WaterLocStatus { loading, ok, permissionDenied, serviceDisabled, fixFailed }

/// 可选外部依赖网关，便于单测隔离原生定位与网络请求。
class WaterSourcesGateway {
  final Future<bool> Function()? requestLocationPermission;
  final Future<bool> Function()? isLocationServiceEnabled;
  final Future<LocationFix?> Function()? currentLocation;
  final Future<void> Function()? openAppSettings;
  final Future<void> Function()? openLocationSettings;
  final Future<WaterMapBootstrap> Function()? fetchMapBootstrap;
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
  final bool Function()? isAuthenticated;
  final String Function()? readBaseUrl;

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
    this.isAuthenticated,
    this.readBaseUrl,
  });
}

/// 按类别、可用态、关键词筛选并按距离升序（无定位时按更新时间降序）排序。
List<WaterSource> filterAndSortWaterSources({
  required List<WaterSource> items,
  required WaterSourceCategory? categoryFilter,
  required bool onlyAvailable,
  required String searchQuery,
  required ({double lat, double lng, double accuracy})? myGcj,
}) {
  final q = searchQuery.trim().toLowerCase();
  final filtered = items
      .where((item) {
        if (categoryFilter != null && item.category != categoryFilter) {
          return false;
        }
        if (onlyAvailable && !item.isAvailable) return false;
        if (q.isNotEmpty) {
          final inName = item.name.toLowerCase().contains(q);
          final inNote = item.note.toLowerCase().contains(q);
          if (!inName && !inNote) return false;
        }
        return true;
      })
      .toList(growable: true);

  filtered.sort((a, b) {
    if (myGcj != null) {
      final da = ChinaCoord.distanceMeters(myGcj.lat, myGcj.lng, a.lat, a.lng);
      final db = ChinaCoord.distanceMeters(myGcj.lat, myGcj.lng, b.lat, b.lng);
      final cmp = da.compareTo(db);
      if (cmp != 0) return cmp;
    }
    final timeCmp = b.updatedAt.compareTo(a.updatedAt);
    if (timeCmp != 0) return timeCmp;
    return a.name.compareTo(b.name);
  });
  return filtered;
}

/// 周边水源高德地图 WebView JS 桥接调用脚本。
abstract final class WaterMapJsCommands {
  static String setItems(List<WaterSource> items, String? selectedId) {
    final payload = waterSourcesSafeJsonEncode(
      items.map(waterSourceToJsPayload).toList(growable: false),
    );
    final selected = waterSourcesSafeJsonEncode(selectedId);
    return 'window.watchdogWaterMap && window.watchdogWaterMap.setItems($payload, $selected);';
  }

  static String setMyLocation(
    ({double lat, double lng, double accuracy}) my, {
    required bool autoCenter,
  }) {
    final payload = waterSourcesSafeJsonEncode({
      'lat': my.lat,
      'lng': my.lng,
      'accuracy': my.accuracy,
    });
    return 'window.watchdogWaterMap && window.watchdogWaterMap.setMyLocation($payload, ${autoCenter ? 'true' : 'false'});';
  }

  static String focusItem(WaterSource item) =>
      'window.watchdogWaterMap && window.watchdogWaterMap.focusItem(${waterSourcesSafeJsonEncode(item.id)}, ${item.lng}, ${item.lat});';

  static String centerOn(double lng, double lat, int zoom) =>
      'window.watchdogWaterMap && window.watchdogWaterMap.centerOn($lng, $lat, $zoom);';

  static String setPickingMode(bool enabled) =>
      'window.watchdogWaterMap && window.watchdogWaterMap.setPickingMode(${enabled ? 'true' : 'false'});';
}
