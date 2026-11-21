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

  static final RegExp _provincePrefixRe = RegExp(
    r'^[^\s\d,，。、;；:：\-/()（）省市县区]{1,12}?(?:特别行政区|自治区|省)',
  );
  static final RegExp _cityPrefixRe = RegExp(
    r'^[^\s\d,，。、;；:：\-/()（）省市县区]{1,12}?(?:自治州|地区|市(?!区)|盟)',
  );
  static final RegExp _countyPrefixRe = RegExp(
    r'^[^\s\d,，。、;；:：\-/()（）省县区]{1,12}?(?:自治县|自治旗|县|(?<![小社园发景港校库营厂矿])区|旗)',
  );
  static final RegExp _leadingTrimPunctRe = RegExp(
    r'^[\s,，、.。;；:：\-–—/|·]+',
  );

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

  /// 计算从 `(lat1, lon1)` 到 `(lat2, lon2)` 的球面初始方位角，归一化返回 `[0, 360)` 度。
  ///
  /// 正北为 `0°`、正东 `90°`、正南 `180°`、正西 `270°`；任一坐标非有限值或两点重合时返回 `0.0`。
  static double bearingDegrees(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    if (!lat1.isFinite || !lon1.isFinite || !lat2.isFinite || !lon2.isFinite) {
      return 0.0;
    }
    if ((lat2 - lat1).abs() < 1e-9 && (lon2 - lon1).abs() < 1e-9) {
      return 0.0;
    }
    final phi1 = _degToRad(lat1);
    final phi2 = _degToRad(lat2);
    final dLambda = _degToRad(lon2 - lon1);
    final y = math.sin(dLambda) * math.cos(phi2);
    final x =
        math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
    var deg = math.atan2(y, x) * 180.0 / _pi;
    deg = ((deg % 360.0) + 360.0) % 360.0;
    if (!deg.isFinite || deg >= 360.0 || deg == 0.0) return 0.0;
    return deg;
  }

  /// 将方位角归一化到 `[0, 360)` 并按每 45° 扇区映射为 8 方位中文名称。
  static String cardinalDirection(double bearingDeg) {
    if (!bearingDeg.isFinite) return '正北';
    const directions = [
      '正北',
      '东北',
      '正东',
      '东南',
      '正南',
      '西南',
      '正西',
      '西北',
    ];
    var normalized = ((bearingDeg % 360.0) + 360.0) % 360.0;
    if (normalized >= 360.0) normalized = 0.0;
    final index = ((normalized + 22.5) ~/ 45.0) % 8;
    return directions[index];
  }

  /// 生成地图气泡紧凑短标签：折叠空白、尝试剥离前置省市区县层级并按上限截断。
  ///
  /// 示例：`'示例省示例市示例县示范路88号'` → `'示范路88号'`。
  static String shortenPinLabel(String raw, {int maxChars = 18}) {
    var text = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceFirst(_leadingTrimPunctRe, '').trim();
    if (text.isEmpty || maxChars <= 0) return '';

    for (final prefixRe in [
      _provincePrefixRe,
      _cityPrefixRe,
      _countyPrefixRe,
    ]) {
      final match = prefixRe.firstMatch(text);
      if (match != null) {
        final rest = text
            .substring(match.end)
            .replaceFirst(_leadingTrimPunctRe, '')
            .trim();
        if (rest.length >= 2) {
          text = rest;
        }
      }
    }

    if (text.length <= maxChars) return text;
    if (maxChars == 1) return text.substring(0, 1);
    return '${text.substring(0, maxChars - 1)}…';
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
