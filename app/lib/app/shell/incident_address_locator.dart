import '../../features/incident/ui/sheets/incident_basic_info_sheet.dart';
import '../../features/media/data/models/weather_info.dart';
import '../../services/camera_bridge.dart';
import '../../services/china_coord.dart';
import '../../state/app_controller.dart';

/// 基于手机定位与服务端逆地理编码（`/api/weather`）一键获取当前事发地点与精确 GCJ-02 坐标。
///
/// 坐标转换统一在端侧使用 [ChinaCoord.wgs84ToGcj02] 直接基于实时 WGS-84 经纬度计算，
/// 与「现场地图」当前位置蓝点保持完全一致的坐标基准，避免服务端网格缓存复用与离线/降级回退引发漂移。
Future<IncidentLocatedAddress> locateCurrentIncidentAddress(
  AppController controller,
) async {
  if (!CameraBridge.isSupported) {
    return const IncidentLocatedAddress(
      errorMessage: '当前设备暂不支持系统定位，请手动输入地点',
    );
  }

  var granted = await CameraBridge.hasLocationPermission();
  if (!granted) {
    granted = await CameraBridge.requestLocationPermission();
  }
  if (!granted) {
    return const IncidentLocatedAddress(
      errorMessage: '未授予位置权限，请在系统设置中开启或手动输入',
    );
  }

  final serviceEnabled = await CameraBridge.isLocationServiceEnabled();
  if (!serviceEnabled) {
    return const IncidentLocatedAddress(
      errorMessage: '系统定位服务未开启，请开启后重试或手动输入',
    );
  }

  final fix = await CameraBridge.currentLocation(
    timeout: const Duration(seconds: 8),
  );
  if (fix == null) {
    return const IncidentLocatedAddress(
      errorMessage: '定位超时或信号较弱，请稍后重试或手动输入',
    );
  }

  WeatherInfo? weather;
  final api = controller.api;
  if (api != null) {
    try {
      weather = await api.fetchWeather(lat: fix.lat, lon: fix.lon);
    } catch (_) {
      weather = null;
    }
  }

  final rawAddress = (weather?.address ?? '').trim();
  final address =
      rawAddress.isNotEmpty ? rawAddress : (weather?.city ?? '').trim();
  final gcj = ChinaCoord.wgs84ToGcj02(fix.lat, fix.lon);
  final lat = gcj.lat;
  final lon = gcj.lon;

  if (address.isNotEmpty) {
    return IncidentLocatedAddress(
      address: address,
      latitude: lat,
      longitude: lon,
    );
  }

  return IncidentLocatedAddress(
    latitude: lat,
    longitude: lon,
    errorMessage: api == null
        ? '已获取当前坐标，未连接服务时请手动输入事发地点'
        : '已获取当前坐标，但暂未解析出街道名称，请手动补充地点',
  );
}
