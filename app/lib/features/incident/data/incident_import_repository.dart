import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../core/network/network.dart';
import '../../../services/scoped_json_cache.dart';

class IncidentImportRepository {
  final ApiHttpTransport _transport;

  const IncidentImportRepository(this._transport);

  String get _incidentId => _transport.config.incidentId;

  Future<Map<String, dynamic>> fetchIncidentDetails() async {
    final incidentId = _incidentId;
    final cacheScope = _transport.cacheScope;
    try {
      final value = await _transport.requestJsonMap(
        '/api/incidents/$incidentId/details',
      );
      await ScopedJsonCache.write(cacheScope, 'details:$incidentId', value);
      return value;
    } catch (error) {
      if (error is ApiException && (error.statusCode ?? 500) < 500) rethrow;
      final cached = await ScopedJsonCache.read(
        cacheScope,
        'details:$incidentId',
      );
      if (cached is Map) {
        return {...Map<String, dynamic>.from(cached), 'offline': true};
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> updateIncidentDetails(
    Map<String, dynamic> data,
    int version,
    String opId,
  ) => _transport.requestJsonMap(
    '/api/incidents/$_incidentId/details',
    method: 'PATCH',
    opId: opId,
    body: {'data': data, 'expected_version': version},
  );

  Future<Map<String, dynamic>> createIncidentImport({
    String? text,
    List<Uint8List> images = const [],
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _transport.uri('/api/incidents/$_incidentId/imports'),
    );
    request.headers.addAll(_transport.headers..remove('Content-Type'));
    if (text != null) request.fields['text'] = text;
    for (var i = 0; i < images.length; i++) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'images',
          images[i],
          filename: 'page-$i.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    }
    final client = _transport.client;
    final response = await (() async {
      final stream = await client.send(request);
      return http.Response.fromStream(stream);
    })().timeout(const Duration(seconds: 90));
    final value = _transport.decodeJson(response, fallback: '提交导入失败');
    if (response.statusCode != 202) {
      throw _transport.apiException(response, body: value, fallback: '提交导入失败');
    }
    if (value is! Map) {
      throw _transport.responseShapeException(response, '导入任务格式异常');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<Uint8List> fetchImportImage(String id, int page) async {
    final response = await _transport.client
        .get(
          _transport.uri(
            '/api/incidents/$_incidentId/imports/$id/images/$page',
          ),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw ApiException('临时图片不可用，可能已清理', statusCode: response.statusCode);
    }
    return response.bodyBytes;
  }

  Future<Map<String, dynamic>> fetchIncidentImport(String id) =>
      _transport.requestJsonMap('/api/incidents/$_incidentId/imports/$id');

  Future<Map<String, dynamic>> retryIncidentImport(
    String id,
    List<int> pages,
  ) => _transport.requestJsonMap(
    '/api/incidents/$_incidentId/imports/$id/retry',
    method: 'POST',
    body: {'pages': pages},
  );

  Future<Map<String, dynamic>> cancelIncidentImport(String id) =>
      _transport.requestJsonMap(
        '/api/incidents/$_incidentId/imports/$id/cancel',
        method: 'POST',
      );

  Future<Map<String, dynamic>> applyIncidentImport(
    String id,
    Map<String, dynamic> body,
    String opId,
  ) => _transport.requestJsonMap(
    '/api/incidents/$_incidentId/imports/$id/apply',
    method: 'POST',
    body: body,
    opId: opId,
  );

  Future<List<Map<String, dynamic>>> fetchIncidentImports() =>
      _transport.requestJsonList('/api/incidents/$_incidentId/imports');
}
