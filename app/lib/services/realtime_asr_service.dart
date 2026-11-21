import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../api/api_client.dart';
import '../core/diagnostics/app_logger.dart';
import 'audio_service.dart';
import 'resilient_dns.dart';

typedef RealtimeTextCallback =
    void Function(String text, {required bool finalText});
typedef RealtimeAsrSocketFactory =
    Future<WebSocket> Function(
      String url, {
      Map<String, dynamic>? headers,
      CompressionOptions compression,
    });

class RealtimeAsrResult {
  final String text;
  final Uint8List wavBytes;

  const RealtimeAsrResult({required this.text, required this.wavBytes});
}

/// 负责实时 PCM 采集与 WatchDog ASR WebSocket 会话。
/// 火山密钥不在此层出现；客户端只连接自有后端代理。
class RealtimeAsrService {
  final ApiClient api;
  final AudioRecorder _recorder;
  final RealtimeTextCallback? onText;
  final RealtimeAsrSocketFactory _socketFactory;
  final int maxAudioBytes;
  final int packetBytes;

  WebSocket? _socket;
  StreamSubscription<Uint8List>? _audioSub;
  Completer<void>? _done;
  Future<void>? _connectTask;
  final BytesBuilder _audio = BytesBuilder(copy: false);
  final BytesBuilder _pending = BytesBuilder(copy: false);
  String _lastText = '';
  bool _hasFinal = false;
  bool _started = false;
  bool _stopping = false;
  bool _cancelled = false;
  int _sessionId = 0;
  Object? _socketError;
  Object? _captureError;
  int _audioBytes = 0;
  int _audioChunks = 0;
  int _resultCount = 0;

  @visibleForTesting
  Future<void>? get pendingConnectTask => _connectTask;

  RealtimeAsrService({
    required this.api,
    this.onText,
    AudioRecorder? recorder,
    RealtimeAsrSocketFactory? socketFactory,
    this.maxAudioBytes = 2 * 1024 * 1024,
    this.packetBytes = 3200,
  }) : _recorder = recorder ?? AudioRecorder(),
       _socketFactory = socketFactory ?? connectResilientWebSocket;

