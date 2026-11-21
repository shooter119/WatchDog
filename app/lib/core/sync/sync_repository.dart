import 'dart:convert';

import '../network/network.dart';

class SyncRepository {
  final ApiHttpTransport _transport;

  const SyncRepository(this._transport);

  /// 业务实时同步连接。与 REST 使用同一服务器地址和会话鉴权，支持
  /// localhost/10.0.2.2 等本地开发入口，也支持任意自托管后端。
  Uri realtimeSyncUri() {
    final httpUri = _transport.uri('/api/realtime');
    return httpUri.replace(scheme: httpUri.scheme == 'https' ? 'wss' : 'ws');
  }

  Map<String, String> realtimeSyncHeaders() => _transport.headers;

  Future<Map<String, dynamic>> fetchSyncBootstrap({
    String? forIncidentId,
  }) async {
    final query = <String, String>{
      if (forIncidentId != null && forIncidentId.isNotEmpty)
        'incident_id': forIncidentId,
    };
    final path = Uri(
      path: '/api/sync/bootstrap',
      queryParameters: query,
    ).toString();
    final uri = _transport.uri(path);
    final res = await _transport.withIdempotentSyncRetry(
      uri,
      (client) => client.get(uri, headers: _transport.headers),
      timeout: const Duration(seconds: 15),
    );
    final body = _transport.decodeJson(res, fallback: '获取实时同步快照失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取实时同步快照失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '实时同步快照格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> fetchSyncCheckpoint({
    String? forIncidentId,
  }) async {
    final query = <String, String>{
      if (forIncidentId != null && forIncidentId.isNotEmpty)
        'incident_id': forIncidentId,
    };
    final path = Uri(
      path: '/api/sync/checkpoint',
      queryParameters: query,
    ).toString();
    final uri = _transport.uri(path);
    final res = await _transport.withIdempotentSyncRetry(
      uri,
      (client) => client.get(uri, headers: _transport.headers),
      timeout: const Duration(seconds: 10),
    );
    final body = _transport.decodeJson(res, fallback: '校准实时同步失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '校准实时同步失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '实时同步校验点格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  Future<List<Map<String, dynamic>>> fetchSyncEvents({
    required String unitCursor,
    required String incidentCursor,
    String? forIncidentId,
    int limit = 500,
  }) async {
    final path = Uri(
      path: '/api/sync/events',
      queryParameters: {
        'unit_cursor': unitCursor,
        'incident_cursor': incidentCursor,
        'limit': '${limit.clamp(1, 500)}',
        if (forIncidentId != null && forIncidentId.isNotEmpty)
          'incident_id': forIncidentId,
      },
    ).toString();
    final uri = _transport.uri(path);
    final res = await _transport.withIdempotentSyncRetry(
      uri,
      (client) => client.get(uri, headers: _transport.headers),
      timeout: const Duration(seconds: 15),
    );
    final body = _transport.decodeJson(res, fallback: '补拉实时事件失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '补拉实时事件失败');
    }
    if (body is! Map || body['events'] is! List) {
      throw _transport.responseShapeException(res, '实时事件响应格式异常');
    }
    return (body['events'] as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> submitReviewedOperation({
    required String type,
    required Map<String, dynamic> payload,
    required String originalOpId,
    required String newOpId,
    int? expectedVersion,
  }) async {
    final id = Uri.encodeComponent(payload['entry_id']?.toString() ?? '');
    final path = type == 'note'
        ? '/api/notes'
        : type == 'entry'
        ? '/api/entries'
        : type == 'exit'
        ? '/api/entries/$id/exit'
        : '/api/entries/$id';
    final data = {
      ...payload,
      'reviewed_client_op_id': originalOpId,
      if (expectedVersion != null) 'expected_version': expectedVersion,
    };
    data.remove('predecessor_op_id');
    final client = _transport.client;
    final res =
        await (type == 'pressure'
                ? client.patch(
                    _transport.uri(path),
                    headers: _transport.opHeaders(newOpId),
                    body: jsonEncode(data),
                  )
                : client.post(
                    _transport.uri(path),
                    headers: _transport.opHeaders(newOpId),
                    body: jsonEncode(data),
                  ))
            .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '重新提交失败');
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw _transport.apiException(res, body: body, fallback: '重新提交失败');
    }
  }

  Future<Map<String, dynamic>> uploadOfflineOperations(
    List<Map<String, dynamic>> operations,
  ) async {
    final res = await _transport.client
        .post(
          _transport.uri(
            '/api/incidents/${_transport.config.incidentId}/offline-operations',
          ),
          headers: _transport.headers,
          body: jsonEncode({'operations': operations}),
        )
        .timeout(const Duration(seconds: 20));
    final body = _transport.decodeJson(res, fallback: '离线数据补传失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '离线数据补传失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '离线补传响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }
}
