import 'dart:convert';

import '../../../core/network/network.dart';
import '../../../services/scoped_json_cache.dart';
import 'models/firefighter.dart';
import 'models/hotword.dart';
import 'models/station.dart';

class RosterRepository {
  final ApiHttpTransport _transport;

  const RosterRepository(this._transport);

  Future<List<Firefighter>> fetchFirefighters() async {
    final res = await _transport.client
        .get(_transport.uri('/api/firefighters'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取名单失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取名单失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '名单响应格式异常');
    }
    final list = body;
    return list
        .map((e) => Firefighter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> addFirefighter(String name) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/firefighters'),
          headers: _transport.headers,
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '添加失败');
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw _transport.apiException(res, body: body, fallback: '添加失败');
    }
    return res.statusCode == 201;
  }

  Future<void> removeFirefighter(String id) async {
    final res = await _transport.client
        .delete(
          _transport.uri('/api/firefighters/$id'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '删除失败');
      throw _transport.apiException(res, body: body, fallback: '删除失败');
    }
  }

  Future<List<Hotword>> fetchHotwords() async {
    final res = await _transport.client
        .get(_transport.uri('/api/hotwords'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取词库失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取词库失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '词库响应格式异常');
    }
    final list = body;
    return list
        .map((e) => Hotword.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addHotword(String word) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/hotwords'),
          headers: _transport.headers,
          body: jsonEncode({'word': word}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '添加失败');
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw _transport.apiException(res, body: body, fallback: '添加失败');
    }
  }

  Future<void> removeHotword(String id) async {
    final res = await _transport.client
        .delete(
          _transport.uri('/api/hotwords/$id'),
          headers: _transport.headers,
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '删除失败');
      throw _transport.apiException(res, body: body, fallback: '删除失败');
    }
  }

  Future<List<Map<String, dynamic>>> fetchUnitStations({
    bool includeInactive = false,
  }) async {
    final key = 'directory:${includeInactive ? 'all' : 'active'}';
    try {
      final value = await _transport.requestJsonList(
        '/api/unit-stations${includeInactive ? '?include_inactive=1' : ''}',
      );
      await ScopedJsonCache.write(_transport.cacheScope, key, value);
      return value;
    } catch (error) {
      if (error is ApiException && (error.statusCode ?? 500) < 500) rethrow;
      final cached = await ScopedJsonCache.read(_transport.cacheScope, key);
      if (cached is List) {
        return cached.map((s) => Map<String, dynamic>.from(s as Map)).toList();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> unitStationAccess() =>
      _transport.requestJsonMap('/api/unit-stations/access');

  Future<Map<String, dynamic>> addUnitStation(String name) => _transport
      .requestJsonMap('/api/unit-stations', method: 'POST', body: {'name': name});

  Future<Map<String, dynamic>> updateUnitStation(
    String id,
    Map<String, dynamic> data,
  ) => _transport.requestJsonMap(
    '/api/unit-stations/$id',
    method: 'PATCH',
    body: data,
  );

  Future<List<Station>> fetchStations() async {
    try {
      final res = await _transport.client
          .get(_transport.uri('/api/stations'), headers: _transport.headers)
          .timeout(const Duration(seconds: 10));
      final body = _transport.decodeJson(res, fallback: '获取消防站名录失败');
      if (res.statusCode != 200) {
        throw _transport.apiException(res, body: body, fallback: '获取消防站名录失败');
      }
      if (body is! List) {
        throw _transport.responseShapeException(res, '消防站名录响应格式异常');
      }
      final list = body
          .whereType<Map>()
          .map((e) => Station.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (_transport.cacheScope.isNotEmpty) {
        await ScopedJsonCache.write(
          _transport.cacheScope,
          'org-stations',
          list.map((item) => {'id': item.id, 'name': item.name}).toList(),
        );
      }
      return list;
    } catch (error) {
      if (error is ApiException && (error.statusCode ?? 500) < 500) rethrow;
      if (_transport.cacheScope.isEmpty) rethrow;
      final cached = await ScopedJsonCache.read(
        _transport.cacheScope,
        'org-stations',
      );
      if (cached is List) {
        return cached
            .whereType<Map>()
            .map((item) => Station.fromJson(Map<String, dynamic>.from(item)))
            .toList();
      }
      rethrow;
    }
  }

  Future<Station> createStation(String name) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/stations'),
          headers: _transport.headers,
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '新增消防站失败');
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw _transport.apiException(res, body: body, fallback: '新增消防站失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '消防站响应格式异常');
    }
    return Station.fromJson(body as Map<String, dynamic>);
  }
}
