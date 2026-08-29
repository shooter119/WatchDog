import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 认证令牌的系统安全存储封装。
///
/// 正式 Android 运行时使用 Keystore-backed storage。测试环境或安全存储
/// 插件不可用时不再把凭据回退写入 SharedPreferences；旧版本留下的明文
/// 副本只有在成功迁移到 Keystore 并删除副本后才会被返回。非原生测试环境
/// 仍使用兼容存储，因为 widget 测试没有 Android Keystore 通道。
class SecureStore {
  SecureStore._();

  static const _storage = FlutterSecureStorage();

  // WatchDog 当前发布 Android；Flutter widget 测试在桌面 VM 上运行时没有
  // 原生插件通道，直接走兼容存储，避免每次设置保存都等待一次必然失败的
  // MethodChannel 调用。真实 Android/iOS 设备仍优先使用系统安全存储。
  static final bool _nativeStorageAvailable =
      Platform.isAndroid || Platform.isIOS;

  static Future<String?> read(String key) async {
    if (!_nativeStorageAvailable) return _readLegacy(key);
    try {
      final value = await _storage.read(key: key);
      if (value != null) return value;

      // 一次性迁移旧版本明文令牌。只有写入 Keystore 且删除旧副本都成功后
      // 才返回令牌；迁移失败时宁可让调用方重新认证，也不继续使用明文副本。
      final sp = await SharedPreferences.getInstance();
      final legacy = sp.getString(key);
      if (legacy == null) return null;
      try {
        await _storage.write(key: key, value: legacy);
        final removed = await sp.remove(key);
        if (!removed && sp.containsKey(key)) return null;
      } catch (_) {
        return null;
      }
      return legacy;
    } catch (_) {
      // Native storage 出错时 fail closed，绝不读取明文回退。
      return null;
    }
  }

  static Future<void> write(String key, String value) async {
    if (!_nativeStorageAvailable) return _writeLegacy(key, value);
    try {
      await _storage.write(key: key, value: value);
      final sp = await SharedPreferences.getInstance();
      final removed = await sp.remove(key);
      if (!removed && sp.containsKey(key)) {
        throw StateError('旧版明文凭据清理失败，未完成保存');
      }
    } catch (_) {
      // Native storage 出错时 fail closed，不把令牌写入新的明文副本。
      throw StateError('系统安全存储不可用，未保存认证凭据');
    }
  }

  static Future<void> delete(String key) async {
    if (!_nativeStorageAvailable) return _deleteLegacy(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    await _deleteLegacy(key);
  }

  static Future<String?> _readLegacy(String key) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(key);
  }

  static Future<void> _writeLegacy(String key, String value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(key, value);
  }

  static Future<void> _deleteLegacy(String key) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(key);
  }
}
