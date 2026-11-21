import 'dart:convert';
import 'dart:io';

import '../../../core/network/network.dart';
import 'models/admin_login.dart';
import 'models/unit_member.dart';

class AuthRepository {
  final ApiHttpTransport _transport;

  const AuthRepository(this._transport);

  Future<AdminCapability?> fetchAdminCapability() async {
    final data = await _transport.requestJsonMap(
      '/api/admin-app/capability',
      fallback: '资料加载失败',
      timeout: const Duration(seconds: 20),
      requireStatus200: true,
    );
    return data['member'] is Map
        ? AdminCapability.fromJson(
            Map<String, dynamic>.from(data['member'] as Map),
          )
        : null;
  }

  Future<void> confirmAdminLogin(
    AdminLoginCode code, {
    bool cancel = false,
  }) async {
    final response = await _transport.client
        .post(
          _transport.uri('/api/admin-app/confirm'),
          headers: _transport.headers,
          body: jsonEncode({
            'id': code.id,
            'scan': code.scan,
            'cancel': cancel,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(response, fallback: '网页登录确认失败');
    if (response.statusCode != 200) {
      throw _transport.apiException(
        response,
        body: body,
        fallback: '网页登录确认失败',
      );
    }
  }

  Future<Map<String, dynamic>> fetchAuthIdentity() async {
    final res = await _transport.client
        .get(_transport.uri('/api/auth/identity'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取成员身份失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取成员身份失败');
    }
    return Map<String, dynamic>.from(body as Map);
  }

  Future<List<Map<String, dynamic>>> fetchLoginDevices() async {
    final res = await _transport.client
        .get(_transport.uri('/api/auth/devices'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取登录设备失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取登录设备失败');
    }
    return (body as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> revokeLoginDevice(String? id) async {
    final path = id == null
        ? 'revoke-others'
        : '${Uri.encodeComponent(id)}/revoke';
    final res = await _transport.client
        .post(
          _transport.uri('/api/auth/devices/$path'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '退出设备失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '退出设备失败');
    }
  }

  /// 首次启动认证：校验单位验证码并登记本机实名。
  /// 认证请求不把验证码放入请求头，避免失败前被当成已认证业务请求。
  Future<Map<String, dynamic>> verifyUnit({
    required String unitName,
    required String unitCode,
    required String realName,
  }) async {
    final uri = _transport.uri('/api/auth/verify');
    final apiToken = _transport.config.apiToken;
    final deviceId = _transport.config.deviceId;
    final res = await _transport.withTransientRetry(
      (client) => client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
          if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
        },
        body: jsonEncode({
          'unit_name': unitName,
          'unit_code': unitCode,
          'real_name': realName,
          'device_name':
              '${Platform.isAndroid ? 'Android 设备' : Platform.operatingSystem}${deviceId.isEmpty ? '' : ' · ${deviceId.substring(deviceId.length > 6 ? deviceId.length - 6 : 0)}'}',
          'platform': Platform.operatingSystem,
        }),
      ),
      timeout: const Duration(seconds: 12),
      host: uri.host,
    );
    final body = _transport.decodeJson(res, fallback: '单位认证失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '单位认证失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '单位认证响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  /// 申请加入单位：免登录提交入队申请（状态为 pending 等待站长审批）
  Future<Map<String, dynamic>> applyUnitMembership({
    required String unitName,
    required String unitCode,
    required String realName,
    String? stationName,
    String? phone,
    String? applyReason,
  }) async {
    final uri = _transport.uri('/api/auth/apply');
    final apiToken = _transport.config.apiToken;
    final deviceId = _transport.config.deviceId;
    final res = await _transport.withTransientRetry(
      (client) => client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
          if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
        },
        body: jsonEncode({
          'unit_name': unitName.trim(),
          'unit_code': unitCode.trim(),
          'real_name': realName.trim(),
          if (stationName != null && stationName.trim().isNotEmpty)
            'station_name': stationName.trim(),
          if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
          if (applyReason != null && applyReason.trim().isNotEmpty)
            'apply_reason': applyReason.trim(),
        }),
      ),
      timeout: const Duration(seconds: 12),
      host: uri.host,
    );
    final body = _transport.decodeJson(res, fallback: '提交申请失败');
    if (res.statusCode != 202 && res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '提交申请失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '申请响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  Future<List<UnitMember>> fetchUnitMembers() async {
    final res = await _transport.client.get(
      _transport.uri('/api/unit-members'),
      headers: _transport.headers,
    );
    final body = _transport.decodeJson(res, fallback: '获取成员列表失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取成员列表失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '成员列表响应格式异常');
    }
    return body
        .whereType<Map<String, dynamic>>()
        .map(UnitMember.fromJson)
        .toList();
  }

  Future<bool> fetchMemberReviewCapability() async {
    final res = await _transport.client
        .get(
          _transport.uri('/api/unit-members/capability'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 12));
    final body = _transport.decodeJson(res, fallback: '获取审批权限失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取审批权限失败');
    }
    if (body is! Map || body['can_review_members'] is! bool) {
      throw _transport.responseShapeException(res, '审批权限响应格式异常');
    }
    return body['can_review_members'] as bool;
  }

  Future<List<Map<String, dynamic>>> fetchMemberReviewHistory({
    int offset = 0,
  }) async {
    final res = await _transport.client
        .get(
          _transport.uri('/api/unit-members/review-history?offset=$offset'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 12));
    final body = _transport.decodeJson(res, fallback: '获取审批记录失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取审批记录失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '审批记录响应格式异常');
    }
    return body.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Future<List<UnitMember>> fetchPendingMembers() async {
    final res = await _transport.client
        .get(
          _transport.uri('/api/unit-members/pending'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 12));
    final body = _transport.decodeJson(res, fallback: '获取待审批成员列表失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取待审批成员列表失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '待审列表响应格式异常');
    }
    return body
        .whereType<Map<String, dynamic>>()
        .map(
          (row) => UnitMember.fromJson({
            ...row,
            'created_at': row['updated_at'] ?? row['created_at'],
          }),
        )
        .toList();
  }

  Future<UnitMember> approveMember(String memberId) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/unit-members/$memberId/approve'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 12));
    final body = _transport.decodeJson(res, fallback: '审批成员失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '审批成员失败');
    }
    if (body is! Map || body['member'] is! Map) {
      throw _transport.responseShapeException(res, '审批响应格式异常');
    }
    return UnitMember.fromJson(
      Map<String, dynamic>.from(body['member'] as Map),
    );
  }

  Future<UnitMember> rejectMember(String memberId, {String? reason}) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/unit-members/$memberId/reject'),
          headers: _transport.headers,
          body: jsonEncode({
            if (reason != null && reason.trim().isNotEmpty)
              'reason': reason.trim(),
          }),
        )
        .timeout(const Duration(seconds: 12));
    final body = _transport.decodeJson(res, fallback: '驳回成员申请失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '驳回成员申请失败');
    }
    if (body is! Map || body['member'] is! Map) {
      throw _transport.responseShapeException(res, '驳回响应格式异常');
    }
    return UnitMember.fromJson(
      Map<String, dynamic>.from(body['member'] as Map),
    );
  }

  Future<UnitMember> addUnitMember({
    required String realName,
    String role = 'member',
    String? stationName,
    String? phone,
  }) async {
    final res = await _transport.client.post(
      _transport.uri('/api/unit-members'),
      headers: _transport.headers,
      body: jsonEncode({
        'real_name': realName.trim(),
        'role': role,
        if (stationName != null && stationName.trim().isNotEmpty)
          'station_name': stationName.trim(),
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      }),
    );
    final body = _transport.decodeJson(res, fallback: '添加成员失败');
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '添加成员失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '添加成员响应格式异常');
    }
    return UnitMember.fromJson(Map<String, dynamic>.from(body));
  }

  Future<UnitMember> updateUnitMember(
    String memberId, {
    String? role,
    String? status,
    String? stationName,
    String? phone,
  }) async {
    final res = await _transport.client.patch(
      _transport.uri('/api/unit-members/$memberId'),
      headers: _transport.headers,
      body: jsonEncode({
        if (role != null) 'role': role,
        if (status != null) 'status': status,
        if (stationName != null) 'station_name': stationName.trim(),
        if (phone != null) 'phone': phone.trim(),
      }),
    );
    final body = _transport.decodeJson(res, fallback: '更新成员失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '更新成员失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '更新成员响应格式异常');
    }
    return UnitMember.fromJson(Map<String, dynamic>.from(body));
  }

  Future<Map<String, dynamic>> refreshSession() async {
    final uri = _transport.uri('/api/auth/refresh');
    final res = await _transport.withIdempotentSyncRetry(
      uri,
      (client) => client.post(uri, headers: _transport.headers),
      timeout: const Duration(seconds: 10),
    );
    final body = _transport.decodeJson(res, fallback: '续期认证会话失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '续期认证会话失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '认证续期响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  /// 主动注销当前服务端会话；网络失败时由调用方继续清理本地凭据。
  Future<void> logout() async {
    final res = await _transport.client
        .post(_transport.uri('/api/auth/logout'), headers: _transport.headers)
        .timeout(const Duration(seconds: 8));
    final body = _transport.decodeJson(res, fallback: '退出认证失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '退出认证失败');
    }
  }
}
