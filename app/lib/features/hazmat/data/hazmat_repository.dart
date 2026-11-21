import 'dart:convert';

import '../../../core/network/network.dart';
import 'models/hazmat.dart';

class HazmatRepository {
  final ApiHttpTransport _transport;

  const HazmatRepository(this._transport);

  /// 增量同步危化品标准库与软删除记录
  Future<HazmatSyncResult> syncHazmats({
    int since = 0,
    int limit = 500,
  }) async {
    final uri = _transport
        .uri('/api/hazmats/sync')
        .replace(queryParameters: {'since': '$since', 'limit': '$limit'});
    final res = await _transport.client
        .get(uri, headers: _transport.headers)
        .timeout(const Duration(seconds: 20));
    final body = _transport.decodeJson(res, fallback: '危化品知识库同步失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '危化品知识库同步失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '危化品同步响应格式异常');
    }
    return HazmatSyncResult.fromJson(Map<String, dynamic>.from(body));
  }

  /// 本地未命中时显式请求云端（服务端精确库优先 -> AI 应急提炼）
  Future<HazmatAiResult> generateHazmatAiCard(String query) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/hazmats/ai-card'),
          headers: _transport.headers,
          body: jsonEncode({'query': query.trim()}),
        )
        .timeout(const Duration(seconds: 35));
    final body = _transport.decodeJson(res, fallback: '危化品 AI 提炼失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '危化品 AI 提炼失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '危化品 AI 响应格式异常');
    }
    return HazmatAiResult.fromJson(Map<String, dynamic>.from(body));
  }
}
