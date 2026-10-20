import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 拍摄界面方向。两种模式最终都输出横版 16:9；
/// 区别是竖屏模式会从竖幅画面中裁切出横向取景区。
enum CameraCaptureOrientation {
  landscape('landscape'),
  portrait('portrait');

  const CameraCaptureOrientation(this.storageValue);

  final String storageValue;

  static CameraCaptureOrientation fromStorage(Object? value) {
    return value == portrait.storageValue ? portrait : landscape;
  }
}

/// 水印相机参数。
///
/// 刻意与账号信息解耦：单位抬头、拍摄部门都可以单独填写，不强制绑定登录身份。
/// 这样同一台手机借给不同班组、或临时支援时，改一个设置就能拍出正确的水印，
/// 不必退出登录再重新认证。
class WatermarkSettings {
  /// 水印顶部蓝色条的抬头（如「浙江总队衢州市消防救援支队」）。为空时回落到单位名称。
  final String unitTitle;

  /// 底部蓝条「拍摄单位」（如「衢州市消防救援支队通信保障分队」）。
  final String department;

  /// 拍摄人；留空则水印不显示这一行。
  final String actorName;

  final bool showTime;
  final bool showWeather;
  final bool showLocation;
  final bool showCoordinates;
  final bool showLogo;
  final CameraCaptureOrientation captureOrientation;

  const WatermarkSettings({
    this.unitTitle = '',
    this.department = '',
    this.actorName = '',
    this.showTime = true,
    this.showWeather = true,
    this.showLocation = true,
    this.showCoordinates = true,
    this.showLogo = true,
    this.captureOrientation = CameraCaptureOrientation.landscape,
  });

  static const WatermarkSettings defaults = WatermarkSettings();

  WatermarkSettings copyWith({
    String? unitTitle,
    String? department,
    String? actorName,
    bool? showTime,
    bool? showWeather,
    bool? showLocation,
    bool? showCoordinates,
    bool? showLogo,
    CameraCaptureOrientation? captureOrientation,
  }) {
    return WatermarkSettings(
      unitTitle: unitTitle ?? this.unitTitle,
      department: department ?? this.department,
      actorName: actorName ?? this.actorName,
      showTime: showTime ?? this.showTime,
      showWeather: showWeather ?? this.showWeather,
      showLocation: showLocation ?? this.showLocation,
      showCoordinates: showCoordinates ?? this.showCoordinates,
      showLogo: showLogo ?? this.showLogo,
      captureOrientation: captureOrientation ?? this.captureOrientation,
    );
  }

  Map<String, Object?> toJson() => {
    'unitTitle': unitTitle,
    'department': department,
    'actorName': actorName,
    'showTime': showTime,
    'showWeather': showWeather,
    'showLocation': showLocation,
    'showCoordinates': showCoordinates,
    'showLogo': showLogo,
    'captureOrientation': captureOrientation.storageValue,
  };

  static WatermarkSettings fromJson(Map<String, dynamic> json) {
    bool flag(String key) => json[key] is bool ? json[key] as bool : true;
    String text(String key) => (json[key] as String?)?.trim() ?? '';
    return WatermarkSettings(
      unitTitle: text('unitTitle'),
      department: text('department'),
      actorName: text('actorName'),
      showTime: flag('showTime'),
      showWeather: flag('showWeather'),
      showLocation: flag('showLocation'),
      showCoordinates: flag('showCoordinates'),
      showLogo: flag('showLogo'),
      captureOrientation: CameraCaptureOrientation.fromStorage(
        json['captureOrientation'],
      ),
    );
  }

  static const String _key = 'watermark_settings_v1';

  static Future<WatermarkSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return defaults;
      return WatermarkSettings.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return defaults;
    }
  }

  static Future<void> save(WatermarkSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }
}
