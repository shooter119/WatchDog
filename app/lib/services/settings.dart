import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_store.dart';

class Settings {
  static const maxCylinderVolL = 20.0;
  static const maxFullPressureMpa = 40.0;
  static const maxConsumptionLpm = 300.0;
  static const maxThresholdMin = 1440;

  /// 正式 APK 可通过 --dart-define=WATCHDOG_API_BASE_URL 覆盖 CloudBase HTTP 网关地址。
  static const defaultServerUrl = String.fromEnvironment(
    'WATCHDOG_API_BASE_URL',
    defaultValue:
        'https://watchdog-prod-d6gch930m378d9a16-1351750301.ap-shanghai.app.tcloudbase.com',
  );

  /// 端侧 ASR 模型与后端通过同一 CloudBase 网关分发，也可独立覆盖。
  static const defaultModelBaseUrl = String.fromEnvironment(
    'WATCHDOG_MODEL_BASE_URL',
    defaultValue: '$defaultServerUrl/models',
  );

  /// 非空时表示通过 dart-define 显式指定了独立模型源；为空时模型源在
  /// 下载时跟随运行时服务器地址，避免用户切换自部署 API 后仍访问旧网关。
  static const modelBaseUrlOverride = String.fromEnvironment(
    'WATCHDOG_MODEL_BASE_URL',
    defaultValue: '',
  );

  /// 正式包默认只访问编译时登记的服务地址；开发/测试或显式开启自定义服务时，
  /// 才允许使用其他受 HTTPS/本机规则保护的地址。
  static const allowCustomServer = bool.fromEnvironment(
    'WATCHDOG_ALLOW_CUSTOM_SERVER',
    defaultValue: false,
  );
  static const _deprecatedCloudRunServiceUrl =
      'https://watchdog-api-prod-294307-10-1351750301.sh.run.tcloudbase.com';
  static const _deprecatedCanaryServiceUrl =
      'https://watchdog-api-canary-294307-10-1351750301.sh.run.tcloudbase.com';
  static const _kServer = 'server_url';
  static const _kIncident = 'current_incident_id';
  static const _kToken = 'api_token';
  static const _kSessionToken = 'session_token';
  static const _kVolume = 'cylinder_vol_l';
  static const _kFullPressure = 'full_pressure_mpa';
  static const _kConsumption = 'consumption_lpm';
  static const _kWarn = 'warn_min';
  static const _kAlarm = 'alarm_min';
  static const _kTts = 'tts_enabled';
  static const _kAlarmSound = 'alarm_sound_enabled';
  static const _kKeepScreenOn = 'keep_screen_on';
  static const _kAsrCloud = 'asr_cloud_enabled';
  static const _kParseCloud = 'parse_cloud_enabled';
  static const _kKeepAlive = 'keep_alive_enabled';
  static const _kModifiedAt = 'settings_modified_at';
  static const _kRealName = 'real_name';
  static const _kUnitId = 'unit_id';
  static const _kUnitCode = 'unit_code';
  static const _kUnitName = 'unit_name';

  static bool _isLocalHost(String host) => const {
    'localhost',
    '127.0.0.1',
    '10.0.2.2',
    'test',
    'offline',
    'rec',
  }.contains(host);

