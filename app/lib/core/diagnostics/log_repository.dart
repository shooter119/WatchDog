import 'dart:convert';

import '../network/network.dart';

class LogRepository {
  final ApiHttpTransport _transport;

  const LogRepository(this._transport);

  /// 批量上报操作日志（每条带 op_id/stage/level/msg/data）
  Future<void> sendLogs(List<Map<String, dynamic>> logs) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/logs'),
          headers: _transport.headers,
          body: jsonEncode({'logs': logs}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '日志上报失败');
      throw _transport.apiException(res, body: body, fallback: '日志上报失败');
    }
  }
}
