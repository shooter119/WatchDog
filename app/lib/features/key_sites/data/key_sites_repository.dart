import 'dart:convert';
import 'dart:typed_data';

import '../../../core/network/network.dart';
import '../../incident/data/models/incident.dart';
import 'models/key_sites.dart';

class KeySitesRepository {
  final ApiHttpTransport _transport;

  const KeySitesRepository(this._transport);

  Future<Map<String, dynamic>> _keySiteRequest(
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? data,
    String? operationId,
  }) async {
    final uri = _transport.uri(path).replace(queryParameters: query);
    final client = _transport.client;
    final response =
        await (data == null
                ? client.get(uri, headers: _transport.headers)
                : client.put(
                    uri,
                    headers: {
                      ..._transport.headers,
                      'Content-Type': 'application/json',
                      if (operationId != null) 'X-Op-Id': operationId,
                    },
                    body: jsonEncode(data),
                  ))
            .timeout(const Duration(seconds: 20));
    final body = _transport.decodeJson(response, fallback: '资料加载失败');
    if (response.statusCode != 200) {
      throw _transport.apiException(
        response,
        body: body,
        fallback: '资料加载失败',
      );
    }
    return Map<String, dynamic>.from(body as Map);
  }

  Future<Map<String, dynamic>> keySiteAccess() =>
      _keySiteRequest('/api/key-sites/access');

  Future<Map<String, dynamic>> keySiteFilters() =>
      _keySiteRequest('/api/key-sites/filters');

  Future<Map<String, dynamic>> fetchKeySites({
    String search = '',
    String district = '',
    String type = '',
    int offset = 0,
  }) => _keySiteRequest(
    '/api/key-sites',
    query: {
      'q': search,
      'district': district,
      'site_type': type,
      'offset': '$offset',
      'limit': '20',
    },
  );

  Future<List<KeySiteSummary>> fetchRecentKeySites(List<String> ids) async {
    final data = await _keySiteRequest(
      '/api/key-sites/recent',
      query: {'ids': ids.join(',')},
    );
    return (data['sites'] as List)
        .map(
          (s) => KeySiteSummary.fromJson(Map<String, dynamic>.from(s as Map)),
        )
        .toList();
  }

  Future<KeySiteVersion> fetchKeySite(
    String id, {
    int? version,
    String? incident,
  }) async => KeySiteVersion.fromJson(
    await _keySiteRequest(
      '/api/key-sites/${Uri.encodeComponent(id)}${version == null ? '' : '/versions/$version'}',
      query: {if (incident != null) 'incidentId': incident},
    ),
  );

  Future<Map<String, dynamic>> fetchIncidentKeySite(String id) =>
      _keySiteRequest('/api/incidents/${Uri.encodeComponent(id)}/key-site');

  Future<Incident> changeIncidentKeySite(
    String id, {
    required int revision,
    required String operationId,
    KeySiteVersion? site,
  }) async {
    final result = await _keySiteRequest(
      '/api/incidents/${Uri.encodeComponent(id)}/key-site',
      operationId: operationId,
      data: {
        'revision': revision,
        'siteId': site?.siteId,
        if (site != null) ...{
          'version': site.version,
          'confirmName': site.name,
          'confirmAddress': site.address,
        },
      },
    );
    return Incident.fromJson(
      Map<String, dynamic>.from(result['incident'] as Map),
    );
  }

  /// 文件路径由调用方的版本快照生成，拒绝任意外站 URL；不使用磁盘缓存。
  Future<Uint8List> fetchKeySiteImage(
    String siteId,
    int version,
    String attachmentId, {
    required String resource,
    String? incident,
  }) async {
    if (!RegExp(
      r'^(pages/[1-9][0-9]*\.jpg|maps/[1-9][0-9]*/tiles/[0-9]+/[0-9]+/[0-9]+\.jpg)$',
    ).hasMatch(resource)) {
      throw ArgumentError('资料图像路径无效');
    }
    final uri = _transport
        .uri(
          '/api/key-sites/${Uri.encodeComponent(siteId)}/versions/$version/attachments/${Uri.encodeComponent(attachmentId)}/$resource',
        )
        .replace(queryParameters: {if (incident != null) 'incidentId': incident});
    final response = await _transport.client
        .get(uri, headers: _transport.headers)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      final body = _transport.decodeJson(response, fallback: '附件加载失败');
      throw _transport.apiException(response, body: body, fallback: '附件加载失败');
    }
    return response.bodyBytes;
  }
}
