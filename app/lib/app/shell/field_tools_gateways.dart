import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/api_client.dart';
import '../../features/hazmat/state/hazmat_store.dart';
import '../../features/key_sites/ui/key_site_gate.dart';
import '../../features/map/ui/orthomap_page.dart';
import '../../features/map/ui/route_traffic_page.dart';
import '../../features/map/ui/scene_map_page.dart';
import '../../features/media/data/models/weather_info.dart';
import '../../features/media/state/media_gateway.dart';
import '../../features/video/data/models/video_resource.dart';
import '../../features/video/data/video_repository.dart';
import '../../features/water_sources/ui/water_sources_page.dart';
import '../../services/camera_bridge.dart';
import '../../services/local_media_store.dart';
import '../../services/location_share_service.dart';
import '../../services/media_capture_service.dart';
import '../../services/screen_on.dart';
import '../../state/app_controller.dart';

/// M3e 现场工具域网关构建器（将 `AppController` / `ApiClient` 适配为各 Feature 独立网关）。
///
/// 零旧 `pages/`、`theme/`、`widgets/` 依赖。
class FieldToolsGateways {
  const FieldToolsGateways(this.controller);

  final AppController controller;

  bool get isAuthenticated =>
      !controller.isGuest &&
      !controller.needsAuthentication &&
      controller.api != null;

  ApiClient _requireApi([String message = '未连接服务端']) {
    final api = controller.api;
    if (api == null) throw Exception(message);
    return api;
  }

  ApiClient _requireKeySiteApi() {
    final api = controller.api;
    if (api == null) {
      throw ApiException(
        '认证已失效，请重新加入单位后查阅',
        statusCode: 401,
        code: 'KEY_SITE_AUTH_REQUIRED',
      );
    }
    return api;
  }

  Future<Map<String, dynamic>> fetchIncidentDetailsById(
    String incidentId,
  ) async {
    final api = controller.api;
    if (api == null) return const <String, dynamic>{};
    if (api.incidentId == incidentId) return api.fetchIncidentDetails();
    final scoped = api.forIncident(incidentId);
    try {
      return await scoped.fetchIncidentDetails();
    } finally {
      scoped.dispose();
    }
  }

  SceneMapIncidentContext? readSceneMapIncidentContext() {
    final inc = controller.currentIncident;
    if (inc == null) return null;
    return SceneMapIncidentContext(
      id: inc.id,
      displayName: inc.displayName,
      effectiveLocation: inc.effectiveLocation,
      administrativeArea:
          (inc.info['administrative_area']?.toString() ?? '').trim(),
      officialLat: double.tryParse(inc.info['latitude']?.toString() ?? ''),
      officialLon: double.tryParse(inc.info['longitude']?.toString() ?? ''),
    );
  }

  RouteTrafficIncidentContext? readRouteIncidentContext() {
    final inc = controller.currentIncident;
    if (inc == null) return null;
    return RouteTrafficIncidentContext(
      id: inc.id,
      displayName: inc.displayName,
      location: inc.effectiveLocation,
      administrativeArea:
          (inc.info['administrative_area']?.toString() ?? '').trim(),
      officialLat: double.tryParse(inc.info['latitude']?.toString() ?? ''),
      officialLon: double.tryParse(inc.info['longitude']?.toString() ?? ''),
    );
  }

  KeySiteGateway buildKeySiteGateway() {
    return KeySiteGateway(
      accessListenable: controller,
      canReadKeySites: () => controller.canReadKeySites,
      readProtectedDataEpoch: () => controller.protectedDataEpoch,
      readServerBaseUrl: () => controller.api?.baseUrl ?? '',
      readClientIdentity: () => controller.api,
      recents: controller.keySiteRecents,
      keySiteAccess: () => _requireKeySiteApi().keySiteAccess(),
      keySiteFilters: () => _requireKeySiteApi().keySiteFilters(),
      fetchKeySites: ({
        String search = '',
        String district = '',
        String type = '',
        int offset = 0,
      }) => _requireKeySiteApi().fetchKeySites(
        search: search,
        district: district,
        type: type,
        offset: offset,
      ),
      fetchRecentKeySites: (List<String> ids) =>
          _requireKeySiteApi().fetchRecentKeySites(ids),
      fetchKeySite: (String id, {int? version, String? incident}) =>
          _requireKeySiteApi().fetchKeySite(
            id,
            version: version,
            incident: incident,
          ),
      fetchKeySiteImage: (
        String siteId,
        int version,
        String attachmentId, {
        required String resource,
        String? incident,
      }) => _requireKeySiteApi().fetchKeySiteImage(
        siteId,
        version,
        attachmentId,
        resource: resource,
        incident: incident,
      ),
    );
  }

