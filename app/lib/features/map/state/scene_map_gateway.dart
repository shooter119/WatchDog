import 'package:flutter/widgets.dart';

import '../../../services/camera_bridge.dart';
import '../data/models/route_traffic_info.dart';
import '../data/models/scene_map_bootstrap.dart';
import '../ui/scene_map_html_builder.dart';
import '../ui/scene_map_surface.dart';

/// 现场地图定位状态。
enum SceneMapLocStatus {
  unknown,
  ok,
  permissionDenied,
  serviceDisabled,
  fixFailed,
}

/// 现场地图所需的轻量警情上下文（隔离 `features/incident/`，零跨 Feature 依赖）。
@immutable
class SceneMapIncidentContext {
  final String id;
  final String displayName;
  final String effectiveLocation;
  final String administrativeArea;
  final double? officialLat;
  final double? officialLon;

  const SceneMapIncidentContext({
    required this.id,
    required this.displayName,
    this.effectiveLocation = '',
    this.administrativeArea = '',
    this.officialLat,
    this.officialLon,
  });
}

/// 现场地图逆地理地址返回值（零跨 Feature 依赖）。
@immutable
class SceneMapAddressResult {
  final String? address;

  const SceneMapAddressResult({this.address});

  static const empty = SceneMapAddressResult();
}

/// 测试可注入网关，隔离原生定位流、后端引导/逆地理/导航与外部跳转。
class SceneMapGateway {
  final Future<bool> Function() requestPermission;
  final Future<bool> Function() locationServiceEnabled;
  final Future<LocationFix?> Function() currentLocation;
  final Stream<LocationFix> Function() watchLocation;
  final Future<SceneMapBootstrap> Function() fetchMapBootstrap;
  final Future<SceneMapAddressResult> Function(double lat, double lon)
  fetchAddress;
  final Future<RouteTrafficInfo> Function({
    required String address,
    String? city,
    double? destLat,
    double? destLon,
  })
  fetchIncidentRouteInfo;
  final Future<Map<String, dynamic>> Function(String incidentId)?
  fetchIncidentDetails;
  final Future<void> Function() openAppSettings;
  final Future<void> Function() openLocationSettings;
  final Future<bool> Function(Uri uri) launchNavigation;
  final DateTime Function() now;
  final bool Function() isAuthenticated;
  final String Function() readBaseUrl;
  final SceneMapIncidentContext? Function() readCurrentIncident;
  final Widget Function(
    BuildContext context,
    SceneMapSurfaceController surfaceController,
    void Function(String eventType, Map<String, dynamic> data) onBridgeEvent,
  )?
  mapSurfaceBuilder;

  const SceneMapGateway({
    required this.requestPermission,
    required this.locationServiceEnabled,
    required this.currentLocation,
    required this.watchLocation,
    required this.fetchMapBootstrap,
    required this.fetchAddress,
    required this.fetchIncidentRouteInfo,
    this.fetchIncidentDetails,
    required this.openAppSettings,
    required this.openLocationSettings,
    required this.launchNavigation,
    required this.now,
    required this.isAuthenticated,
    required this.readBaseUrl,
    required this.readCurrentIncident,
    this.mapSurfaceBuilder,
  });
}

/// 解析高德导航 Web 与 Android 原生 URI。
({Uri? webUri, Uri? nativeUri}) resolveSceneMapNavigationUris({
  required RouteTrafficInfo? info,
  required ({double lat, double lon})? coord,
  required String destName,
}) {
  final trimmed = destName.trim();
  final webUri =
      info?.navigationUri ??
      (coord == null
          ? null
          : Uri.https('uri.amap.com', '/navigation', {
              'to': trimmed.isNotEmpty
                  ? '${coord.lon.toStringAsFixed(6)},${coord.lat.toStringAsFixed(6)},$trimmed'
                  : '${coord.lon.toStringAsFixed(6)},${coord.lat.toStringAsFixed(6)}',
              'mode': 'car',
              'src': 'watchdog',
              'callnative': '1',
            }));
  final nativeUri =
      info?.nativeAndroidNavigationUri ??
      (coord == null
          ? null
          : Uri(
              scheme: 'androidamap',
              host: 'navi',
              queryParameters: {
                'sourceApplication': 'watchdog',
                'poiname': trimmed.isNotEmpty ? trimmed : '事发地点',
                'lat': coord.lat.toStringAsFixed(6),
                'lon': coord.lon.toStringAsFixed(6),
                'dev': '0',
                'style': '2',
              },
            ));
  return (webUri: webUri, nativeUri: nativeUri);
}

/// 构建现场地图 WebView JS 桥接调用脚本。
abstract final class SceneMapJsCommands {
  static String setLayerMode(SceneMapLayerMode mode) =>
      'window.watchdogMap && window.watchdogMap.setLayerMode(${sceneMapSafeJsonEncode(mode.jsValue)});';

  static String setTrafficEnabled(bool enabled) =>
      'window.watchdogMap && window.watchdogMap.setTrafficEnabled($enabled);';

  static String updateMyLocation(
    ({double lat, double lon}) gcj,
    LocationFix fix,
    bool followMe,
  ) {
    final acc = fix.accuracyMeters > 0 ? fix.accuracyMeters : 0.0;
    final bearing = fix.bearingDegrees == null
        ? 'null'
        : fix.bearingDegrees!.toStringAsFixed(1);
    return 'window.watchdogMap && window.watchdogMap.updateMyLocation(${gcj.lon}, ${gcj.lat}, $acc, $bearing, $followMe);';
  }

  static String updateIncident(({double lat, double lon}) gcj, String title) =>
      'window.watchdogMap && window.watchdogMap.updateIncident(${gcj.lon}, ${gcj.lat}, ${sceneMapSafeJsonEncode(title)});';

  static const String focusMyLocation =
      'window.watchdogMap && window.watchdogMap.focusMyLocation();';

  static const String focusIncident =
      'window.watchdogMap && window.watchdogMap.focusIncident();';

  static const String fitBoth =
      'window.watchdogMap && window.watchdogMap.fitBoth();';
}
