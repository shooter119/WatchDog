import 'dart:convert';

import '../../../core/network/network.dart';

class SettingsRepository {
  final ApiHttpTransport _transport;

  const SettingsRepository(this._transport);

  /// 拉取云端用户设置（按 X-Device-Id 识别用户，按场景隔离）
  /// 返回 { settings: {...}, updatedAt: 服务器最近修改时间（无记录为 0） }
  Future<Map<String, dynamic>> fetchUserSettings() async {
    final res = await _transport.client
        .get(_transport.uri('/api/user-settings'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取云端设置失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取云端设置失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '云端设置响应格式异常');
    }
    return {
      'settings': body['settings'] is Map<String, dynamic>
          ? body['settings'] as Map<String, dynamic>
          : <String, dynamic>{},
      'updatedAt': (body['updated_at'] as num?)?.toInt() ?? 0,
    };
  }

  /// 推送本地用户设置到云端（全量覆盖白名单键）
  Future<void> pushUserSettings(Map<String, dynamic> settings) async {
    final res = await _transport.client
        .put(
          _transport.uri('/api/user-settings'),
          headers: _transport.headers,
          body: jsonEncode({'settings': settings}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '同步设置失败');
      throw _transport.apiException(res, body: body, fallback: '同步设置失败');
    }
  }

  Future<Map<String, dynamic>> fetchProfile() async {
    final res = await _transport.client
        .get(_transport.uri('/api/profile'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取实名信息失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取实名信息失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '实名信息响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> saveProfile(String realName) async {
    final res = await _transport.client
        .put(
          _transport.uri('/api/profile'),
          headers: _transport.headers,
          body: jsonEncode({'real_name': realName}),
        )
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '保存实名失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '保存实名失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '实名信息响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }
}
