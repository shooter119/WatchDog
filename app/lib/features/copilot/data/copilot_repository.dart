import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../core/network/network.dart';
import 'models/chat_message.dart';
import 'models/vision_analysis.dart';

class CopilotRepository {
  final ApiHttpTransport _transport;

  const CopilotRepository(this._transport);

  /// 对完整警情简报补充客户端任务标记。
  ///
  /// 服务端新版本会用 incident_brief 模式处理；客户端也保留这层标记，
  /// 兼容尚未完成滚动更新的网关，避免模型把真实警情当成普通闲聊。
  String _chatMessageForModel(String message) {
    if (!_looksLikeIncidentBrief(message)) return message;
    const instruction =
        '这是一条真实的现场警情简报，不是普通提问。请水元素按80~120字火场口令卡直接研判（1句核心风险判断+最多3条立即处置与禁忌短句），正文中严禁反问；需核实或展开的问题放入末尾 <<<FOLLOW_UPS>>>。\n\n原始警情：';
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

  /// 拉取智能体问答历史（旧→新，供聊天室恢复上下文）
  Future<List<ChatMessage>> fetchChatMessages() async {
    final res = await _transport.client
        .get(_transport.uri('/api/chat'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取问答记录失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取问答记录失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '问答记录响应格式异常');
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
    final res = await _transport.client
        .post(
          _transport.uri('/api/chat'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({
            'message': modelMessage,
            'history_incident_id': _transport.config.incidentId,
            'follow_ups_protocol': 'v2',
            if (history.isNotEmpty) 'history': _chatHistoryPayload(history),
          }),
        )
        // 服务端联网检索最长约 90 秒，客户端留出少量网络传输余量。
        .timeout(const Duration(seconds: 100));
    final body = _transport.decodeJson(res, fallback: '提问失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '提问失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '辅助问答响应格式异常');
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
  /// 后端启动返回 502/503/504 时自动重试一次。
  Future<String> sendChatMessageStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final client = _transport.openChatClient();
    final modelMessage = _chatMessageForModel(message);
    try {
      Future<String> request() async {
        Future<http.StreamedResponse> open() {
          final req = http.Request('POST', _transport.uri('/api/chat'));
          req.headers.addAll(_transport.opHeaders(opId));
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode({
            'message': modelMessage,
            'history_incident_id': _transport.config.incidentId,
            'follow_ups_protocol': 'v2',
            'stream': 1,
            if (history.isNotEmpty) 'history': _chatHistoryPayload(history),
          });
          // 首字节允许后端启动完成；首字节之后按流实时消费。
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
          throw _transport.streamedApiException(res, body, fallback: '提问失败');
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
      _transport.releaseChatClient(client);
    }
  }

  Future<VisionAnalysis> analyzeVision(
    Uint8List bytes, {
    required String mimeType,
    String message = '',
    String? opId,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _transport.uri('/api/chat/vision'),
    );
    request.headers.addAll(_transport.opHeaders(opId)..remove('Content-Type'));
    request.fields['message'] = message.trim();
    request.files.add(
      http.MultipartFile.fromBytes(
        'image',
        bytes,
        filename: 'vision.jpg',
        contentType: _mediaType(mimeType),
      ),
    );
    final response = await _transport.client
        .send(request)
        .timeout(const Duration(seconds: 100));
    final res = await http.Response.fromStream(response);
    final body = _transport.decodeJson(res, fallback: '图片分析失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '图片分析失败');
    }
    if (body is! Map || body['analysis'] is! Map) {
      throw _transport.responseShapeException(res, '图片分析响应格式异常');
    }
    return VisionAnalysis.fromJson(
      Map<String, dynamic>.from(body['analysis'] as Map),
    );
  }

  MediaType _mediaType(String mimeType) {
    final parts = mimeType.split('/');
    return MediaType(parts.first, parts.length > 1 ? parts[1] : 'jpeg');
  }

  List<Map<String, String>> _chatHistoryPayload(List<ChatMessage> history) {
    final followUpDelimiter = RegExp(
      r'\n?<{2,3}\s*FOLLOW_UPS\s*>{2,3}[\s\S]*$',
      caseSensitive: false,
    );
    return history
        .where(
          (message) =>
              (message.role == 'user' || message.role == 'assistant') &&
              message.content.trim().isNotEmpty,
        )
        .map(
          (message) => {
            'role': message.role,
            'content': message.content.replaceFirst(followUpDelimiter, '').trim(),
          },
        )
        .where((entry) => entry['content']!.isNotEmpty)
        .toList()
        .reversed
        .take(40)
        .toList()
        .reversed
        .toList();
  }

  /// 清空本场景问答记录
  Future<void> clearChatMessages() async {
    final res = await _transport.client
        .delete(_transport.uri('/api/chat'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '清空问答记录失败');
      throw _transport.apiException(res, body: body, fallback: '清空问答记录失败');
    }
  }
}
