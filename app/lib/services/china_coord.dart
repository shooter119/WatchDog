import 'dart:math' as math;

/// 中国标准坐标系（WGS-84 ↔ GCJ-02 火星坐标）端侧零延迟转换与测距工具。
///
/// Android 系统 `LocationManager` 返回 WGS-84 坐标，而高德 JS API 2.0 地图底图使用
/// GCJ-02 坐标；不经转换在中国境内会产生 300~500 米左右的系统性偏移。
class ChinaCoord {
  ChinaCoord._();

  static const double _pi = math.pi;
  static const double _axis = 6378245.0; // Krasovsky 1940 长半轴
  static const double _ee = 0.00669342162296594323; // 第一偏心率平方
  static const double _earthRadiusM = 6371000.0;

  /// 判断坐标是否大致处于中国陆地/近海范围内；境外不做偏移。
  static bool isOutOfChina(double lat, double lon) {
    if (!lat.isFinite || !lon.isFinite) return true;
    return lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271;
  }

  /// 将 GPS/北斗输出的 WGS-84 坐标转换为高德地图使用的 GCJ-02 坐标（精度 < 0.5m）。
  static ({double lat, double lon}) wgs84ToGcj02(double lat, double lon) {
    if (isOutOfChina(lat, lon)) {
      return (lat: lat, lon: lon);
    }
    var dLat = _transformLat(lon - 105.0, lat - 35.0);
    var dLon = _transformLon(lon - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * _pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_axis * (1 - _ee)) / (magic * sqrtMagic) * _pi);
    dLon = (dLon * 180.0) / (_axis / sqrtMagic * math.cos(radLat) * _pi);
    return (lat: lat + dLat, lon: lon + dLon);
  }

  /// 计算两组坐标之间的 Haversine 球面直线距离（单位：米）。
  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final radLat1 = _degToRad(lat1);
    final radLat2 = _degToRad(lat2);
    final sinLat = math.sin(dLat / 2);
    final sinLon = math.sin(dLon / 2);
    final a =
        sinLat * sinLat +
        math.cos(radLat1) * math.cos(radLat2) * sinLon * sinLon;
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return _earthRadiusM * c;
  }

  /// 格式化直线距离：< 1km 显示整数米，>= 1km 显示 1 位小数公里。
  static String formatDistance(double meters) {
    if (!meters.isFinite || meters < 0) return '--';
    if (meters < 1000) {
      return '${meters.round()} m';
    }
    final km = meters / 1000.0;
    return '${km.toStringAsFixed(1)} km';
  }

  static double _degToRad(double deg) => deg * _pi / 180.0;

  static double _transformLat(double x, double y) {
    var ret =
        -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret +=
        (20.0 * math.sin(6.0 * x * _pi) + 20.0 * math.sin(2.0 * x * _pi)) *
        2.0 /
        3.0;
    ret +=
        (20.0 * math.sin(y * _pi) + 40.0 * math.sin(y / 3.0 * _pi)) * 2.0 / 3.0;
    ret +=
        (160.0 * math.sin(y / 12.0 * _pi) + 320 * math.sin(y * _pi / 30.0)) *
        2.0 /
        3.0;
    return ret;
  }

  static double _transformLon(double x, double y) {
    var ret =
        300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret +=
        (20.0 * math.sin(6.0 * x * _pi) + 20.0 * math.sin(2.0 * x * _pi)) *
        2.0 /
        3.0;
    ret +=
        (20.0 * math.sin(x * _pi) + 40.0 * math.sin(x / 3.0 * _pi)) * 2.0 / 3.0;
    ret +=
        (150.0 * math.sin(x / 12.0 * _pi) + 300.0 * math.sin(x / 30.0 * _pi)) *
        2.0 /
        3.0;
    return ret;
  }
}
