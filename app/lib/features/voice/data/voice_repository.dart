import 'dart:convert';
import 'dart:typed_data';

import '../../../core/network/network.dart';
import '../../../services/settings.dart';
import 'models/voice_parse.dart';

class VoiceRepository {
  final ApiHttpTransport _transport;

  const VoiceRepository(this._transport);

  /// 实时 ASR 代理使用同一认证头，但通过 WebSocket 协议连接。
  Uri realtimeAsrUri() {
    return realtimeAsrUris().first;
  }

  /// 返回实时连接入口，首选云托管直连，直连 DNS/建连失败时再尝试同一
  /// 后端的历史 HTTP 网关。两个入口都是真实 WebSocket，不改变识别协议。
  List<Uri> realtimeAsrUris() {
    final bases = <String>[
      Settings.realtimeAsrBaseUrl,
      Settings.realtimeAsrFallbackBaseUrl,
    ];
    final result = <Uri>[];
    for (final base in bases) {
      if (!Settings.isSafeRealtimeUrl(base)) continue;
      final normalized = base.trim().replaceFirst(RegExp(r'/+$'), '');
      final httpUri = Uri.parse('$normalized/api/asr/stream');
      final uri = httpUri.replace(
        scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      );
      if (!result.contains(uri)) result.add(uri);
    }
    if (result.isEmpty) throw StateError('实时识别服务器地址不安全');
    return result;
  }

  Map<String, String> realtimeAsrHeaders({String? opId}) =>
      _transport.opHeaders(opId);

  Future<String> transcribe(Uint8List audioBytes, {String? opId}) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/transcribe'),
          headers: {..._transport.opHeaders(opId), 'Content-Type': 'audio/wav'},
          body: audioBytes,
        )
        .timeout(const Duration(seconds: 30));
    final body = _transport.decodeJson(res, fallback: '转写失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '转写失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '转写响应格式异常');
    }
    return body['text'] as String? ?? '';
  }

  /// 视频口述允许不关联警情，音频经过现有单位认证发送到服务器。
  Future<String> transcribeMedia(Uint8List audioBytes, {String? opId}) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/media/transcribe'),
          headers: {..._transport.opHeaders(opId), 'Content-Type': 'audio/wav'},
          body: audioBytes,
        )
        .timeout(const Duration(seconds: 30));
    final body = _transport.decodeJson(res, fallback: '视频语音转写失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '视频语音转写失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '转写响应格式异常');
    }
    return body['text'] as String? ?? '';
  }

  Future<ParseResult> parse(String text, {String? opId}) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/parse'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 30));
    final body = _transport.decodeJson(res, fallback: '解析失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '解析失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '解析响应格式异常');
    }
    return ParseResult.fromJson(body as Map<String, dynamic>);
  }
}
