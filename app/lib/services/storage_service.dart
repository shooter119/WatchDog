import 'package:flutter/services.dart';

/// 设备存储空间能力：仅用于下载前提示和系统设置跳转。
/// 平台不支持或通道异常时返回 null/false，由上层继续使用既有网络路径。
class StorageService {
  static const MethodChannel _channel = MethodChannel('watchdog/storage');

  static Future<int?> availableBytes() async {
    try {
      final value = await _channel
          .invokeMethod<Object?>('availableBytes')
          .timeout(const Duration(seconds: 2));
      if (value is num && value.isFinite && value >= 0) return value.toInt();
    } catch (_) {
      // 桌面/测试环境没有 Android 存储通道时不阻断下载流程。
    }
    return null;
  }

  static Future<bool> openStorageSettings() async {
    try {
      final result = await _channel
          .invokeMethod<Object?>('openStorageSettings')
          .timeout(const Duration(seconds: 2));
      return result != false;
    } catch (_) {
      return false;
    }
  }
}