  HazmatGateway? buildHazmatGateway() {
    final api = controller.api;
    if (api == null || controller.isGuest) return null;
    return HazmatGateway(
      syncHazmats: ({int since = 0, int limit = 500}) =>
          api.syncHazmats(since: since, limit: limit),
      generateHazmatAiCard: api.generateHazmatAiCard,
    );
  }

  MediaGateway buildMediaGateway() {
    return MediaGateway(
      readCurrentIncident: () {
        final inc = controller.currentIncident;
        if (inc == null) return null;
        return MediaIncidentRef(
          id: inc.id,
          number: inc.number,
          title: inc.title ?? '',
        );
      },
      fetchWeather: ({required double lat, required double lon}) async =>
          controller.api?.fetchWeather(lat: lat, lon: lon) ?? WeatherInfo.empty,
      isObservationApiAvailable: () =>
          controller.api != null && !controller.isGuest,
      createIncidentObservation: ({
        required String incidentId,
        required String transcript,
        required String sourceType,
        required int capturedAt,
        required String mediaRef,
      }) async {
        final scoped = _requireApi().forIncident(incidentId);
        try {
          await scoped.createIncidentObservation(
            transcript: transcript,
            sourceType: sourceType,
            capturedAt: capturedAt,
            mediaRef: mediaRef,
          );
        } finally {
          scoped.dispose();
        }
      },
      refreshIncidentData: controller.refreshIncidentData,
      deriveMedia: (
        LocalMedia media, {
        void Function(String stage)? onProgress,
        void Function(String message)? onError,
        bool Function()? isCancelled,
      }) => MediaCaptureService.derive(
        media,
        controller: controller,
        onProgress: onProgress,
        onError: onError,
        isCancelled: isCancelled,
      ),
      transcribeMediaAudio: controller.transcribeMediaAudio,
      isAsrCloudEnabled: () => controller.asrCloudEnabled,
    );
  }

  SceneMapGateway buildSceneMapGateway() {
    return SceneMapGateway(
      requestPermission: CameraBridge.requestLocationPermission,
      locationServiceEnabled: CameraBridge.isLocationServiceEnabled,
      currentLocation: () =>
          CameraBridge.currentLocation(timeout: const Duration(seconds: 6)),
      watchLocation: CameraBridge.watchLocation,
      fetchMapBootstrap: () => _requireApi().fetchSceneMapBootstrap(),
      fetchAddress: (double lat, double lon) async {
        final api = controller.api;
        if (api == null) return SceneMapAddressResult.empty;
        final weather = await api.fetchWeather(lat: lat, lon: lon);
        return SceneMapAddressResult(address: weather.address);
      },
      fetchIncidentRouteInfo: ({
        required String address,
        String? city,
        double? destLat,
        double? destLon,
      }) => _requireApi().fetchRouteTraffic(
        address: address,
        city: city,
        destLat: destLat,
        destLon: destLon,
      ),
      fetchIncidentDetails: fetchIncidentDetailsById,
      openAppSettings: ScreenOn.openAppSettings,
      openLocationSettings: CameraBridge.openLocationSettings,
      launchNavigation: (Uri uri) =>
          launchUrl(uri, mode: LaunchMode.externalApplication),
      now: DateTime.now,
      isAuthenticated: () => isAuthenticated,
      readBaseUrl: () => controller.api?.baseUrl ?? '',
      readCurrentIncident: readSceneMapIncidentContext,
    );
  }

  OrthomapGateway buildOrthomapGateway() {
    return OrthomapGateway(
      fetchMaps: () => _requireApi().fetchMaps(),
      mapTileUrl: (String id, int z, int x, int y) =>
          controller.api?.mapTileUrl(id, z, x, y) ?? '',
      mapTileHeaders: () =>
          controller.api?.mapTileHeaders() ?? const <String, String>{},
      isAuthenticated: () => isAuthenticated,
      sessionTokenHash: () => controller.api?.sessionToken.hashCode ?? 0,
      authListenable: controller,
    );
  }

