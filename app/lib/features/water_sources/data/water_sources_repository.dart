import 'dart:convert';

import '../../../core/network/network.dart';
import 'models/water_source.dart';

class WaterSourcesRepository {
  final ApiHttpTransport _transport;

  const WaterSourcesRepository(this._transport);

  /// 拉取本单位全部未删除水源与统计摘要（整单位轻量快照，端侧本地算距排序）。
  Future<WaterSourceListResult> fetchWaterSources() async {
    final res = await _transport.client
        .get(_transport.uri('/api/water-sources'), headers: _transport.headers)
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '获取周边水源失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取周边水源失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '水源列表响应格式异常');
    }
    return WaterSourceListResult.fromJson(Map<String, dynamic>.from(body));
  }

  /// 新增水源点位（全库统一 GCJ-02 坐标）。
  Future<WaterSource> createWaterSource({
    required WaterSourceCategory category,
    required String name,
    required double lat,
    required double lng,
    WaterSourceStatus status = WaterSourceStatus.available,
    List<WaterIntakeMethod> intakeMethods = const [],
    String note = '',
  }) async {
    final payload = <String, dynamic>{
      'category': category.apiValue,
      'name': name.trim(),
      'lat': lat,
      'lng': lng,
      'status': status.apiValue,
      'intake_methods': intakeMethods.map((m) => m.apiValue).toList(),
      'note': note.trim(),
    };
    final res = await _transport.client
        .post(
          _transport.uri('/api/water-sources'),
          headers: _transport.headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '新增水源失败');
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '新增水源失败');
    }
    if (body is! Map || body['item'] is! Map) {
      throw _transport.responseShapeException(res, '新增水源响应格式异常');
    }
    return WaterSource.fromJson(
      Map<String, dynamic>.from(body['item'] as Map),
    );
  }

  /// 更新水源点位（编辑、改坐标、备注更新或快捷切换可用状态）。
  Future<WaterSource> updateWaterSource(
    String id, {
    WaterSourceCategory? category,
    String? name,
    double? lat,
    double? lng,
    WaterSourceStatus? status,
    List<WaterIntakeMethod>? intakeMethods,
    String? note,
  }) async {
    final payload = <String, dynamic>{
      if (category != null) 'category': category.apiValue,
      if (name != null) 'name': name.trim(),
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (status != null) 'status': status.apiValue,
      if (intakeMethods != null)
        'intake_methods': intakeMethods.map((m) => m.apiValue).toList(),
      if (note != null) 'note': note.trim(),
    };
    final res = await _transport.client
        .patch(
          _transport.uri('/api/water-sources/${Uri.encodeComponent(id)}'),
          headers: _transport.headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '更新水源失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '更新水源失败');
    }
    if (body is! Map || body['item'] is! Map) {
      throw _transport.responseShapeException(res, '更新水源响应格式异常');
    }
    return WaterSource.fromJson(
      Map<String, dynamic>.from(body['item'] as Map),
    );
  }

  /// 软删除水源点位（原删除人 60 秒内可调用 [restoreWaterSource] 撤销）。
  Future<int> deleteWaterSource(String id) async {
    final res = await _transport.client
        .delete(
          _transport.uri('/api/water-sources/${Uri.encodeComponent(id)}'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '删除水源失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '删除水源失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '删除水源响应格式异常');
    }
    return (body['deleted_at'] as num?)?.toInt() ?? 0;
  }

  /// 撤销 60 秒内的本人软删除记录。
  Future<WaterSource> restoreWaterSource(String id) async {
    final res = await _transport.client
        .post(
          _transport.uri(
            '/api/water-sources/${Uri.encodeComponent(id)}/restore',
          ),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '恢复水源失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '恢复水源失败');
    }
    if (body is! Map || body['item'] is! Map) {
      throw _transport.responseShapeException(res, '恢复水源响应格式异常');
    }
    return WaterSource.fromJson(
      Map<String, dynamic>.from(body['item'] as Map),
    );
  }
}
