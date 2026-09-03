import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../api/api_client.dart';
import 'audio_service.dart';

typedef RealtimeTextCallback =
    void Function(String text, {required bool finalText});

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
  final int maxAudioBytes;
  final int packetBytes;

  WebSocket? _socket;
  StreamSubscription<Uint8List>? _audioSub;
  Completer<void>? _done;
  final BytesBuilder _audio = BytesBuilder(copy: false);
  final BytesBuilder _pending = BytesBuilder(copy: false);
  String _lastText = '';
  bool _hasFinal = false;
  bool _started = false;
  bool _stopping = false;
  Object? _socketError;
  int _audioBytes = 0;
  int _audioChunks = 0;
  int _resultCount = 0;

  RealtimeAsrService({
    required this.api,
    this.onText,
    AudioRecorder? recorder,
    this.maxAudioBytes = 2 * 1024 * 1024,
    this.packetBytes = 3200,
  }) : _recorder = recorder ?? AudioRecorder();

  Future<void> start({String? opId}) async {
    if (_started) throw StateError('实时语音会话已启动');
    _started = true;
    _done = Completer<void>();
    try {
      final uris = api.realtimeAsrUris();
      final captureFuture = _recorder.startStream(
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
      final socketFuture = _connectSocket(uris, opId: opId);
      final values = await Future.wait<Object>([captureFuture, socketFuture]);
      final stream = values[0] as Stream<Uint8List>;
      _socket = values[1] as WebSocket;
      debugPrint(
        'Realtime ASR capture ready chunks=$_audioChunks bytes=$_audioBytes opId=${opId ?? '-'}',
      );
      _socket!.listen(
        _onSocketMessage,
        onError: _onSocketError,
        onDone: _onSocketDone,
      );
      _socket!.add(jsonEncode({'type': 'start', 'opId': opId ?? ''}));
      _audioSub = stream.listen(_onAudio, onError: _onSocketError);
    } catch (error) {
      await _cleanupRecorder();
      await _closeSocket();
      _started = false;
      rethrow;
    }
  }

  Future<WebSocket> _connectSocket(List<Uri> uris, {String? opId}) async {
    Object? lastError;
    for (final uri in uris) {
      debugPrint(
        'Realtime ASR connect host=${uri.host} path=${uri.path} opId=${opId ?? '-'}',
      );
      try {
        final socket = await WebSocket.connect(
          uri.toString(),
          headers: api.realtimeAsrHeaders(opId: opId),
          compression: CompressionOptions.compressionDefault,
        ).timeout(const Duration(seconds: 12));
        debugPrint(
          'Realtime ASR websocket open host=${uri.host} opId=${opId ?? '-'}',
        );
        return socket;
      } catch (error) {
        lastError = error;
        debugPrint(
          'Realtime ASR websocket connect failed host=${uri.host} error=$error',
        );
      }
    }
    throw lastError ?? StateError('实时识别连接失败');
  }

  Stream<double> amplitudeStream() => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map((value) => normalizeAmplitudeDbfs(value.current));

  void _onAudio(Uint8List chunk) {
    if (_stopping || chunk.isEmpty) return;
    if (_audio.length + chunk.length > maxAudioBytes) {
      _onSocketError(StateError('实时录音超过大小限制'));
      return;
    }
    _audio.add(chunk);
    _audioBytes += chunk.length;
    _audioChunks++;
    if (_audioChunks == 1 || _audioChunks % 50 == 0) {
      debugPrint('Realtime ASR audio chunks=$_audioChunks bytes=$_audioBytes');
    }
    _pending.add(chunk);
    final bytes = _pending.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= packetBytes) {
      _sendAudio(bytes.sublist(offset, offset + packetBytes));
      offset += packetBytes;
    }
    if (offset < bytes.length) _pending.add(bytes.sublist(offset));
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
        debugPrint(
          'Realtime ASR result type=$type chars=${text.length} count=$_resultCount',
        );
        onText?.call(text, finalText: type == 'final');
      } else if (type == 'ready') {
        debugPrint(
          'Realtime ASR server ready hotwords=${value['hotwordCount'] ?? '-'}',
        );
      } else if (type == 'error') {
        debugPrint(
          'Realtime ASR server error: ${value['code'] ?? '-'} ${value['message'] ?? ''}',
        );
        _onSocketError(StateError(value['message']?.toString() ?? '实时识别失败'));
      } else if (type == 'done' && !(_done?.isCompleted ?? true)) {
        _done!.complete();
      }
    } catch (error) {
      _onSocketError(error);
    }
  }

  void _onSocketError(Object error, [StackTrace? stack]) {
    _socketError ??= error;
    debugPrint('Realtime ASR socket error: $error');
    if (!(_done?.isCompleted ?? true)) _done!.completeError(error, stack);
  }

  void _onSocketDone() {
    debugPrint('Realtime ASR websocket done stopping=$_stopping');
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
    final rest = _pending.takeBytes();
    _sendAudio(rest);
    final socket = _socket;
    if (socket != null && socket.readyState == WebSocket.open) {
      socket.add(jsonEncode({'type': 'stop'}));
      try {
        await _done!.future.timeout(const Duration(seconds: 5));
      } catch (error, stack) {
        _socketError ??= error;
        if (!(_done?.isCompleted ?? true)) _done!.completeError(error, stack);
      }
    }
    await _closeSocket();
    final error =
        _socketError ?? (!_hasFinal ? StateError('实时识别未收到最终结果') : null);
    final result = RealtimeAsrResult(
      text: _lastText,
      wavBytes: _toWav(_audio.takeBytes()),
    );
    debugPrint(
      'Realtime ASR stop bytes=$_audioBytes chunks=$_audioChunks results=$_resultCount final=$_hasFinal',
    );
    _reset();
    if (error != null) throw RealtimeAsrException(error, result);
    return result;
  }

  Future<Uint8List> cancel() async {
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
    try {
      await _recorder.stop();
    } catch (_) {}
    await _audioSub?.cancel();
    _audioSub = null;
  }

  Future<void> _closeSocket() async {
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  void _reset() {
    _started = false;
    _stopping = false;
    _done = null;
    _lastText = '';
    _hasFinal = false;
    _socketError = null;
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
