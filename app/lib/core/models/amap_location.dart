/// 水印相机使用的地址与天气（服务端代理高德，Key 不下发客户端）。
class AmapLocation {
  final double lat;
  final double lon;
  final String coordinate;

  const AmapLocation({
    required this.lat,
    required this.lon,
    this.coordinate = 'gcj02',
  });

  static AmapLocation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lon = (raw['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return AmapLocation(
      lat: lat,
      lon: lon,
      coordinate: raw['coordinate']?.toString() ?? 'gcj02',
    );
  }
}
