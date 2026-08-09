import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';

class ApiClient {
  final String baseUrl;
  final String incidentId;
  final String apiToken;
  final String deviceId;
  final String actorName;

  ApiClient({
    required this.baseUrl,
    required this.incidentId,
    this.apiToken = '',
    this.deviceId = '',
    this.actorName = '',
  });

  ApiClient forIncident(String id) => ApiClient(
    baseUrl: baseUrl,
    incidentId: id,
    apiToken: apiToken,
    deviceId: deviceId,
    actorName: actorName,
  );

  /// 辅助 AI 不属于任何警情，也不参与警情协同。
  ApiClient forAssistant() => ApiClient(
    baseUrl: baseUrl,
    incidentId: '',
    apiToken: apiToken,
    deviceId: deviceId,
    actorName: actorName,
  );

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (incidentId.isNotEmpty) 'X-Incident-Id': incidentId,
    if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
    if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
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

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<String> transcribe(Uint8List audioBytes, {String? opId}) async {
    final res = await http
        .post(
          _uri('/api/transcribe'),
          headers: {..._opHeaders(opId), 'Content-Type': 'audio/wav'},
          body: audioBytes,
        )
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '转写失败(${res.statusCode})',
      );
    }
    return (body as Map)['text'] as String? ?? '';
  }

  Future<ParseResult> parse(String text, {String? opId}) async {
    final res = await http
        .post(
          _uri('/api/parse'),
          headers: _opHeaders(opId),
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '解析失败(${res.statusCode})',
      );
    }
    return ParseResult.fromJson(body as Map<String, dynamic>);
  }

  Future<List<Entry>> fetchEntries({bool activeOnly = false}) async {
    final res = await http
        .get(
          _uri('/api/entries${activeOnly ? '?active=1' : ''}'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 10));
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
      throw ApiException(
        (body as Map)['error']?.toString() ?? '创建失败(${res.statusCode})',
      );
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
      throw ApiException(
        (body as Map)['error']?.toString() ?? '更新失败(${res.statusCode})',
      );
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
    return list
        .map((e) => Firefighter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addFirefighter(String name) async {
    final res = await http
        .post(
          _uri('/api/firefighters'),
          headers: _headers,
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw ApiException('添加失败(${res.statusCode})');
    }
  }

  Future<void> removeFirefighter(String id) async {
    final res = await http.delete(
      _uri('/api/firefighters/$id'),
      headers: _headers,
    );
    if (res.statusCode != 200) throw ApiException('删除失败(${res.statusCode})');
  }

  Future<List<Hotword>> fetchHotwords() async {
    final res = await http.get(_uri('/api/hotwords'), headers: _headers);
    if (res.statusCode != 200) throw ApiException('获取词库失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list
        .map((e) => Hotword.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Note>> fetchNotes() async {
    final res = await http
        .get(_uri('/api/notes'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取日志失败(${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list.map((e) => Note.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Note> createNote({
    required String text,
    String? category,
    String? opId,
    String? author,
  }) async {
    final res = await http
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
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 201) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '记录日志失败(${res.statusCode})',
      );
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<Note> updateNote({
    required String id,
    String? text,
    String? category,
  }) async {
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
      throw ApiException(
        (body as Map)['error']?.toString() ?? '编辑日志失败(${res.statusCode})',
      );
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteNote(String id) async {
    final res = await http
        .delete(_uri('/api/notes/$id'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw ApiException('删除日志失败(${res.statusCode})');
  }

  Future<void> addHotword(String word) async {
    final res = await http
        .post(
          _uri('/api/hotwords'),
          headers: _headers,
          body: jsonEncode({'word': word}),
        )
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
    final res = await http
        .get(_uri('/api/config'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('获取配置失败(${res.statusCode})');
    return CalcConfig.fromJson(
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
    );
  }

  /// 拉取智能体问答历史（旧→新，供聊天室恢复上下文）
  Future<List<ChatMessage>> fetchChatMessages() async {
    final res = await http
        .get(_uri('/api/chat'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('获取问答记录失败(${res.statusCode})');
    }
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
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
    final res = await http
        .post(
          _uri('/api/chat'),
          headers: _opHeaders(opId),
          body: jsonEncode({
            'message': message,
            if (history.isNotEmpty) 'history': _chatHistoryPayload(history),
          }),
        )
        // 服务端联网检索最长约 90 秒，客户端留出少量网络传输余量。
        .timeout(const Duration(seconds: 100));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '提问失败(${res.statusCode})',
      );
    }
    final m = body as Map;
    return ChatMessage(
      id: '',
      role: 'assistant',
      content: m['reply']?.toString() ?? '',
      createdAt:
          (m['created_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 兼容旧客户端的流式提问（SSE）；当前辅助页不使用此接口，因为它不走联网检索。
  /// 服务端回复完成才落库，本地无需额外保存。
  Future<String> sendChatMessageStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('POST', _uri('/api/chat'));
      req.headers.addAll(_opHeaders(opId));
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({
        'message': message,
        'stream': 1,
        if (history.isNotEmpty) 'history': _chatHistoryPayload(history),
      });
      // 首字节 15s 超时（流式下无需等待整条回复，60s 总超时问题随之消失）
      final res = await client.send(req).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        final body = await res.stream.bytesToString();
        final m = jsonDecode(body) as Map?;
        throw ApiException(
          m?['error']?.toString() ?? '提问失败(${res.statusCode})',
        );
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
    final res = await http
        .delete(_uri('/api/chat'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('清空问答记录失败(${res.statusCode})');
    }
  }

  /// 批量上报操作日志（每条带 op_id/stage/level/msg/data）
  Future<void> sendLogs(List<Map<String, dynamic>> logs) async {
    final res = await http
        .post(
          _uri('/api/logs'),
          headers: _headers,
          body: jsonEncode({'logs': logs}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiException('日志上报失败(${res.statusCode})');
  }

  /// 拉取云端用户设置（按 X-Device-Id 识别用户，按场景隔离）
  /// 返回 { settings: {...}, updatedAt: 服务器最近修改时间（无记录为 0） }
  Future<Map<String, dynamic>> fetchUserSettings() async {
    final res = await http
        .get(_uri('/api/user-settings'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('获取云端设置失败(${res.statusCode})');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return {
      'settings': body['settings'] is Map<String, dynamic>
          ? body['settings'] as Map<String, dynamic>
          : <String, dynamic>{},
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

  Future<List<Incident>> fetchIncidents({String? status}) async {
    final path = status == null
        ? '/api/incidents'
        : '/api/incidents?status=${Uri.encodeQueryComponent(status)}';
    final res = await http
        .get(_uri(path), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('获取警情列表失败(${res.statusCode})');
    }
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list
        .map((e) => Incident.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Incident> createIncident({
    required String realName,
    String? opId,
  }) async {
    final res = await http
        .post(
          _uri('/api/incidents'),
          headers: _opHeaders(opId),
          body: jsonEncode({'actor_name': realName}),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 201) {
      if (res.statusCode == 409 &&
          body is Map &&
          body['code'] == 'INCIDENT_CREATE_COOLDOWN' &&
          body['incident'] is Map) {
        throw IncidentCreateConflictException(
          body['error']?.toString() ?? '刚刚已有用户新建警情，请优先加入现有警情',
          Incident.fromJson(Map<String, dynamic>.from(body['incident'] as Map)),
        );
      }
      throw ApiException(
        (body as Map)['error']?.toString() ?? '新建警情失败(${res.statusCode})',
      );
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> fetchIncident(String id) async {
    final res = await http
        .get(_uri('/api/incidents/$id'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '获取警情失败(${res.statusCode})',
      );
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> updateIncidentTitle(
    String id,
    String? title, {
    required int expectedVersion,
  }) async {
    final res = await http
        .patch(
          _uri('/api/incidents/$id'),
          headers: {..._headers, 'X-Expected-Version': '$expectedVersion'},
          body: jsonEncode({
            'title': title,
            'expected_version': expectedVersion,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 409) throw ApiException('警情已被其他设备修改，请刷新后重试');
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '修改警情名称失败(${res.statusCode})',
      );
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<Incident> archiveIncident(String id) async {
    final res = await http
        .post(
          _uri('/api/incidents/$id/archive'),
          headers: _headers,
          body: jsonEncode({'confirm': true}),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '归档警情失败(${res.statusCode})',
      );
    }
    return Incident.fromJson(body as Map<String, dynamic>);
  }

  Future<List<IncidentForce>> fetchIncidentForces({
    String? forIncidentId,
  }) async {
    final id = forIncidentId ?? incidentId;
    final res = await http
        .get(_uri('/api/incidents/$id/forces'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('获取参战力量失败(${res.statusCode})');
    }
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
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
    final method = forceId == null ? http.post : http.patch;
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
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 409) throw ApiException('参战力量已被其他设备修改，请刷新后重试');
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '保存参战力量失败(${res.statusCode})',
      );
    }
    return IncidentForce.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteIncidentForce(String forceId) async {
    final res = await http
        .delete(
          _uri('/api/incidents/$incidentId/forces/$forceId'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw ApiException('删除参战力量失败(${res.statusCode})');
    }
  }

  Future<List<Station>> fetchStations() async {
    final res = await http
        .get(_uri('/api/stations'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('获取消防站名录失败(${res.statusCode})');
    }
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return list
        .map((e) => Station.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Station> createStation(String name) async {
    final res = await http
        .post(
          _uri('/api/stations'),
          headers: _headers,
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 201 && res.statusCode != 409) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '新增消防站失败(${res.statusCode})',
      );
    }
    return Station.fromJson(body as Map<String, dynamic>);
  }

  Future<List<IncidentEvent>> fetchTimeline(
    String id, {
    int limit = 2000,
  }) async {
    final res = await http
        .get(
          _uri('/api/incidents/$id/timeline?limit=$limit'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '获取火场复盘失败(${res.statusCode})',
      );
    }
    final list = (body as Map)['events'] as List? ?? const [];
    return list
        .map((e) => IncidentEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> uploadOfflineOperations(
    List<Map<String, dynamic>> operations,
  ) async {
    final res = await http
        .post(
          _uri('/api/incidents/$incidentId/offline-operations'),
          headers: _headers,
          body: jsonEncode({'operations': operations}),
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '离线数据补传失败(${res.statusCode})',
      );
    }
    return Map<String, dynamic>.from(body as Map);
  }

  Future<Map<String, dynamic>> fetchProfile() async {
    final res = await http
        .get(_uri('/api/profile'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('获取实名信息失败(${res.statusCode})');
    }
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(res.bodyBytes)) as Map,
    );
  }

  Future<Map<String, dynamic>> saveProfile(String realName) async {
    final res = await http
        .put(
          _uri('/api/profile'),
          headers: _headers,
          body: jsonEncode({'real_name': realName}),
        )
        .timeout(const Duration(seconds: 10));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException(
        (body as Map)['error']?.toString() ?? '保存实名失败(${res.statusCode})',
      );
    }
    return Map<String, dynamic>.from(body as Map);
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
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