  RouteTrafficGateway buildRouteTrafficGateway() {
    return RouteTrafficGateway(
      requestPermission: CameraBridge.requestLocationPermission,
      locationServiceEnabled: CameraBridge.isLocationServiceEnabled,
      currentLocation: CameraBridge.currentLocation,
      fetchRouteTraffic: ({
        required String address,
        String? city,
        double? originLat,
        double? originLon,
        double? destLat,
        double? destLon,
        String? destName,
        String? destAdcode,
      }) => _requireApi().fetchRouteTraffic(
        address: address,
        city: city,
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
        destName: destName,
        destAdcode: destAdcode,
      ),
      fetchIncidentDetails: fetchIncidentDetailsById,
      openAppSettings: ScreenOn.openAppSettings,
      openLocationSettings: CameraBridge.openLocationSettings,
      copyText: (String text) => Clipboard.setData(ClipboardData(text: text)),
      launchNavigation: (Uri uri) =>
          launchUrl(uri, mode: LaunchMode.externalApplication),
    );
  }

  LocationShareGateway buildLocationShareGateway() {
    return LocationShareGateway(
      requestPermission: CameraBridge.requestLocationPermission,
      locationServiceEnabled: CameraBridge.isLocationServiceEnabled,
      currentLocation: CameraBridge.currentLocation,
      fetchWeather: (double lat, double lon) async =>
          controller.api?.fetchWeather(lat: lat, lon: lon) ?? WeatherInfo.empty,
      openAppSettings: ScreenOn.openAppSettings,
      openLocationSettings: CameraBridge.openLocationSettings,
      copyText: (String text) => Clipboard.setData(ClipboardData(text: text)),
      shareText: (String text) async {
        await LocationShareService.shareText(text);
      },
      now: DateTime.now,
    );
  }

  WaterSourcesGateway buildWaterSourcesGateway() {
    return WaterSourcesGateway(
      requestLocationPermission: CameraBridge.requestLocationPermission,
      isLocationServiceEnabled: CameraBridge.isLocationServiceEnabled,
      currentLocation: CameraBridge.currentLocation,
      openAppSettings: ScreenOn.openAppSettings,
      openLocationSettings: CameraBridge.openLocationSettings,
      fetchMapBootstrap: () async {
        final b = await _requireApi().fetchSceneMapBootstrap();
        return WaterMapBootstrap(
          configured: b.configured,
          jsKey: b.jsKey,
          hasSecurityProxy: b.hasSecurityProxy,
          proxyPath: b.proxyPath,
          expiresInMs: b.expiresInMs,
          code: b.code,
          message: b.message,
        );
      },
      fetchWaterSources: () => _requireApi().fetchWaterSources(),
      createWaterSource: ({
        required WaterSourceCategory category,
        required String name,
        required double lat,
        required double lng,
        WaterSourceStatus status = WaterSourceStatus.available,
        List<WaterIntakeMethod> intakeMethods = const <WaterIntakeMethod>[],
        String note = '',
      }) => _requireApi().createWaterSource(
        category: category,
        name: name,
        lat: lat,
        lng: lng,
        status: status,
        intakeMethods: intakeMethods,
        note: note,
      ),
      updateWaterSource: (
        String id, {
        WaterSourceCategory? category,
        String? name,
        double? lat,
        double? lng,
        WaterSourceStatus? status,
        List<WaterIntakeMethod>? intakeMethods,
        String? note,
      }) => _requireApi().updateWaterSource(
        id,
        category: category,
        name: name,
        lat: lat,
        lng: lng,
        status: status,
        intakeMethods: intakeMethods,
        note: note,
      ),
      deleteWaterSource: (String id) => _requireApi().deleteWaterSource(id),
      restoreWaterSource: (String id) => _requireApi().restoreWaterSource(id),
      isAuthenticated: () => isAuthenticated,
      readBaseUrl: () => controller.api?.baseUrl ?? '',
    );
  }

  VideoRepository? buildVideoRepository() {
    final api = controller.api;
    return api == null ? null : _ApiVideoRepository(api);
  }
}

class _ApiVideoRepository implements VideoRepository {
  const _ApiVideoRepository(this._api);

  final ApiClient _api;

  @override
  Future<Map<String, dynamic>> videoResourceAccess() =>
      _api.videoResourceAccess();

  @override
  Future<List<VideoResource>> fetchVideoResources({
    bool includeInactive = false,
  }) => _api.fetchVideoResources(includeInactive: includeInactive);

  @override
  Future<VideoResource> addVideoResource({
    required String name,
    required String streamUrl,
    String description = '',
    bool active = true,
  }) => _api.addVideoResource(
    name: name,
    streamUrl: streamUrl,
    description: description,
    active: active,
  );

  @override
  Future<VideoResource> updateVideoResource(
    String id, {
    required int expectedVersion,
    String? name,
    String? streamUrl,
    String? description,
    bool? active,
  }) => _api.updateVideoResource(
    id,
    expectedVersion: expectedVersion,
    name: name,
    streamUrl: streamUrl,
    description: description,
    active: active,
  );
}
