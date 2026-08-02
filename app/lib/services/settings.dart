import 'package:shared_preferences/shared_preferences.dart';

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

  static Future<String> get serverUrl async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kServer) ?? 'http://192.168.1.100:3000';
  }

  static Future<void> setServerUrl(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kServer, v);
  }

  static Future<String> get sceneCode async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kScene) ?? 'default';
  }

  static Future<void> setSceneCode(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kScene, v);
  }

  static Future<String> get apiToken async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kToken) ?? '';
  }

  static Future<void> setApiToken(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kToken, v);
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
      (await SharedPreferences.getInstance()).getDouble(_kConsumption) ?? 40;

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
}
