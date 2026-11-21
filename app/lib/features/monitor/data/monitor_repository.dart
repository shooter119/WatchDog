import 'dart:convert';

import '../../../core/network/network.dart';
import 'models/calc_config.dart';
import 'models/entry.dart';
import 'monitor_exceptions.dart';

class MonitorRepository {
  final ApiHttpTransport _transport;

  const MonitorRepository(this._transport);

  Future<List<Entry>> fetchEntries({bool activeOnly = false}) async {
    final res = await _transport.client
        .get(
          _transport.uri('/api/entries${activeOnly ? '?active=1' : ''}'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取记录失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取记录失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '记录响应格式异常');
    }
    final list = body;
    return list.map((e) => Entry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Entry> createEntry({
    required String name,
    required double pressureMpa,
    String source = 'voice',
    String? rawText,
    bool force = false,
    double? volumeL,
    double? consumptionLpm,
    String? opId,
  }) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/entries'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({
            'name': name,
            'pressure_mpa': pressureMpa,
            'source': source,
            'raw_text': rawText,
            if (force) 'force': true,
            if (volumeL != null) 'volume_l': volumeL,
            if (consumptionLpm != null) 'consumption_lpm': consumptionLpm,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '创建失败');
    if (res.statusCode == 409 && body is Map && body['entry'] != null) {
      throw EntryConflictException(
        body['error']?.toString() ?? '该人员已在火场内',
        Entry.fromJson(body['entry'] as Map<String, dynamic>),
      );
    }
    if (res.statusCode != 201) {
      throw _transport.apiException(res, body: body, fallback: '创建失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '创建响应格式异常');
    }
    return Entry.fromJson(body as Map<String, dynamic>);
  }

  /// 更新在场记录（改名 / 按现场复核压力重新倒计时）
  Future<Entry> updateEntry({
    required String id,
    String? name,
    double? pressureMpa,
    double? consumptionLpm,
    String? opId,
    int? expectedVersion,
  }) async {
    final res = await _transport.client
        .patch(
          _transport.uri('/api/entries/$id'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({
            if (expectedVersion != null) 'expected_version': expectedVersion,
            if (name != null) 'name': name,
            if (pressureMpa != null) 'pressure_mpa': pressureMpa,
            if (consumptionLpm != null) 'consumption_lpm': consumptionLpm,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '更新失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '更新失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '更新响应格式异常');
    }
    return Entry.fromJson(body as Map<String, dynamic>);
  }

  Future<void> markExited(
    String id, {
    String? opId,
    int? expectedVersion,
  }) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/entries/$id/exit'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({
            if (expectedVersion != null) 'expected_version': expectedVersion,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '登记出火场失败');
      throw _transport.apiException(res, body: body, fallback: '登记出火场失败');
    }
  }

  Future<CalcConfig> fetchConfig() async {
    final res = await _transport.client
        .get(_transport.uri('/api/config'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取配置失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取配置失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '配置响应格式异常');
    }
    return CalcConfig.fromJson(body as Map<String, dynamic>);
  }
}
