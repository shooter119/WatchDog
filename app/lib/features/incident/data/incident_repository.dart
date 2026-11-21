import 'dart:convert';

import '../../../core/network/network.dart';
import 'models/external_incident.dart';
import 'models/incident.dart';
import 'models/incident_create_conflict_exception.dart';
import 'models/incident_event.dart';
import 'models/incident_force.dart';

class IncidentRepository {
  final ApiHttpTransport _transport;

  const IncidentRepository(this._transport);

  /// 把人工核对后的口述内容写入警情，供辅助问答作为现场背景引用。
  Future<void> createIncidentObservation({
    required String transcript,
    required String sourceType,
    required int capturedAt,
    String mediaRef = '',
    Map<String, Object?> structured = const {},
  }) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/incident-observations'),
          headers: {..._transport.headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'transcript': transcript,
            'source_type': sourceType,
            'captured_at': capturedAt,
            'media_ref': mediaRef,
            'structured': structured,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 201 || res.statusCode == 200) return;
    final body = _transport.decodeJson(res, fallback: '保存口述记录失败');
    throw _transport.apiException(res, body: body, fallback: '保存口述记录失败');
  }

  Future<List<Incident>> fetchIncidents({String? status}) async {
    // 服务端按稳定的有限页返回；客户端继续聚合为原有 List 契约，避免
    // 旧页面看到分页细节，同时防止一次响应无界增长。100 页/10000 条
    // 是本机同步的硬上限，远端异常不会让轮询无限发请求。
    const pageSize = 100;
    const maxPages = 100;
    final incidents = <Incident>[];
    for (var page = 0; page < maxPages; page++) {
      final query = <String, String>{
        if (status != null) 'status': status,
        'limit': '$pageSize',
        'offset': '${page * pageSize}',
      };
      final path = Uri(
        path: '/api/incidents',
        queryParameters: query,
      ).toString();
      final res = await _transport.client
          .get(_transport.uri(path), headers: _transport.headers)
          .timeout(const Duration(seconds: 10));
      final body = _transport.decodeJson(res, fallback: '获取警情列表失败');
      if (res.statusCode != 200) {
        throw _transport.apiException(res, body: body, fallback: '获取警情列表失败');
      }
      if (body is! List) {
        throw _transport.responseShapeException(res, '获取警情列表响应格式异常');
      }
      final list = body;
      incidents.addAll(
        list.map((e) => Incident.fromJson(e as Map<String, dynamic>)),
      );
      if (list.length < pageSize) break;
    }
    return incidents;
  }

  Future<Incident> createIncident({
    required String realName,
    String? opId,
  }) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/incidents'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({'actor_name': realName}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '新建警情失败');
    if (res.statusCode != 200 && res.statusCode != 201) {
      if (res.statusCode == 409 &&
          body is Map &&
          body['code'] == 'INCIDENT_CREATE_COOLDOWN' &&
          body['incident'] is Map) {
        throw IncidentCreateConflictException(
          body['error']?.toString() ?? '刚刚已有用户新建警情，请优先加入现有警情',
          Incident.fromJson(Map<String, dynamic>.from(body['incident'] as Map)),
        );
      }
      throw _transport.apiException(res, body: body, fallback: '新建警情失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '新建警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<List<ExternalIncident>> fetchExternalIncidents({
    bool refresh = false,
  }) async {
    final query = refresh ? '?refresh=true' : '';
    final res = await _transport.client
        .get(
          _transport.uri('/api/external-incidents$query'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '获取官方警情失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取官方警情失败');
    }
    if (body is Map && body['list'] is List) {
      final list = body['list'] as List;
      return list
          .whereType<Map>()
          .map(
            (item) =>
                ExternalIncident.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    }
    return const [];
  }

  Future<List<ExternalIncident>> reorganizeExternalIncidents({
    List<String>? externalIds,
  }) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/external-incidents/reorganize'),
          headers: _transport.headers,
          body: jsonEncode({
            if (externalIds != null && externalIds.isNotEmpty)
              'external_ids': externalIds,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final body = _transport.decodeJson(res, fallback: 'AI 重新整理警情失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: 'AI 重新整理警情失败');
    }
    if (body is Map && body['list'] is List) {
      final list = body['list'] as List;
      return list
          .whereType<Map>()
          .map(
            (item) =>
                ExternalIncident.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    }
    return const [];
  }

  Future<Incident> claimExternalIncident(
    ExternalIncident incident, {
    required String realName,
    String? opId,
  }) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/incidents/claim-external'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({
            'external_incident': incident.toJson(),
            'actor_name': realName,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '认领警情失败');
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw _transport.apiException(res, body: body, fallback: '认领警情失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '认领警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> fetchIncident(String id) async {
    final res = await _transport.client
        .get(_transport.uri('/api/incidents/$id'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取警情失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取警情失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '获取警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> updateIncidentTitle(
    String id,
    String? title, {
    required int expectedVersion,
  }) async {
    final res = await _transport.client
        .patch(
          _transport.uri('/api/incidents/$id'),
          headers: {
            ..._transport.headers,
            'X-Expected-Version': '$expectedVersion',
          },
          body: jsonEncode({
            'title': title,
            'expected_version': expectedVersion,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '修改警情名称失败');
    if (res.statusCode == 409) {
      throw _transport.apiException(
        res,
        body: body,
        fallback: '警情已被其他设备修改，请刷新后重试',
      );
    }
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '修改警情名称失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> archiveIncident(String id) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/incidents/$id/archive'),
          headers: _transport.headers,
          body: jsonEncode({'confirm': true}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '归档警情失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '归档警情失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '归档警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<List<IncidentForce>> fetchIncidentForces({
    String? forIncidentId,
  }) async {
    final id = forIncidentId ?? _transport.config.incidentId;
    final res = await _transport.client
        .get(
          _transport.uri('/api/incidents/$id/forces'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取参战力量失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取参战力量失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '参战力量响应格式异常');
    }
    final list = body;
    return list
        .map((e) => IncidentForce.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> mergeIncidentForces(
    Map<String, dynamic> body,
    String opId,
  ) => _transport.requestJsonMap(
    '/api/incidents/${_transport.config.incidentId}/forces/merge',
    method: 'POST',
    body: body,
    opId: opId,
  );

  Future<IncidentForce> saveIncidentForce({
    String? forceId,
    required String stationName,
    String? stationId,
    String? unitStationId,
    required int vehicleCount,
    required int personnelCount,
    bool vehicleCountKnown = true,
    bool personnelCountKnown = true,
    int? expectedVersion,
  }) async {
    final incidentId = _transport.config.incidentId;
    final path = forceId == null
        ? '/api/incidents/$incidentId/forces'
        : '/api/incidents/$incidentId/forces/$forceId';
    final client = _transport.client;
    final method = forceId == null ? client.post : client.patch;
    final res = await method(
      _transport.uri(path),
      headers: _transport.headers,
      body: jsonEncode({
        'station_name': stationName,
        if (stationId != null) 'station_id': stationId,
        'vehicle_count': vehicleCount,
        'personnel_count': personnelCount,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      }),
    ).timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '保存参战力量失败');
    if (res.statusCode == 409) {
      throw _transport.apiException(
        res,
        body: body,
        fallback: '参战力量已被其他设备修改，请刷新后重试',
      );
    }
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw _transport.apiException(res, body: body, fallback: '保存参战力量失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '参战力量响应格式异常');
    }
    return IncidentForce.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteIncidentForce(String forceId) async {
    final res = await _transport.client
        .delete(
          _transport.uri(
            '/api/incidents/${_transport.config.incidentId}/forces/$forceId',
          ),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '删除参战力量失败');
      throw _transport.apiException(res, body: body, fallback: '删除参战力量失败');
    }
  }

  Future<List<IncidentEvent>> fetchTimeline(
    String id, {
    int limit = 2000,
  }) async {
    final res = await _transport.client
        .get(
          _transport.uri('/api/incidents/$id/timeline?limit=$limit'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '获取火场复盘失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取火场复盘失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '火场复盘响应格式异常');
    }
    final rawEvents = body['events'];
    if (rawEvents is! List) {
      throw _transport.responseShapeException(res, '火场复盘事件响应格式异常');
    }
    if (rawEvents.any((event) => event is! Map)) {
      throw _transport.responseShapeException(res, '火场复盘事件项格式异常');
    }
    final list = rawEvents;
    return list
        .map((e) => IncidentEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
