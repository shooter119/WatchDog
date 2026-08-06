import 'package:flutter/services.dart';

/// 屏幕常亮控制（Android 原生 FLAG_KEEP_SCREEN_ON，iOS 无操作）
class ScreenOn {
  static const MethodChannel _channel = MethodChannel('watchdog/screen');

  static Future<void> setKeepScreenOn(bool enable) async {
    try {
      // 超时保护：无平台响应（如测试环境/异常）时 2s 后放弃，避免挂起保存链路
      await _channel
          .invokeMethod('keepScreenOn', {'enable': enable})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 平台不支持（iOS/桌面）或超时时静默忽略
    }
  }

  /// 打开本应用的系统设置页（权限被拒后的恢复路径，Android 原生实现）
  static Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod('openAppSettings').timeout(const Duration(seconds: 2));
    } catch (_) {
      // 平台不支持时静默忽略
    }
  }
}
