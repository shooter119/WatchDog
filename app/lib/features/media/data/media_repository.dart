import '../../../core/network/network.dart';
import 'models/weather_info.dart';

class MediaRepository {
  final ApiHttpTransport _transport;

  const MediaRepository(this._transport);

  /// 水印相机的地址与天气。服务端按网格与城市缓存，客户端每次拍摄前查询一次即可。
  /// 上游不可用时返回降级结果而不是抛错：拍摄流程不能因此中断。
  Future<WeatherInfo> fetchWeather({
    required double lat,
    required double lon,
  }) async {
    try {
      final query =
          'lat=${lat.toStringAsFixed(5)}&lon=${lon.toStringAsFixed(5)}';
      final res = await _transport.client
          .get(
            _transport.uri('/api/weather?$query'),
            headers: _transport.headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 503) return WeatherInfo.empty;
      final body = _transport.decodeJson(res, fallback: '获取地址天气失败');
      if (res.statusCode != 200 || body is! Map) return WeatherInfo.empty;
      return WeatherInfo.fromJson(body.cast<String, dynamic>());
    } catch (_) {
      return WeatherInfo.empty;
    }
  }
}
