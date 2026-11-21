part of 'api_client.dart';

mixin _ToolsApiFacade on _ApiClientBase {
  // ---- RosterRepository (12) ----

  Future<List<Firefighter>> fetchFirefighters() => _roster.fetchFirefighters();

  Future<bool> addFirefighter(String name) => _roster.addFirefighter(name);

  Future<void> removeFirefighter(String id) => _roster.removeFirefighter(id);

  Future<List<Hotword>> fetchHotwords() => _roster.fetchHotwords();

  Future<void> addHotword(String word) => _roster.addHotword(word);

  Future<void> removeHotword(String id) => _roster.removeHotword(id);

  Future<List<Map<String, dynamic>>> fetchUnitStations({
    bool includeInactive = false,
  }) => _roster.fetchUnitStations(includeInactive: includeInactive);

  Future<Map<String, dynamic>> unitStationAccess() =>
      _roster.unitStationAccess();

  Future<Map<String, dynamic>> addUnitStation(String name) =>
      _roster.addUnitStation(name);

  Future<Map<String, dynamic>> updateUnitStation(
    String id,
    Map<String, dynamic> data,
  ) => _roster.updateUnitStation(id, data);

  Future<List<Station>> fetchStations() => _roster.fetchStations();

  Future<Station> createStation(String name) => _roster.createStation(name);

  // ---- MapRepository (5) ----

  Future<List<Map<String, dynamic>>> fetchMaps() => _map.fetchMaps();

  String mapTileUrl(String id, int z, int x, int y) =>
      _map.mapTileUrl(id, z, x, y);

  Map<String, String> mapTileHeaders() => _map.mapTileHeaders();

  Future<RouteTrafficInfo> fetchRouteTraffic({
    required String address,
    String? city,
    double? originLat,
    double? originLon,
    double? destLat,
    double? destLon,
    String? destName,
    String? destAdcode,
  }) => _map.fetchRouteTraffic(
    address: address,
    city: city,
    originLat: originLat,
    originLon: originLon,
    destLat: destLat,
    destLon: destLon,
    destName: destName,
    destAdcode: destAdcode,
  );

  Future<SceneMapBootstrap> fetchSceneMapBootstrap() =>
      _map.fetchSceneMapBootstrap();

  // ---- MediaRepository (1) ----

  Future<WeatherInfo> fetchWeather({
    required double lat,
    required double lon,
  }) => _media.fetchWeather(lat: lat, lon: lon);

  // ---- VideoRepository (4) ----

  Future<Map<String, dynamic>> videoResourceAccess() =>
      _video.videoResourceAccess();

  Future<List<VideoResource>> fetchVideoResources({
    bool includeInactive = false,
  }) => _video.fetchVideoResources(includeInactive: includeInactive);

  Future<VideoResource> addVideoResource({
    required String name,
    required String streamUrl,
    String description = '',
    bool active = true,
  }) => _video.addVideoResource(
    name: name,
    streamUrl: streamUrl,
    description: description,
    active: active,
  );

  Future<VideoResource> updateVideoResource(
    String id, {
    required int expectedVersion,
    String? name,
    String? streamUrl,
    String? description,
    bool? active,
  }) => _video.updateVideoResource(
    id,
    expectedVersion: expectedVersion,
    name: name,
    streamUrl: streamUrl,
    description: description,
    active: active,
  );

  // ---- KeySitesRepository (8) ----

  Future<Map<String, dynamic>> keySiteAccess() => _keySites.keySiteAccess();

  Future<Map<String, dynamic>> keySiteFilters() => _keySites.keySiteFilters();

  Future<Map<String, dynamic>> fetchKeySites({
    String search = '',
    String district = '',
    String type = '',
    int offset = 0,
  }) => _keySites.fetchKeySites(
    search: search,
    district: district,
    type: type,
    offset: offset,
  );

  Future<List<KeySiteSummary>> fetchRecentKeySites(List<String> ids) =>
      _keySites.fetchRecentKeySites(ids);

  Future<KeySiteVersion> fetchKeySite(
    String id, {
    int? version,
    String? incident,
  }) => _keySites.fetchKeySite(id, version: version, incident: incident);

  Future<Map<String, dynamic>> fetchIncidentKeySite(String id) =>
      _keySites.fetchIncidentKeySite(id);

  Future<Incident> changeIncidentKeySite(
    String id, {
    required int revision,
    required String operationId,
    KeySiteVersion? site,
  }) => _keySites.changeIncidentKeySite(
    id,
    revision: revision,
    operationId: operationId,
    site: site,
  );

  Future<Uint8List> fetchKeySiteImage(
    String siteId,
    int version,
    String attachmentId, {
    required String resource,
    String? incident,
  }) => _keySites.fetchKeySiteImage(
    siteId,
    version,
    attachmentId,
    resource: resource,
    incident: incident,
  );

  // ---- HazmatRepository (2) ----

  Future<HazmatSyncResult> syncHazmats({int since = 0, int limit = 500}) =>
      _hazmat.syncHazmats(since: since, limit: limit);

  Future<HazmatAiResult> generateHazmatAiCard(String query) =>
      _hazmat.generateHazmatAiCard(query);

  // ---- WaterSourcesRepository (5) ----

  Future<WaterSourceListResult> fetchWaterSources() =>
      _waterSources.fetchWaterSources();

  Future<WaterSource> createWaterSource({
    required WaterSourceCategory category,
    required String name,
    required double lat,
    required double lng,
    WaterSourceStatus status = WaterSourceStatus.available,
    List<WaterIntakeMethod> intakeMethods = const [],
    String note = '',
  }) => _waterSources.createWaterSource(
    category: category,
    name: name,
    lat: lat,
    lng: lng,
    status: status,
    intakeMethods: intakeMethods,
    note: note,
  );

  Future<WaterSource> updateWaterSource(
    String id, {
    WaterSourceCategory? category,
    String? name,
    double? lat,
    double? lng,
    WaterSourceStatus? status,
    List<WaterIntakeMethod>? intakeMethods,
    String? note,
  }) => _waterSources.updateWaterSource(
    id,
    category: category,
    name: name,
    lat: lat,
    lng: lng,
    status: status,
    intakeMethods: intakeMethods,
    note: note,
  );

  Future<int> deleteWaterSource(String id) =>
      _waterSources.deleteWaterSource(id);

  Future<WaterSource> restoreWaterSource(String id) =>
      _waterSources.restoreWaterSource(id);
}
