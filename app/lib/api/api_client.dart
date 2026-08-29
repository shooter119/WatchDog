import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/models.dart';
import '../services/settings.dart';

class ApiClient {
  final String baseUrl;
  final String incidentId;
  final String apiToken;
  final String deviceId;
  final String actorName;
  final String unitId;
  final String unitCode;
  final String sessionToken;
  final IOClient _client = _newHttpClient();
  IOClient? _activeChatClient;
  final Set<IOClient> _transientClients = <IOClient>{};
  bool _disposed = false;

  ApiClient({
    required this.baseUrl,
    required this.incidentId,
    this.apiToken = '',
    this.deviceId = '',
    this.actorName = '',
    this.unitId = '',
    this.unitCode = '',
    this.sessionToken = '',
  });

  ApiClient forIncident(String id) => ApiClient(
    baseUrl: baseUrl,
    incidentId: id,
    apiToken: apiToken,
    deviceId: deviceId,
    actorName: actorName,
    unitId: unitId,
    unitCode: unitCode,
    sessionToken: sessionToken,
  );

  /// 辅助 AI 不属于任何警情，也不参与警情协同。
  ApiClient forAssistant() => ApiClient(
    baseUrl: baseUrl,
    incidentId: '',
    apiToken: apiToken,
    deviceId: deviceId,
    actorName: actorName,
    unitId: unitId,
    unitCode: unitCode,
    sessionToken: sessionToken,
  );

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (incidentId.isNotEmpty) 'X-Incident-Id': incidentId,
    if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
    if (sessionToken.isNotEmpty) 'Authorization': 'Bearer $sessionToken',
    if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
    if (unitId.isNotEmpty) 'X-Unit-Id': unitId,
    if (unitCode.isNotEmpty) 'X-Unit-Code': unitCode,
    // HTTP 头只能安全承载 ASCII/Latin-1；消防员实名通常是中文，
    // 直接放入 X-Actor-Name 会被 Dart http 拒绝并导致所有请求失败。
    if (actorName.isNotEmpty)
      'X-Actor-Name-B64': base64Encode(utf8.encode(actorName)),
  };

  /// 带操作 ID 的头（opId 贯穿一次语音操作的完整链路，服务端埋点与客户端对齐）
  Map<String, String> _opHeaders(String? opId) => {
    ..._headers,
    if (opId != null && opId.isNotEmpty) 'X-Op-Id': opId,
  };

  Uri _uri(String path) {
    if (!Settings.isSafeHttpUrl(baseUrl)) {
      throw StateError('服务器地址不安全');
    }
    final uri = Uri.tryParse('$baseUrl$path');
    if (uri == null || uri.host.isEmpty) {
      throw StateError('服务器地址无效');
    }
    return uri;
  }

  /// 创建带底层连接/空闲超时的移动端 HTTP 客户端。
  ///
  /// `Future.timeout` 只能停止等待 Dart Future，不能保证底层 socket 被关闭。
  /// 所有 API 请求都使用受控客户端；辅助页另建一个客户端，便于单独取消。
  static IOClient _newHttpClient() {
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 25);
    return IOClient(httpClient);
  }

  IOClient _newChatClient() => _newHttpClient();

  /// 取消当前辅助问答的底层请求（页面超时、离开页面或用户重试时调用）。
  void cancelChatRequest() {
    _activeChatClient?.close();
  }

  /// 释放 API 客户端及其底层 socket。
  void dispose() {
    _disposed = true;
    cancelChatRequest();
    _client.close();
    for (final client in List<IOClient>.of(_transientClients)) {
      client.close();
    }
    _transientClients.clear();
  }

  /// CloudBase 网关故障时可能返回 HTML（例如 503），不能直接 jsonDecode，
  /// 否则用户只能看到无意义的 FormatException: Unexpected character '<'。
  dynamic _decodeJson(http.Response res, {required String fallback}) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw ApiException(
        _responseError(res.statusCode, null, fallback),
        statusCode: res.statusCode,
        code: 'INVALID_JSON',
      );
    }
  }

  String _responseError(int statusCode, dynamic body, String fallback) {
    if (body is Map && body['error'] != null) {
      final message = body['error'].toString().trim();
      if (message.isNotEmpty) return message;
    }
    if (statusCode >= 500) {
      return '服务器暂时不可用，请稍后重试（HTTP $statusCode）';
    }
    return '$fallback（HTTP $statusCode）';
  }

  ApiException _apiException(
    http.Response res, {
    required dynamic body,
    required String fallback,
  }) {
    return ApiException(
      _responseError(res.statusCode, body, fallback),
      statusCode: res.statusCode,
      code: _responseCode(res, body),
    );
  }

  String _responseCode(http.Response res, dynamic body) {
    final code = body is Map ? body['code']?.toString().trim() : null;
    return code == null || code.isEmpty ? 'HTTP_${res.statusCode}' : code;
  }

  ApiException _responseShapeException(http.Response res, String message) =>
      ApiException(
        message,
        statusCode: res.statusCode,
        code: 'INVALID_RESPONSE_SHAPE',
      );

  String _responseErrorText(String raw, int statusCode, String fallback) {
    dynamic body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      body = null;
    }
    return _responseError(statusCode, body, fallback);
  }

  /// CloudBase 冷启动或移动网络切换时，认证请求可能短暂收到 502/503/504
  /// 或在连接层超时。认证写入按设备幂等，允许短暂退避后重试。
  Future<http.Response> _withTransientRetry(
    Future<http.Response> Function(IOClient client) request, {
    required Duration timeout,
  }) async {
    const attempts = 3;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (_disposed) throw StateError('API 客户端已释放');
      final client = _newHttpClient();
      _transientClients.add(client);
      try {
        final response = await request(client).timeout(timeout);
        final retryable =
            response.statusCode == 502 ||
            response.statusCode == 503 ||
            response.statusCode == 504;
        if (!retryable || attempt == attempts - 1) return response;
      } catch (_) {
        if (attempt == attempts - 1) rethrow;
      } finally {
        // Future.timeout 不会自动关闭底层 socket；每次重试结束后关闭本次
        // 专用客户端，不能触碰同时进行的共享 API 请求。
        _transientClients.remove(client);
        client.close();
      }
      await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
    }
    throw StateError('请求重试失败');
  }

  /// 对完整警情简报补充客户端任务标记。
  ///
  /// 服务端新版本会用 incident_brief 模式处理；客户端也保留这层标记，
  /// 兼容尚未完成滚动更新的网关，避免模型把真实警情当成普通闲聊。
  String _chatMessageForModel(String message) {
    if (!_looksLikeIncidentBrief(message)) return message;
    const instruction =
        '这是一条真实的现场警情简报，不是普通提问。请水元素直接进行现场辅助研判：先给警情性质和主要风险，再给立即处置要点、禁忌事项，并主动列出需核实的信息。不要反问用户想了解什么。\n\n原始警情：';
    final maxOriginalLength = 2000 - instruction.length;
    final original = message.length > maxOriginalLength
        ? message.substring(0, maxOriginalLength)
        : message;
    return '$instruction$original';
  }

  bool _looksLikeIncidentBrief(String text) {
    if (text.length < 20) return false;
    final factSignals = [
      RegExp(r'警情|报警|调度|派遣|出动|到场|现场|任务|通报'),
      RegExp(r'发现|发生|位于|有人|居民|被困|受伤|车辆|人员|住宅|建筑|路段'),
      RegExp(r'请求|需要|处置|救助|搜救|转移|警戒|封控'),
    ];
    return factSignals.where((pattern) => pattern.hasMatch(text)).length >= 2;
  }

  Future<String> transcribe(Uint8List audioBytes, {String? opId}) async {
    final res = await _client
        .post(
          _uri('/api/transcribe'),
          headers: {..._opHeaders(opId), 'Content-Type': 'audio/wav'},
          body: audioBytes,
        )
        .timeout(const Duration(seconds: 30));
    final body = _decodeJson(res, fallback: '转写失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '转写失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '转写响应格式异常');
    }
    return body['text'] as String? ?? '';
  }

  Future<ParseResult> parse(String text, {String? opId}) async {
    final res = await _client
        .post(
          _uri('/api/parse'),
          headers: _opHeaders(opId),
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 30));
    final body = _decodeJson(res, fallback: '解析失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '解析失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '解析响应格式异常');
    }
    return ParseResult.fromJson(body as Map<String, dynamic>);
  }

  Future<List<Entry>> fetchEntries({bool activeOnly = false}) async {
    final res = await _client
        .get(
          _uri('/api/entries${activeOnly ? '?active=1' : ''}'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取记录失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取记录失败');
    }
    if (body is! List) {
      throw _responseShapeException(res, '记录响应格式异常');
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
    final res = await _client
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
    final body = _decodeJson(res, fallback: '创建失败');
    if (res.statusCode == 409 && body is Map && body['entry'] != null) {
      throw EntryConflictException(
        body['error']?.toString() ?? '该人员已在火场内',
        Entry.fromJson(body['entry'] as Map<String, dynamic>),
      );
    }
    if (res.statusCode != 201) {
      throw _apiException(res, body: body, fallback: '创建失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '创建响应格式异常');
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
  }) async {
    final res = await _client
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
    final body = _decodeJson(res, fallback: '更新失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '更新失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '更新响应格式异常');
    }
    return Entry.fromJson(body as Map<String, dynamic>);
  }

  Future<void> markExited(String id, {String? opId}) async {
    final res = await _client
        .post(_uri('/api/entries/$id/exit'), headers: _opHeaders(opId))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '登记出火场失败');
      throw _apiException(res, body: body, fallback: '登记出火场失败');
    }
  }

  Future<List<Firefighter>> fetchFirefighters() async {
    final res = await _client
        .get(_uri('/api/firefighters'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取名单失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取名单失败');
    }
    if (body is! List) {
      throw _responseShapeException(res, '名单响应格式异常');
    }
    final list = body;
    return list
        .map((e) => Firefighter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> addFirefighter(String name) async {
    final res = await _client
        .post(
          _uri('/api/firefighters'),
          headers: _headers,
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '添加失败');
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw _apiException(res, body: body, fallback: '添加失败');
    }
    return res.statusCode == 201;
  }

  Future<void> removeFirefighter(String id) async {
    final res = await _client
        .delete(_uri('/api/firefighters/$id'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '删除失败');
      throw _apiException(res, body: body, fallback: '删除失败');
    }
  }

  Future<List<Hotword>> fetchHotwords() async {
    final res = await _client
        .get(_uri('/api/hotwords'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取词库失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取词库失败');
    }
    if (body is! List) {
      throw _responseShapeException(res, '词库响应格式异常');
    }
    final list = body;
    return list
        .map((e) => Hotword.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Note>> fetchNotes() async {
    final res = await _client
        .get(_uri('/api/notes'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取日志失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取日志失败');
    }
    if (body is! List) {
      throw _responseShapeException(res, '日志响应格式异常');
    }
    final list = body;
    return list.map((e) => Note.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Note> createNote({
    required String text,
    String? category,
    String? opId,
    String? author,
  }) async {
    final res = await _client
        .post(
          _uri('/api/notes'),
          headers: _opHeaders(opId),
          body: jsonEncode({
            'text': text,
            if (category != null) 'category': category,
            // 实名作者：随请求直接提交（本地实名，不依赖服务器 user_settings 同步时序/场景匹配）
            if (author != null && author.isNotEmpty) 'author': author,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '记录日志失败');
    if (res.statusCode != 201) {
      throw _apiException(res, body: body, fallback: '记录日志失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '日志响应格式异常');
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<Note> updateNote({
    required String id,
    String? text,
    String? category,
  }) async {
    final res = await _client
        .patch(
          _uri('/api/notes/$id'),
          headers: _headers,
          body: jsonEncode({
            if (text != null) 'text': text,
            if (category != null) 'category': category,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '编辑日志失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '编辑日志失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '日志响应格式异常');
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteNote(String id) async {
    final res = await _client
        .delete(_uri('/api/notes/$id'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '删除日志失败');
      throw _apiException(res, body: body, fallback: '删除日志失败');
    }
  }

  Future<void> addHotword(String word) async {
    final res = await _client
        .post(
          _uri('/api/hotwords'),
          headers: _headers,
          body: jsonEncode({'word': word}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '添加失败');
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw _apiException(res, body: body, fallback: '添加失败');
    }
  }

  Future<void> removeHotword(String id) async {
    final res = await _client
        .delete(_uri('/api/hotwords/$id'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '删除失败');
      throw _apiException(res, body: body, fallback: '删除失败');
    }
  }

  Future<CalcConfig> fetchConfig() async {
    final res = await _client
        .get(_uri('/api/config'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取配置失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取配置失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '配置响应格式异常');
    }
    return CalcConfig.fromJson(body as Map<String, dynamic>);
  }

  /// 拉取智能体问答历史（旧→新，供聊天室恢复上下文）
  Future<List<ChatMessage>> fetchChatMessages() async {
    final res = await _client
        .get(_uri('/api/chat'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取问答记录失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取问答记录失败');
    }
    if (body is! List) {
      throw _responseShapeException(res, '问答记录响应格式异常');
    }
    final list = body;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 发送普通提问。服务端默认联网检索；历史由客户端保存在本机，按需带入本轮请求，不在服务端落库。
  Future<ChatMessage> sendChatMessage(
    String message, {
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final modelMessage = _chatMessageForModel(message);
    final res = await _client
        .post(
          _uri('/api/chat'),
          headers: _opHeaders(opId),
          body: jsonEncode({
            'message': modelMessage,
            if (history.isNotEmpty) 'history': _chatHistoryPayload(history),
          }),
        )
        // 服务端联网检索最长约 90 秒，客户端留出少量网络传输余量。
        .timeout(const Duration(seconds: 100));
    final body = _decodeJson(res, fallback: '提问失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '提问失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '辅助问答响应格式异常');
    }
    final m = body;
    return ChatMessage(
      id: '',
      role: 'assistant',
      content: m['reply']?.toString() ?? '',
      createdAt:
          (m['created_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 流式提问（SSE）：服务端产出首个 token 后立即回调，避免等待完整答案。
  /// CloudBase 冷启动返回 502/503/504 时自动重试一次。
  Future<String> sendChatMessageStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final client = _newChatClient();
    _activeChatClient = client;
    final modelMessage = _chatMessageForModel(message);
    try {
      Future<String> request() async {
        Future<http.StreamedResponse> open() {
          final req = http.Request('POST', _uri('/api/chat'));
          req.headers.addAll(_opHeaders(opId));
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode({
            'message': modelMessage,
            'stream': 1,
            if (history.isNotEmpty) 'history': _chatHistoryPayload(history),
          });
          // 首字节允许 CloudBase 冷启动完成；首字节之后按流实时消费。
          return client.send(req).timeout(const Duration(seconds: 25));
        }

        var res = await open();
        if (res.statusCode == 502 ||
            res.statusCode == 503 ||
            res.statusCode == 504) {
          await res.stream.drain();
          await Future<void>.delayed(const Duration(milliseconds: 700));
          res = await open();
        }
        if (res.statusCode != 200) {
          final body = await res.stream.bytesToString();
          throw ApiException(_responseErrorText(body, res.statusCode, '提问失败'));
        }
        final full = StringBuffer();
        final parser = SseLineParser();
        final bodyStream = res.stream
            .transform(utf8.decoder)
            .timeout(
              const Duration(seconds: 20),
              onTimeout: (sink) =>
                  sink.addError(TimeoutException('辅助问答响应超时，请检查网络后重试')),
            );
        await for (final chunk in bodyStream) {
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
      }

      // 网络层在 DNS/连接异常时可能迟迟不结束 Future；给整个请求设置最终
      // 截止时间，并在超时分支关闭 Client，避免辅助页永久停留在思考态。
      final reply = await request().timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          client.close();
          throw TimeoutException('辅助问答响应超时，请检查网络后重试');
        },
      );
      if (reply.trim().isEmpty) {
        throw ApiException('辅助回复为空，请重试');
      }
      return reply;
    } finally {
      if (identical(_activeChatClient, client)) _activeChatClient = null;
      client.close();
    }
  }

  List<Map<String, String>> _chatHistoryPayload(List<ChatMessage> history) =>
      history
          .where(
            (message) =>
                (message.role == 'user' || message.role == 'assistant') &&
                message.content.trim().isNotEmpty,
          )
          .toList()
          .reversed
          .take(40)
          .toList()
          .reversed
          .map(
            (message) => {
              'role': message.role,
              'content': message.content.trim(),
            },
          )
          .toList();

  /// 清空本场景问答记录
  Future<void> clearChatMessages() async {
    final res = await _client
        .delete(_uri('/api/chat'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '清空问答记录失败');
      throw _apiException(res, body: body, fallback: '清空问答记录失败');
    }
  }

  /// 批量上报操作日志（每条带 op_id/stage/level/msg/data）
  Future<void> sendLogs(List<Map<String, dynamic>> logs) async {
    final res = await _client
        .post(
          _uri('/api/logs'),
          headers: _headers,
          body: jsonEncode({'logs': logs}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '日志上报失败');
      throw _apiException(res, body: body, fallback: '日志上报失败');
    }
  }

  /// 拉取云端用户设置（按 X-Device-Id 识别用户，按场景隔离）
  /// 返回 { settings: {...}, updatedAt: 服务器最近修改时间（无记录为 0） }
  Future<Map<String, dynamic>> fetchUserSettings() async {
    final res = await _client
        .get(_uri('/api/user-settings'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取云端设置失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取云端设置失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '云端设置响应格式异常');
    }
    return {
      'settings': body['settings'] is Map<String, dynamic>
          ? body['settings'] as Map<String, dynamic>
          : <String, dynamic>{},
      'updatedAt': (body['updated_at'] as num?)?.toInt() ?? 0,
    };
  }

  /// 推送本地用户设置到云端（全量覆盖白名单键）
  Future<void> pushUserSettings(Map<String, dynamic> settings) async {
    final res = await _client
        .put(
          _uri('/api/user-settings'),
          headers: _headers,
          body: jsonEncode({'settings': settings}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '同步设置失败');
      throw _apiException(res, body: body, fallback: '同步设置失败');
    }
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
      final res = await _client
          .get(_uri(path), headers: _headers)
          .timeout(const Duration(seconds: 10));
      final body = _decodeJson(res, fallback: '获取警情列表失败');
      if (res.statusCode != 200) {
        throw _apiException(res, body: body, fallback: '获取警情列表失败');
      }
      if (body is! List) {
        throw _responseShapeException(res, '获取警情列表响应格式异常');
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
    final res = await _client
        .post(
          _uri('/api/incidents'),
          headers: _opHeaders(opId),
          body: jsonEncode({'actor_name': realName}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '新建警情失败');
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
      throw _apiException(res, body: body, fallback: '新建警情失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '新建警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  /// 首次启动认证：校验单位验证码并登记本机实名。
  /// 认证请求不把验证码放入请求头，避免失败前被当成已认证业务请求。
  Future<Map<String, dynamic>> verifyUnit({
    required String unitName,
    required String unitCode,
    required String realName,
  }) async {
    final res = await _withTransientRetry(
      (client) => client.post(
        _uri('/api/auth/verify'),
        headers: {
          'Content-Type': 'application/json',
          if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
          if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
        },
        body: jsonEncode({
          'unit_name': unitName,
          'unit_code': unitCode,
          'real_name': realName,
        }),
      ),
      timeout: const Duration(seconds: 12),
    );
    final body = _decodeJson(res, fallback: '单位认证失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '单位认证失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '单位认证响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  /// 主动注销当前服务端会话；网络失败时由调用方继续清理本地凭据。
  Future<void> logout() async {
    final res = await _client
        .post(_uri('/api/auth/logout'), headers: _headers)
        .timeout(const Duration(seconds: 8));
    final body = _decodeJson(res, fallback: '退出认证失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '退出认证失败');
    }
  }

  Future<Incident> fetchIncident(String id) async {
    final res = await _client
        .get(_uri('/api/incidents/$id'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取警情失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取警情失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '获取警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> updateIncidentTitle(
    String id,
    String? title, {
    required int expectedVersion,
  }) async {
    final res = await _client
        .patch(
          _uri('/api/incidents/$id'),
          headers: {..._headers, 'X-Expected-Version': '$expectedVersion'},
          body: jsonEncode({
            'title': title,
            'expected_version': expectedVersion,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '修改警情名称失败');
    if (res.statusCode == 409) {
      throw _apiException(res, body: body, fallback: '警情已被其他设备修改，请刷新后重试');
    }
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '修改警情名称失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> archiveIncident(String id) async {
    final res = await _client
        .post(
          _uri('/api/incidents/$id/archive'),
          headers: _headers,
          body: jsonEncode({'confirm': true}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '归档警情失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '归档警情失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '归档警情响应格式异常');
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<List<IncidentForce>> fetchIncidentForces({
    String? forIncidentId,
  }) async {
    final id = forIncidentId ?? incidentId;
    final res = await _client
        .get(_uri('/api/incidents/$id/forces'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取参战力量失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取参战力量失败');
    }
    if (body is! List) {
      throw _responseShapeException(res, '参战力量响应格式异常');
    }
    final list = body;
    return list
        .map((e) => IncidentForce.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<IncidentForce> saveIncidentForce({
    String? forceId,
    required String stationName,
    String? stationId,
    required int vehicleCount,
    required int personnelCount,
    int? expectedVersion,
  }) async {
    final path = forceId == null
        ? '/api/incidents/$incidentId/forces'
        : '/api/incidents/$incidentId/forces/$forceId';
    final method = forceId == null ? _client.post : _client.patch;
    final res = await method(
      _uri(path),
      headers: _headers,
      body: jsonEncode({
        'station_name': stationName,
        if (stationId != null) 'station_id': stationId,
        'vehicle_count': vehicleCount,
        'personnel_count': personnelCount,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      }),
    ).timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '保存参战力量失败');
    if (res.statusCode == 409) {
      throw _apiException(res, body: body, fallback: '参战力量已被其他设备修改，请刷新后重试');
    }
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw _apiException(res, body: body, fallback: '保存参战力量失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '参战力量响应格式异常');
    }
    return IncidentForce.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteIncidentForce(String forceId) async {
    final res = await _client
        .delete(
          _uri('/api/incidents/$incidentId/forces/$forceId'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      final body = _decodeJson(res, fallback: '删除参战力量失败');
      throw _apiException(res, body: body, fallback: '删除参战力量失败');
    }
  }

  Future<List<Station>> fetchStations() async {
    final res = await _client
        .get(_uri('/api/stations'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取消防站名录失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取消防站名录失败');
    }
    if (body is! List) {
      throw _responseShapeException(res, '消防站名录响应格式异常');
    }
    final list = body;
    return list
        .map((e) => Station.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Station> createStation(String name) async {
    final res = await _client
        .post(
          _uri('/api/stations'),
          headers: _headers,
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '新增消防站失败');
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw _apiException(res, body: body, fallback: '新增消防站失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '消防站响应格式异常');
    }
    return Station.fromJson(body as Map<String, dynamic>);
  }

  Future<List<IncidentEvent>> fetchTimeline(
    String id, {
    int limit = 2000,
  }) async {
    final res = await _client
        .get(
          _uri('/api/incidents/$id/timeline?limit=$limit'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeJson(res, fallback: '获取火场复盘失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取火场复盘失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '火场复盘响应格式异常');
    }
    final rawEvents = body['events'];
    if (rawEvents is! List) {
      throw _responseShapeException(res, '火场复盘事件响应格式异常');
    }
    if (rawEvents.any((event) => event is! Map)) {
      throw _responseShapeException(res, '火场复盘事件项格式异常');
    }
    final list = rawEvents;
    return list
        .map((e) => IncidentEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> uploadOfflineOperations(
    List<Map<String, dynamic>> operations,
  ) async {
    final res = await _client
        .post(
          _uri('/api/incidents/$incidentId/offline-operations'),
          headers: _headers,
          body: jsonEncode({'operations': operations}),
        )
        .timeout(const Duration(seconds: 20));
    final body = _decodeJson(res, fallback: '离线数据补传失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '离线数据补传失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '离线补传响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> fetchProfile() async {
    final res = await _client
        .get(_uri('/api/profile'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '获取实名信息失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '获取实名信息失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '实名信息响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> saveProfile(String realName) async {
    final res = await _client
        .put(
          _uri('/api/profile'),
          headers: _headers,
          body: jsonEncode({'real_name': realName}),
        )
        .timeout(const Duration(seconds: 10));
    final body = _decodeJson(res, fallback: '保存实名失败');
    if (res.statusCode != 200) {
      throw _apiException(res, body: body, fallback: '保存实名失败');
    }
    if (body is! Map) {
      throw _responseShapeException(res, '实名信息响应格式异常');
    }
    return Map<String, dynamic>.from(body);
  }
}

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;
  ApiException(this.message, {this.statusCode, this.code});
  @override
  String toString() => message;
}

class IncidentCreateConflictException implements Exception {
  final String message;
  final Incident existing;

  IncidentCreateConflictException(this.message, this.existing);

  @override
  String toString() => message;
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
