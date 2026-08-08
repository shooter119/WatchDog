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

  /// 流式提问（SSE）：每收到一段增量内容回调 [onChunk]，返回完整回复文本。
  /// 服务端回复完成才落库，本地无需额外保存。
  Future<String> sendChatMessageStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('POST', _uri('/api/chat'));
      req.headers.addAll(_opHeaders(opId));
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({'message': message, 'stream': 1});
      // 首字节 15s 超时（流式下无需等待整条回复，60s 总超时问题随之消失）
      final res = await client.send(req).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        final body = await res.stream.bytesToString();
        final m = jsonDecode(body) as Map?;
        throw ApiException(m?['error']?.toString() ?? '提问失败(${res.statusCode})');
      }
      final full = StringBuffer();
      final parser = SseLineParser();
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        for (final ev in parser.push(chunk)) {
          if (ev.done) return full.toString();
          if (ev.error != null) throw ApiException(ev.error!);
          if (ev.content != null) {
            full.write(ev.content);
            onChunk(ev.content!);
          }
        }
      }
      return full.toString();
    } finally {
      client.close();
    }
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

  /// 结束任务：标记当前场景已归档，返回服务端统一分配的新场景码（幂等）
  Future<String> endTask({String? opId}) async {
    final res = await http
        .post(_uri('/api/scenes/end'), headers: _opHeaders(opId))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException((body as Map)['error']?.toString() ?? '结束任务失败(${res.statusCode})');
    }
    return (body as Map)['new_scene']?.toString() ?? '';
  }

  /// 核验场景码（更换任务码前调用）：格式（水果词表/default）+ 存在性 + 是否已归档。
  /// 核验不通过时 App 必须维持原场景码，避免切换后设备失联。
  Future<SceneValidation> validateScene(String code) async {
    final uri = Uri.parse('$baseUrl/api/scenes/validate')
        .replace(queryParameters: {'code': code});
    final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('核验失败(${res.statusCode})');
    final m = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return SceneValidation(
      valid: m['valid'] == true,
      exists: m['exists'] == true,
      ended: m['ended'] == true,
      newScene: m['new_scene']?.toString(),
    );
  }

  /// 查询当前场景是否已被归档（其他设备发起），返回 null 表示场景未结束
  Future<SceneState?> fetchSceneState() async {
    final res = await http.get(_uri('/api/scenes'), headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取场景状态失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    for (final item in list) {
      final m = item as Map<String, dynamic>;
      if (m['code'] == sceneCode && m['ended_at'] != null) {
        return SceneState(
          endedAt: (m['ended_at'] as num).toInt(),
          endedBy: m['ended_by']?.toString(),
          newScene: m['new_scene']?.toString(),
        );
      }
    }
    return null;
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// 场景码核验结果（GET /api/scenes/validate）
class SceneValidation {
  final bool valid; // 合法任务码（水果词表或 default）
  final bool exists; // 服务器上已有该场景数据
  final bool ended; // 该场景已被归档（任务已结束）
  final String? newScene; // ended 时服务端分配的新场景码

  const SceneValidation({
    required this.valid,
    required this.exists,
    required this.ended,
    this.newScene,
  });
}

/// SSE 事件：增量内容 / 错误 / 结束
class SseEvent {
  final String? content;
  final String? error;
  final bool done;
  const SseEvent.content(String this.content) : error = null, done = false;
  const SseEvent.error(String this.error) : content = null, done = false;
  const SseEvent.done() : content = null, error = null, done = true;
}

/// SSE 行解析：缓冲跨 chunk 的半行，产出完整事件（协议：`data: {...}` 行 + [DONE]）
class SseLineParser {
  String _buf = '';
  final List<SseEvent> _events = [];

  List<SseEvent> push(String chunk) {
    _events.clear();
    _buf += chunk;
    var idx = -1;
    while ((idx = _buf.indexOf('\n')) >= 0) {
      final line = _buf.substring(0, idx);
      _buf = _buf.substring(idx + 1);
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final data = trimmed.substring(5).trim();
      if (data == '[DONE]') {
        _events.add(const SseEvent.done());
        continue;
      }
      try {
        final m = jsonDecode(data) as Map<String, dynamic>;
        final error = m['error'] as String?;
        if (error != null) {
          _events.add(SseEvent.error(error));
        } else {
          final content = m['content'] as String?;
          if (content != null) _events.add(SseEvent.content(content));
        }
      } catch (_) {
        // 忽略无法解析的行（服务端可能发送 keep-alive）
      }
    }
    return _events;
  }
}

/// 同名人员已在火场内（409）：携带已有在场记录，供确认页二选一处理
class EntryConflictException implements Exception {
  final String message;
  final Entry existing;
  EntryConflictException(this.message, this.existing);
  @override
  String toString() => message;
}
