import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';

class ApiClient {
  final String baseUrl;
  final String sceneCode;
  final String apiToken;

  ApiClient({required this.baseUrl, required this.sceneCode, this.apiToken = ''});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Scene-Code': sceneCode,
        if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<String> transcribe(Uint8List audioBytes) async {
    final res = await http
        .post(
          _uri('/api/transcribe'),
          headers: {
            'Content-Type': 'audio/wav',
            'X-Scene-Code': sceneCode,
            if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
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

  Future<ParseResult> parse(String text) async {
    final res = await http
        .post(_uri('/api/parse'), headers: _headers, body: jsonEncode({'text': text}))
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
  }) async {
    final res = await http
        .post(
          _uri('/api/entries'),
          headers: _headers,
          body: jsonEncode({
            'name': name,
            'pressure_mpa': pressureMpa,
            'source': source,
            'raw_text': rawText,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 201) {
      throw ApiException((body as Map)['error']?.toString() ?? '创建失败(${res.statusCode})');
    }
    return Entry.fromJson(body as Map<String, dynamic>);
  }

  Future<void> markExited(String id) async {
    final res = await http
        .post(_uri('/api/entries/$id/exit'), headers: _headers)
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
    final res = await http.get(_uri('/api/config')).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取配置失败(${res.statusCode})');
    return CalcConfig.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}