  Future<void> start({String? opId}) async {
    if (_started) throw StateError('实时语音会话已启动');
    final sessionId = ++_sessionId;
    _started = true;
    _stopping = false;
    _cancelled = false;
    _done = Completer<void>();
    try {
      final uris = api.realtimeAsrUris();
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          streamBufferSize: 3200,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceRecognition,
          ),
        ),
      );
      if (sessionId != _sessionId || !_started || _stopping || _cancelled) {
        await _cleanupRecorder();
        if (sessionId == _sessionId) _reset();
        return;
      }
      _audioSub = stream.listen(_onAudio, onError: _onCaptureError);
      AppLogger.log(
        'Realtime ASR capture ready chunks=$_audioChunks bytes=$_audioBytes opId=${opId ?? '-'}',
        tag: 'asr',
      );
      // 本地麦克风就绪后立即返回让页面进入录音态，WebSocket 在后台异步建连并
      // 冲刷缓冲音频，避免弱网/冷启动握手阻塞导致松手被误判取消。
      _connectTask = _establishSocketSession(
        uris,
        sessionId: sessionId,
        opId: opId,
      );
    } catch (error) {
      await _cleanupRecorder();
      await _closeSocket();
      _reset();
      rethrow;
    }
  }

  Future<void> _establishSocketSession(
    List<Uri> uris, {
    required int sessionId,
    String? opId,
  }) async {
    try {
      final socket = await _connectSocket(uris, opId: opId);
      if (sessionId != _sessionId || !_started || _stopping || _cancelled) {
        try {
          socket.listen((_) {}, onError: (_) {});
          await socket.close(WebSocketStatus.normalClosure);
        } catch (_) {}
        return;
      }
      _socket = socket;
      socket.listen(
        (message) {
          if (sessionId == _sessionId) _onSocketMessage(message);
        },
        onError: (Object error, StackTrace stack) {
          if (sessionId == _sessionId) _onSocketError(error, stack);
        },
        onDone: () {
          if (sessionId == _sessionId) _onSocketDone();
        },
      );
      socket.add(jsonEncode({'type': 'start', 'opId': opId ?? ''}));
      _flushPendingAudio(flushRemainder: false);
    } catch (error, stack) {
      if (sessionId == _sessionId) {
        _onSocketError(error, stack);
      }
    }
  }

  Future<WebSocket> _connectSocket(List<Uri> uris, {String? opId}) async {
    Object? lastError;
    for (final uri in uris) {
      AppLogger.log(
        'Realtime ASR connect host=${uri.host} path=${uri.path} opId=${opId ?? '-'}',
        tag: 'asr',
      );
      try {
        final socket = await _socketFactory(
          uri.toString(),
          headers: api.realtimeAsrHeaders(opId: opId),
          compression: CompressionOptions.compressionDefault,
        ).timeout(const Duration(seconds: 12));
        AppLogger.log(
          'Realtime ASR websocket open host=${uri.host} opId=${opId ?? '-'}',
          tag: 'asr',
        );
        return socket;
      } catch (error) {
        lastError = error;
        AppLogger.error(
          'Realtime ASR websocket connect failed host=${uri.host}',
          tag: 'asr',
          error: error,
        );
      }
    }
    throw lastError ?? StateError('实时识别连接失败');
  }

  Stream<double> amplitudeStream() => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map((value) => normalizeAmplitudeDbfs(value.current));

  void _onAudio(Uint8List chunk) {
    if (_stopping || _cancelled || chunk.isEmpty) return;
    if (_audio.length + chunk.length > maxAudioBytes) {
      _captureError ??= StateError('实时录音超过大小限制');
      _onSocketError(_captureError!);
      return;
    }
    _audio.add(chunk);
    _audioBytes += chunk.length;
    _audioChunks++;
    if (_audioChunks == 1 || _audioChunks % 50 == 0) {
      AppLogger.log(
        'Realtime ASR audio chunks=$_audioChunks bytes=$_audioBytes',
        tag: 'asr',
      );
    }
    if (_socketError != null) {
      _pending.clear();
      return;
    }
    _pending.add(chunk);
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      _flushPendingAudio(flushRemainder: false);
    }
  }

  void _flushPendingAudio({required bool flushRemainder}) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    final bytes = _pending.takeBytes();
    if (bytes.isEmpty) return;
    var offset = 0;
    while (bytes.length - offset >= packetBytes) {
      _sendAudio(bytes.sublist(offset, offset + packetBytes));
      offset += packetBytes;
    }
    if (offset < bytes.length) {
      final tail = bytes.sublist(offset);
      if (flushRemainder) {
        _sendAudio(tail);
      } else {
        _pending.add(tail);
      }
    }
  }

  void _sendAudio(Uint8List bytes) {
    final socket = _socket;
    if (socket == null ||
        socket.readyState != WebSocket.open ||
        bytes.isEmpty) {
      return;
    }
    socket.add(bytes);
  }

  void _onSocketMessage(dynamic message) {
    if (message is! String) return;
    try {
      final value = jsonDecode(message);
      if (value is! Map) return;
      final type = value['type']?.toString();
      if (type == 'partial' || type == 'final') {
        final text = value['text']?.toString().trim() ?? '';
        if (text.isEmpty) return;
        _resultCount++;
        _lastText = text;
        if (type == 'final') _hasFinal = true;
        AppLogger.log(
          'Realtime ASR result type=$type chars=${text.length} count=$_resultCount',
          tag: 'asr',
        );
        onText?.call(text, finalText: type == 'final');
      } else if (type == 'ready') {
        AppLogger.log(
          'Realtime ASR server ready hotwords=${value['hotwordCount'] ?? '-'}',
          tag: 'asr',
        );
      } else if (type == 'error') {
        AppLogger.error(
          'Realtime ASR server error: ${value['code'] ?? '-'} ${value['message'] ?? ''}',
          tag: 'asr',
        );
        _onSocketError(StateError(value['message']?.toString() ?? '实时识别失败'));
      } else if (type == 'done' && !(_done?.isCompleted ?? true)) {
        _done!.complete();
      }
    } catch (error) {
      _onSocketError(error);
    }
  }

  void _onCaptureError(Object error, [StackTrace? stack]) {
    _captureError ??= error;
    _onSocketError(error, stack);
  }

  void _onSocketError(Object error, [StackTrace? stack]) {
    _socketError ??= error;
    _pending.clear();
    AppLogger.error(
      'Realtime ASR socket error',
      tag: 'asr',
      error: error,
      stackTrace: stack,
    );
    // 录音期间用户尚未 await _done.future；若此处调用 completeError 会在无监听器
    // 时向 Zone 抛出未捕获异步错误。记录 _socketError 后正常 complete 即可。
    if (!(_done?.isCompleted ?? true)) _done!.complete();
  }

  void _onSocketDone() {
    AppLogger.log(
      'Realtime ASR websocket done stopping=$_stopping',
      tag: 'asr',
    );
    // stop() 会先完成结果并重置状态，底层 WebSocket 的 onDone 可能在
    // reset 之后才异步到达；这属于正常收口，不能再伪造“连接已断开”。
    if (_stopping || _done == null || _hasFinal || _done!.isCompleted) {
      return;
    }
    _onSocketError(StateError('实时识别连接已断开'));
  }

  Future<RealtimeAsrResult> stop() async {
    if (!_started) throw StateError('实时语音会话未启动');
    _stopping = true;
    await _cleanupRecorder();
    final socket = _socket;
    if (socket != null &&
        socket.readyState == WebSocket.open &&
        _socketError == null) {
      try {
        _flushPendingAudio(flushRemainder: true);
        socket.add(jsonEncode({'type': 'stop'}));
        await _done!.future.timeout(const Duration(seconds: 5));
      } catch (error) {
        _socketError ??= error;
        if (!(_done?.isCompleted ?? true)) _done!.complete();
      }
    } else {
      _cancelled = true;
    }
    await _closeSocket();
    final error =
        _captureError ??
        _socketError ??
        (!_hasFinal
            ? StateError(
                socket == null ? '实时识别连接未就绪，改用批量识别' : '实时识别未收到最终结果',
              )
            : null);
    final result = RealtimeAsrResult(
      text: _lastText,
      wavBytes: _toWav(_audio.takeBytes()),
    );
    AppLogger.log(
      'Realtime ASR stop bytes=$_audioBytes chunks=$_audioChunks results=$_resultCount final=$_hasFinal',
      tag: 'asr',
    );
    _reset();
    if (error != null) throw RealtimeAsrException(error, result);
    return result;
  }

  Future<Uint8List> cancel() async {
    _cancelled = true;
    _stopping = true;
    await _cleanupRecorder();
    await _closeSocket();
    final bytes = _toWav(_audio.takeBytes());
    _reset();
    return bytes;
  }

  Future<void> dispose() async {
    if (_started) await cancel();
    await _recorder.dispose();
  }

  Future<void> _cleanupRecorder() async {
    final sub = _audioSub;
    _audioSub = null;
    await sub?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  Future<void> _closeSocket() async {
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  void _reset() {
    _sessionId++;
    _started = false;
    _stopping = false;
    _cancelled = false;
    _done = null;
    _connectTask = null;
    _pending.clear();
    _lastText = '';
    _hasFinal = false;
    _socketError = null;
    _captureError = null;
    _audioBytes = 0;
    _audioChunks = 0;
    _resultCount = 0;
  }

  Uint8List _toWav(Uint8List pcm) {
    final out = BytesBuilder(copy: false);
    void u16(int value) => out.add(
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little),
    );
    void u32(int value) => out.add(
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little),
    );
    out.add(utf8.encode('RIFF'));
    u32(36 + pcm.length);
    out.add(utf8.encode('WAVE'));
    out.add(utf8.encode('fmt '));
    u32(16);
    u16(1);
    u16(1);
    u32(16000);
    u32(32000);
    u16(2);
    u16(16);
    out.add(utf8.encode('data'));
    u32(pcm.length);
    out.add(pcm);
    return out.takeBytes();
  }
}

class RealtimeAsrException implements Exception {
  final Object cause;
  final RealtimeAsrResult result;

  const RealtimeAsrException(this.cause, this.result);

  @override
  String toString() => 'RealtimeAsrException: $cause';
}