  static bool _isSafeServerUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && !(scheme == 'http' && _isLocalHost(uri.host))) {
      return false;
    }
    if (kReleaseMode && !allowCustomServer) {
      final defaultUri = Uri.tryParse(_normalizeBaseUrl(defaultServerUrl));
      if (defaultUri == null || !_sameEndpoint(uri, defaultUri)) return false;
    }
    return true;
  }

  static bool _sameEndpoint(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port &&
      left.path == right.path;

  /// 模型下载地址是默认服务的 /models 子路径，正式包同样只信任编译时登记的模型源。
  static bool isSafeModelUrl(String value) {
    final trimmed = _normalizeBaseUrl(value.trim());
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && !(scheme == 'http' && _isLocalHost(uri.host))) {
      return false;
    }
    if (kReleaseMode && !allowCustomServer) {
      final defaultUri = Uri.tryParse(_normalizeBaseUrl(defaultModelBaseUrl));
      if (defaultUri == null || !_sameEndpoint(uri, defaultUri)) return false;
    }
    return true;
  }

  /// URL 校验供端侧模型下载和前台服务共用：生产地址必须 HTTPS，测试/本机地址
  /// 允许使用受限的本地 host。URL 不允许携带 query/fragment，避免拼接路径时
  /// 请求落到错误地址或把临时凭据带入后续请求。
  static bool isSafeHttpUrl(String value) => _isSafeServerUrl(value.trim());

  static String _normalizeBaseUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  /// 可同步到服务器的个人设置键（与后端 user_settings 白名单一致，snake_case）
  static const syncKeys = [
    'cylinder_vol_l',
    'full_pressure_mpa',
    'consumption_lpm',
    'warn_min',
    'alarm_min',
    'tts_enabled',
    'alarm_sound_enabled',
    'keep_screen_on',
    'asr_cloud_enabled',
    'parse_cloud_enabled',
    'real_name',
  ];

  /// 本地设置最近修改时间戳（0 = 从未显式保存过）
  static Future<int> get modifiedAt async =>
      (await SharedPreferences.getInstance()).getInt(_kModifiedAt) ?? 0;

  /// 标记本地设置被显式修改（保存设置时调用，作为云端同步的本地时间戳）
  static Future<void> markModified(int ts) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kModifiedAt, ts);
  }

  /// 收集全部可同步设置
  static Future<Map<String, dynamic>> toSyncMap() async {
    final sp = await SharedPreferences.getInstance();
    return {
      'cylinder_vol_l': sp.getDouble(_kVolume) ?? 6.8,
      'full_pressure_mpa': sp.getDouble(_kFullPressure) ?? 30,
      'consumption_lpm': sp.getDouble(_kConsumption) ?? 80,
      'warn_min': sp.getInt(_kWarn) ?? 10,
      'alarm_min': sp.getInt(_kAlarm) ?? 5,
      'tts_enabled': sp.getBool(_kTts) ?? true,
      'alarm_sound_enabled': sp.getBool(_kAlarmSound) ?? true,
      'keep_screen_on': sp.getBool(_kKeepScreenOn) ?? true,
      'asr_cloud_enabled': sp.getBool(_kAsrCloud) ?? true,
      'parse_cloud_enabled': sp.getBool(_kParseCloud) ?? true,
      'real_name': sp.getString(_kRealName) ?? '',
    };
  }

  /// 应用云端设置（按类型与合理范围校验），updatedAt 同步为本地修改时间戳
  static Future<void> applyFromServer(
    Map<String, dynamic> map, {
    required int updatedAt,
  }) async {
    final sp = await SharedPreferences.getInstance();
    num? numOf(String k) => map[k] is num ? map[k] as num : null;
    bool? boolOf(String k) => map[k] is bool ? map[k] as bool : null;
    final vol = numOf('cylinder_vol_l');
    if (vol != null && vol > 0 && vol <= maxCylinderVolL) {
      await sp.setDouble(_kVolume, vol.toDouble());
    }
    final full = numOf('full_pressure_mpa');
    if (full != null && full > 0 && full <= maxFullPressureMpa) {
      await sp.setDouble(_kFullPressure, full.toDouble());
    }
    final cons = numOf('consumption_lpm');
    if (cons != null && cons > 0 && cons <= maxConsumptionLpm) {
      await sp.setDouble(_kConsumption, cons.toDouble());
    }
    final currentWarn = sp.getInt(_kWarn) ?? 10;
    final currentAlarm = sp.getInt(_kAlarm) ?? 5;
    final warn = numOf('warn_min');
    final alarm = numOf('alarm_min');
    final nextWarn = warn != null && warn >= 0 && warn <= maxThresholdMin
        ? warn.toInt()
        : currentWarn;
    final nextAlarm = alarm != null && alarm >= 0 && alarm <= maxThresholdMin
        ? alarm.toInt()
        : currentAlarm;
    if (nextWarn >= nextAlarm) {
      await sp.setInt(_kWarn, nextWarn);
      await sp.setInt(_kAlarm, nextAlarm);
    }
    final tts = boolOf('tts_enabled');
    if (tts != null) await sp.setBool(_kTts, tts);
    final sound = boolOf('alarm_sound_enabled');
    if (sound != null) await sp.setBool(_kAlarmSound, sound);
    final keepOn = boolOf('keep_screen_on');
    if (keepOn != null) await sp.setBool(_kKeepScreenOn, keepOn);
    final asrCloud = boolOf('asr_cloud_enabled');
    if (asrCloud != null) await sp.setBool(_kAsrCloud, asrCloud);
    final parseCloud = boolOf('parse_cloud_enabled');
    if (parseCloud != null) await sp.setBool(_kParseCloud, parseCloud);
    final realName = map['real_name'];
    if (realName is String) {
      final trimmed = realName.trim();
      final value = trimmed.length > 32 ? trimmed.substring(0, 32) : trimmed;
      if (value.isEmpty) {
        await sp.remove(_kRealName);
      } else {
        await sp.setString(_kRealName, value);
      }
    }
    await sp.setInt(_kModifiedAt, updatedAt);
  }

  static Future<String> get serverUrl async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getString(_kServer);
    // 迁移之前版本自动写入的 CloudBase 云托管直连地址（包括 canary）。
    if (saved == _deprecatedCloudRunServiceUrl ||
        saved == _deprecatedCanaryServiceUrl) {
      await sp.setString(_kServer, defaultServerUrl);
      return defaultServerUrl;
    }
    final candidate = _normalizeBaseUrl(saved ?? defaultServerUrl);
    if (!_isSafeServerUrl(candidate)) {
      await sp.setString(_kServer, defaultServerUrl);
      return defaultServerUrl;
    }
    if (saved != candidate) await sp.setString(_kServer, candidate);
    return candidate;
  }

  static Future<void> setServerUrl(String v) async {
    final value = _normalizeBaseUrl(v);
    if (!isSafeHttpUrl(value)) {
      throw ArgumentError('服务器地址必须使用 HTTPS');
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kServer, value);
  }

  static Future<String> get currentIncidentId async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getString(_kIncident) ?? '').trim();
  }

  static Future<void> setCurrentIncidentId(String v) async {
    final sp = await SharedPreferences.getInstance();
    if (v.trim().isEmpty) {
      await sp.remove(_kIncident);
    } else {
      await sp.setString(_kIncident, v.trim());
    }
  }

  static Future<String> get apiToken async {
    // 不能把任何可用的生产/开发令牌编进 APK；首次安装由运维或设备配置
    // 注入访问令牌，优先保存在系统安全存储；空值会让受保护业务请求
    // 明确返回 401。
    return (await SecureStore.read(_kToken) ?? '').trim();
  }

  static Future<void> setApiToken(String v) async {
    final value = v.trim();
    if (value.isEmpty) {
      await SecureStore.delete(_kToken);
    } else {
      await SecureStore.write(_kToken, value);
    }
  }

  /// 当前单位认证后由服务端签发的短期会话令牌。
  /// 令牌只用于受保护 API 请求，不参与个人设置同步。
  static Future<String> get sessionToken async {
    return (await SecureStore.read(_kSessionToken) ?? '').trim();
  }

  static Future<void> setSessionToken(String v) async {
    final value = v.trim();
    if (value.isEmpty) {
      await SecureStore.delete(_kSessionToken);
    } else {
      await SecureStore.write(_kSessionToken, value);
    }
  }

  /// 实名认证：真实姓名（空 = 匿名，日志发布显示"匿名"）
  static Future<String> get realName async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getString(_kRealName) ?? '').trim();
  }

  static Future<void> setRealName(String v) async {
    final sp = await SharedPreferences.getInstance();
    final value = v.trim();
    if (value.isEmpty) {
      await sp.remove(_kRealName);
    } else {
      await sp.setString(_kRealName, value);
    }
  }

  /// 当前设备已通过认证的单位 ID；为空表示未完成单位认证。
  static Future<String> get unitId async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getString(_kUnitId) ?? '').trim();
  }

  static Future<void> setUnitId(String v) async {
    final sp = await SharedPreferences.getInstance();
    final value = v.trim();
    if (value.isEmpty) {
      await sp.remove(_kUnitId);
    } else {
      await sp.setString(_kUnitId, value);
    }
  }

  /// 当前设备已通过认证的单位验证码；为空表示尚未完成首次认证。
  static Future<String> get unitCode async {
    return (await SecureStore.read(_kUnitCode) ?? '').trim();
  }

  static Future<void> setUnitCode(String v) async {
    final value = v.trim();
    if (value.isEmpty) {
      await SecureStore.delete(_kUnitCode);
    } else {
      await SecureStore.write(_kUnitCode, value);
    }
  }

  static Future<String> get unitName async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getString(_kUnitName) ?? '').trim();
  }

  static Future<void> setUnitName(String v) async {
    final sp = await SharedPreferences.getInstance();
    final value = v.trim();
    if (value.isEmpty) {
      await sp.remove(_kUnitName);
    } else {
      await sp.setString(_kUnitName, value);
    }
  }

  static Future<double> get cylinderVolL async =>
      (await SharedPreferences.getInstance()).getDouble(_kVolume) ?? 6.8;

  static Future<void> setCylinderVolL(double v) async {
    validateCalculationParameters(cylinderVolL: v);
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kVolume, v);
  }

  static Future<double> get fullPressureMpa async =>
      (await SharedPreferences.getInstance()).getDouble(_kFullPressure) ?? 30;

  static Future<void> setFullPressureMpa(double v) async {
    validateCalculationParameters(fullPressureMpa: v);
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kFullPressure, v);
  }

  static Future<double> get consumptionLpm async =>
      (await SharedPreferences.getInstance()).getDouble(_kConsumption) ?? 80;

  static Future<void> setConsumptionLpm(double v) async {
    validateCalculationParameters(consumptionLpm: v);
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kConsumption, v);
  }

  static Future<int> get warnMin async =>
      (await SharedPreferences.getInstance()).getInt(_kWarn) ?? 10;

  static Future<int> get alarmMin async =>
      (await SharedPreferences.getInstance()).getInt(_kAlarm) ?? 5;

  static Future<void> setThresholds(int warn, int alarm) async {
    if (warn < 0 ||
        alarm < 0 ||
        warn > maxThresholdMin ||
        alarm > maxThresholdMin ||
        warn < alarm) {
      throw ArgumentError('提醒阈值必须满足 0 ≤ 报警阈值 ≤ 提醒阈值 ≤ 1440');
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kWarn, warn);
    await sp.setInt(_kAlarm, alarm);
  }

  /// 设置页保存前的统一计算参数校验；传入 null 的字段表示沿用已有值。
  static void validateCalculationParameters({
    double? cylinderVolL,
    double? fullPressureMpa,
    double? consumptionLpm,
  }) {
    if (cylinderVolL != null &&
        (!cylinderVolL.isFinite ||
            cylinderVolL <= 0 ||
            cylinderVolL > maxCylinderVolL)) {
      throw ArgumentError('气瓶容量必须在 0 到 $maxCylinderVolL L 之间');
    }
    if (fullPressureMpa != null &&
        (!fullPressureMpa.isFinite ||
            fullPressureMpa <= 0 ||
            fullPressureMpa > maxFullPressureMpa)) {
      throw ArgumentError('满压必须在 0 到 $maxFullPressureMpa MPa 之间');
    }
    if (consumptionLpm != null &&
        (!consumptionLpm.isFinite ||
            consumptionLpm <= 0 ||
            consumptionLpm > maxConsumptionLpm)) {
      throw ArgumentError('消耗率必须在 0 到 $maxConsumptionLpm L/min 之间');
    }
  }

  static Future<bool> get ttsEnabled async =>
      (await SharedPreferences.getInstance()).getBool(_kTts) ?? true;

  static Future<void> setTtsEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kTts, v);
  }

  static Future<bool> get alarmSoundEnabled async =>
      (await SharedPreferences.getInstance()).getBool(_kAlarmSound) ?? true;

  static Future<void> setAlarmSoundEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kAlarmSound, v);
  }

  static Future<bool> get keepScreenOn async =>
      (await SharedPreferences.getInstance()).getBool(_kKeepScreenOn) ?? true;

  static Future<void> setKeepScreenOn(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kKeepScreenOn, v);
  }

  /// 语音识别联网开关：开 = 云端优先、失败自动切本地；关 = 强制本地
  static Future<bool> get asrCloudEnabled async =>
      (await SharedPreferences.getInstance()).getBool(_kAsrCloud) ?? true;

  static Future<void> setAsrCloudEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kAsrCloud, v);
  }

  /// 语义解析联网开关：开 = 云端优先、失败自动切本地；关 = 强制本地
  static Future<bool> get parseCloudEnabled async =>
      (await SharedPreferences.getInstance()).getBool(_kParseCloud) ?? true;

  static Future<void> setParseCloudEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kParseCloud, v);
  }

  /// 后台值守模式：前台服务常驻，切后台/锁屏后轮询与报警不停
  static Future<bool> get keepAliveEnabled async =>
      (await SharedPreferences.getInstance()).getBool(_kKeepAlive) ?? false;

  static Future<void> setKeepAliveEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kKeepAlive, v);
  }
}
