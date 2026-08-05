import 'package:flutter/services.dart';

/// 屏幕常亮控制（Android 原生 FLAG_KEEP_SCREEN_ON，iOS 无操作）
class ScreenOn {
  static const MethodChannel _channel = MethodChannel('watchdog/screen');

  static Future<void> setKeepScreenOn(bool enable) async {
    try {
      await _channel.invokeMethod('keepScreenOn', {'enable': enable});
    } catch (_) {
      // 平台不支持（iOS/桌面）时静默忽略
    }
  }
}
