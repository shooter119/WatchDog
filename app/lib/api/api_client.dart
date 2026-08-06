import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';

class ApiClient {
  final String baseUrl;
  final String sceneCode;
  final String apiToken;
  final String deviceId;

  ApiClient({required this.baseUrl, required this.sceneCode, this.apiToken = '', this.deviceId = ''});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Scene-Code': sceneCode,
        if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
        if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
      };

  /// 带操作 ID 的头（opId 贯穿一次语音操作的完整链路，服务端埋点与客户端对齐）
  Map<String, String> _opHeaders(String? opId) => {
        ..._headers,
        if (opId != null && opId.isNotEmpty) 'X-Op-Id': opId,
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<String> transcribe(Uint8List audioBytes, {String? opId}) async {
    final res = await http
        .post(
          _uri('/api/transcribe'),
          headers: {
            ..._opHeaders(opId),
            'Content-Type': 'audio/wav',
          },
          body: audioBytes,
        )
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException((body as Map)['error']?.toString() ?? '转写失败(${res.statusCode})');
    }
    return (body as Map)['text'] as String? ?? '';
  }

  Future<ParseResult> parse(String text, {String? opId}) async {
    final res = await http
        .post(_uri('/api/parse'), headers: _opHeaders(opId), body: jsonEncode({'text': text}))
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException((body as Map)['error']?.toString() ?? '解析失败(${res.statusCode})');
    }
    return ParseResult.fromJson(body as Map<String, dynamic>);
  }

  Future<List<Entry>> fetchEntries({bool activeOnly = false}) async {
    final res = await http.get(_uri('/api/entries${activeOnly ? '?active=1' : ''}'), headers: _headers);
    if (res.statusCode != 200) throw ApiException('获取记录失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
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
    final res = await http
        .post(
          _uri('/api/entries'),
          headers: _opHeaders(opId),
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
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 409 && body['entry'] != null) {
      throw EntryConflictException(
        body['error']?.toString() ?? '该人员已在火场内',
        Entry.fromJson(body['entry'] as Map<String, dynamic>),
      );
    }
    if (res.statusCode != 201) {
      throw ApiException((body as Map)['error']?.toString() ?? '创建失败(${res.statusCode})');
    }
    return Entry.fromJson(body as Map<String, dynamic>);
  }

  /// 更新在场记录（改名 / 按现场复核压力重新倒计时）
  Future<Entry> updateEntry({required String id, String? name, double? pressureMpa, double? consumptionLpm, String? opId}) async {
    final res = await http
        .patch(
          _uri('/api/entries/$id'),
          headers: _opHeaders(opId),
          body: jsonEncode({
            if (name != null) 'name': name,
            if (pressureMpa != null) 'pressure_mpa': pressureMpa,
            if (consumptionLpm != null) 'consumption_lpm': consumptionLpm,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException((body as Map)['error']?.toString() ?? '更新失败(${res.statusCode})');
    }
    return Entry.fromJson(body as Map<String, dynamic>);
  }

  Future<void> markExited(String id, {String? opId}) async {
    final res = await http
        .post(_uri('/api/entries/$id/exit'), headers: _opHeaders(opId))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw ApiException('登记出火场失败(${res.statusCode})');
  }

  Future<List<Firefighter>> fetchFirefighters() async {
    final res = await http.get(_uri('/api/firefighters'), headers: _headers);
    if (res.statusCode != 200) throw ApiException('获取名单失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list.map((e) => Firefighter.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> addFirefighter(String name) async {
    final res = await http
        .post(_uri('/api/firefighters'), headers: _headers, body: jsonEncode({'name': name}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw ApiException('添加失败(${res.statusCode})');
    }
  }

  Future<void> removeFirefighter(String id) async {
    final res = await http.delete(_uri('/api/firefighters/$id'), headers: _headers);
    if (res.statusCode != 200) throw ApiException('删除失败(${res.statusCode})');
  }

  Future<List<Hotword>> fetchHotwords() async {
    final res = await http.get(_uri('/api/hotwords'), headers: _headers);
    if (res.statusCode != 200) throw ApiException('获取词库失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list.map((e) => Hotword.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> addHotword(String word) async {
    final res = await http
        .post(_uri('/api/hotwords'), headers: _headers, body: jsonEncode({'word': word}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw ApiException('添加失败(${res.statusCode})');
    }
  }

  Future<void> removeHotword(String id) async {
    final res = await http.delete(_uri('/api/hotwords/$id'), headers: _headers);
    if (res.statusCode != 200) throw ApiException('删除失败(${res.statusCode})');
  }

  Future<CalcConfig> fetchConfig() async {
    final res = await http.get(_uri('/api/config'), headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取配置失败(${res.statusCode})');
    return CalcConfig.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  /// 批量上报操作日志（每条带 op_id/stage/level/msg/data）
  Future<void> sendLogs(List<Map<String, dynamic>> logs) async {
    final res = await http
        .post(_uri('/api/logs'), headers: _headers, body: jsonEncode({'logs': logs}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('日志上报失败(${res.statusCode})');
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// 同名人员已在火场内（409）：携带已有在场记录，供确认页二选一处理
class EntryConflictException implements Exception {
  final String message;
  final Entry existing;
  EntryConflictException(this.message, this.existing);
  @override
  String toString() => message;
}
