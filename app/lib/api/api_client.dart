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

  Future<List<Note>> fetchNotes() async {
    final res = await http.get(_uri('/api/notes'), headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取日志失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list.map((e) => Note.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Note> createNote({required String text, String? category, String? opId}) async {
    final res = await http
        .post(
          _uri('/api/notes'),
          headers: _opHeaders(opId),
          body: jsonEncode({'text': text, if (category != null) 'category': category}),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 201) {
      throw ApiException((body as Map)['error']?.toString() ?? '记录日志失败(${res.statusCode})');
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<Note> updateNote({required String id, String? text, String? category}) async {
    final res = await http
        .patch(
          _uri('/api/notes/$id'),
          headers: _headers,
          body: jsonEncode({
            if (text != null) 'text': text,
            if (category != null) 'category': category,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException((body as Map)['error']?.toString() ?? '编辑日志失败(${res.statusCode})');
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteNote(String id) async {
    final res = await http.delete(_uri('/api/notes/$id'), headers: _headers).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw ApiException('删除日志失败(${res.statusCode})');
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

  /// 拉取智能体问答历史（旧→新，供聊天室恢复上下文）
  Future<List<ChatMessage>> fetchChatMessages() async {
    final res = await http.get(_uri('/api/chat'), headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取问答记录失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 发送提问，返回 AI 回复消息（服务端已把 user+assistant 成对落库）
  Future<ChatMessage> sendChatMessage(String message, {String? opId}) async {
    final res = await http
        .post(
          _uri('/api/chat'),
          headers: _opHeaders(opId),
          body: jsonEncode({'message': message}),
        )
        .timeout(const Duration(seconds: 60));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException((body as Map)['error']?.toString() ?? '提问失败(${res.statusCode})');
    }
    final m = body as Map;
    return ChatMessage(
      id: '',
      role: 'assistant',
      content: m['reply']?.toString() ?? '',
      createdAt: (m['created_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 清空本场景问答记录
  Future<void> clearChatMessages() async {
    final res = await http.delete(_uri('/api/chat'), headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('清空问答记录失败(${res.statusCode})');
  }

  /// 批量上报操作日志（每条带 op_id/stage/level/msg/data）
  Future<void> sendLogs(List<Map<String, dynamic>> logs) async {
    final res = await http
        .post(_uri('/api/logs'), headers: _headers, body: jsonEncode({'logs': logs}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('日志上报失败(${res.statusCode})');
  }

  /// 拉取云端用户设置（按 X-Device-Id 识别用户，按场景隔离）
  /// 返回 { settings: {...}, updatedAt: 服务器最近修改时间（无记录为 0） }
  Future<Map<String, dynamic>> fetchUserSettings() async {
    final res = await http
        .get(_uri('/api/user-settings'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取云端设置失败(${res.statusCode})');
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return {
      'settings': body['settings'] is Map<String, dynamic> ? body['settings'] as Map<String, dynamic> : <String, dynamic>{},
      'updatedAt': (body['updated_at'] as num?)?.toInt() ?? 0,
    };
  }

  /// 推送本地用户设置到云端（全量覆盖白名单键）
  Future<void> pushUserSettings(Map<String, dynamic> settings) async {
    final res = await http
        .put(
          _uri('/api/user-settings'),
          headers: _headers,
          body: jsonEncode({'settings': settings}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('同步设置失败(${res.statusCode})');
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
