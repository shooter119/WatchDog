import '../../../core/network/network.dart';
import 'models/route_traffic_info.dart';
import 'models/scene_map_bootstrap.dart';

class MapRepository {
  final ApiHttpTransport _transport;

  const MapRepository(this._transport);

  Future<List<Map<String, dynamic>>> fetchMaps() async {
    final response = await _transport.client
        .get(_transport.uri('/api/maps'), headers: _transport.headers)
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(response, fallback: '获取地图失败');
    if (response.statusCode != 200) {
      throw _transport.apiException(response, body: body, fallback: '获取地图失败');
    }
    return (body['maps'] as List).cast<Map<String, dynamic>>();
  }

  // URLs contain no credentials. Each tile uses the current session headers.
  String mapTileUrl(String id, int z, int x, int y) => _transport
      .uri('/api/maps/${Uri.encodeComponent(id)}/tiles/$z/$x/$y.jpg')
      .replace(queryParameters: {'unit': _transport.config.unitId})
      .toString();

  Map<String, String> mapTileHeaders() => _transport.headers;

  /// 查询赴事发地沿途路况、耗时、途经道路及现场天气与风向风力。
  Future<RouteTrafficInfo> fetchRouteTraffic({
    required String address,
    String? city,
    double? originLat,
    double? originLon,
    double? destLat,
    double? destLon,
    String? destName,
    String? destAdcode,
  }) async {
    final trimmedCity = city?.trim() ?? '';
    final query = <String, String>{
      'address': address.trim(),
      if (trimmedCity.isNotEmpty) 'city': trimmedCity,
      if (originLat != null && originLon != null) ...{
        'originLat': originLat.toStringAsFixed(6),
        'originLon': originLon.toStringAsFixed(6),
      },
      if (destLat != null && destLon != null) ...{
        'destLat': destLat.toStringAsFixed(6),
        'destLon': destLon.toStringAsFixed(6),
      },
      if ((destName?.trim() ?? '').isNotEmpty) 'destName': destName!.trim(),
      if ((destAdcode?.trim() ?? '').isNotEmpty)
        'destAdcode': destAdcode!.trim(),
    };
    final uri = _transport
        .uri('/api/route-traffic')
        .replace(queryParameters: query);
    final res = await _transport.client
        .get(uri, headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '路况查询失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '路况查询失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '路况查询响应格式异常');
    }
    return RouteTrafficInfo.fromJson(Map<String, dynamic>.from(body));
  }

  /// 获取首页「现场地图」高德 JS API 2.0 引导配置与短期安全代理票据。
  Future<SceneMapBootstrap> fetchSceneMapBootstrap() async {
    final res = await _transport.client
        .get(
          _transport.uri('/api/scene-map/bootstrap'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取现场地图配置失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取现场地图配置失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '现场地图配置响应格式异常');
    }
    return SceneMapBootstrap.fromJson(Map<String, dynamic>.from(body));
  }
}
