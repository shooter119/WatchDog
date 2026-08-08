import 'package:shared_preferences/shared_preferences.dart';

import 'scene_code.dart';

class Settings {
  static const _kServer = 'server_url';
  static const _kScene = 'scene_code';
  static const _kToken = 'api_token';
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
    };
  }

  /// 应用云端设置（按类型与合理范围校验），updatedAt 同步为本地修改时间戳
  static Future<void> applyFromServer(Map<String, dynamic> map, {required int updatedAt}) async {
    final sp = await SharedPreferences.getInstance();
    num? numOf(String k) => map[k] is num ? map[k] as num : null;
    bool? boolOf(String k) => map[k] is bool ? map[k] as bool : null;
    final vol = numOf('cylinder_vol_l');
    if (vol != null && vol > 0 && vol <= 20) await sp.setDouble(_kVolume, vol.toDouble());
    final full = numOf('full_pressure_mpa');
    if (full != null && full > 0 && full <= 40) await sp.setDouble(_kFullPressure, full.toDouble());
    final cons = numOf('consumption_lpm');
    if (cons != null && cons > 0 && cons <= 300) await sp.setDouble(_kConsumption, cons.toDouble());
    final warn = numOf('warn_min');
    if (warn != null && warn >= 0) await sp.setInt(_kWarn, warn.toInt());
    final alarm = numOf('alarm_min');
    if (alarm != null && alarm >= 0) await sp.setInt(_kAlarm, alarm.toInt());
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
    await sp.setInt(_kModifiedAt, updatedAt);
  }

  static Future<String> get serverUrl async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kServer) ?? 'https://bytevirt.meiyou.xyz:8443';
  }

  static Future<void> setServerUrl(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kServer, v);
  }

  static Future<String> get sceneCode async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getString(_kScene);
    if (v != null && v.isNotEmpty) return v;
    // 首次安装：自动分配一个随机水果场景码（与服务器任务码同一词表），
    // 已装设备保留原值（如旧版 default）不受影响
    final code = generateSceneCode();
    await sp.setString(_kScene, code);
    return code;
  }

  static Future<void> setSceneCode(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kScene, v);
  }

  static Future<String> get apiToken async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kToken) ?? 'watchdog-dev-token-2026';
  }

  static Future<void> setApiToken(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kToken, v);
  }

  /// 实名认证：真实姓名（空 = 匿名，日志发布显示"匿名"）
  static Future<String> get realName async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getString(_kRealName) ?? '').trim();
  }

  static Future<void> setRealName(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kRealName, v.trim());
  }

  static Future<double> get cylinderVolL async =>
      (await SharedPreferences.getInstance()).getDouble(_kVolume) ?? 6.8;

  static Future<void> setCylinderVolL(double v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kVolume, v);
  }

  static Future<double> get fullPressureMpa async =>
      (await SharedPreferences.getInstance()).getDouble(_kFullPressure) ?? 30;

  static Future<void> setFullPressureMpa(double v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kFullPressure, v);
  }

  static Future<double> get consumptionLpm async =>
      (await SharedPreferences.getInstance()).getDouble(_kConsumption) ?? 80;

  static Future<void> setConsumptionLpm(double v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kConsumption, v);
  }

  static Future<int> get warnMin async =>
      (await SharedPreferences.getInstance()).getInt(_kWarn) ?? 10;

  static Future<int> get alarmMin async =>
      (await SharedPreferences.getInstance()).getInt(_kAlarm) ?? 5;

  static Future<void> setThresholds(int warn, int alarm) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kWarn, warn);
    await sp.setInt(_kAlarm, alarm);
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
