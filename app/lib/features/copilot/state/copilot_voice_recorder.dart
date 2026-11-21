import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../services/audio_service.dart';
import '../../../services/op_log_service.dart';
import '../../../services/realtime_asr_service.dart';

/// 实时语音识别增量回调。
typedef CopilotRealtimeTextCallback =
    void Function(String text, {required bool finalText});

/// 轻提示通知回调（UI 层映射到 SnackBar）。
typedef CopilotNoticeCallback =
    void Function(String message, {Duration duration});

/// 实时语音会话抽象，避免 `features/copilot/state/` 直接依赖 `ApiClient`。
abstract class CopilotRealtimeSession {
  Future<void> start({String? opId});
  Future<RealtimeAsrResult> stop();
  Future<void> cancel();
  Future<void> dispose();
}

/// 将冻结的 [RealtimeAsrService] 适配为 [CopilotRealtimeSession]。
class RealtimeAsrSessionAdapter implements CopilotRealtimeSession {
  RealtimeAsrSessionAdapter(this._service);

  final RealtimeAsrService _service;

  @override
  Future<void> start({String? opId}) => _service.start(opId: opId);

  @override
  Future<RealtimeAsrResult> stop() => _service.stop();

  @override
  Future<void> cancel() => _service.cancel();

  @override
  Future<void> dispose() => _service.dispose();
}

/// 智能辅助就地 60 秒语音录音控制器（含 50s 预警、实时转写降级与 ≤44B WAV 判空）。
class CopilotVoiceRecorder {
  static const Duration maxDuration = Duration(seconds: 60);
  static const Duration warningDuration = Duration(seconds: 50);
  static const int wavHeaderBytes = 44;

  CopilotVoiceRecorder({
    required AudioService audioService,
    required this.transcribeAudio,
    required this.onStateChanged,
    required this.onNotice,
    required this.onTranscriptSubmitted,
    this.isRealtimeAsrEnabled,
    this.createRealtimeSession,
    this.onRecordingChanged,
    this.onProcessingChanged,
  }) : _audio = audioService;

  final AudioService _audio;
  final Future<String> Function(Uint8List bytes, {String? opId})
  transcribeAudio;
  final VoidCallback onStateChanged;
  final CopilotNoticeCallback onNotice;
  final void Function(String text) onTranscriptSubmitted;
  final bool Function()? isRealtimeAsrEnabled;
  final CopilotRealtimeSession? Function(CopilotRealtimeTextCallback onText)?
  createRealtimeSession;
  ValueChanged<bool>? onRecordingChanged;
  ValueChanged<bool>? onProcessingChanged;

  bool _recording = false;
  bool _processing = false;
  bool _requested = false;
  bool _starting = false;
  int _generation = 0;
  int _seconds = 0;
  String? _transcript;
  String? _opId;
  Timer? _timer;
  DateTime? _startedAt;
  CopilotRealtimeSession? _realtime;
  bool _disposed = false;

  bool get recording => _recording;
  bool get processing => _processing;
  int get recordingSeconds => _seconds;
  String? get transcript => _transcript;
  bool get isWarning => _seconds >= warningDuration.inSeconds;
  int get remainingSeconds => max(0, maxDuration.inSeconds - _seconds);

  void clearTranscript() {
    _transcript = null;
  }

  Future<void> begin({required bool blockedBySending}) async {
    if (_disposed ||
        _recording ||
        _processing ||
        blockedBySending ||
        _requested ||
        _starting) {
      return;
    }
    final generation = ++_generation;
    _requested = true;
    _starting = true;
    _opId =
        'op-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFF).toRadixString(16)}';
    OpLogService.instance.record(_opId!, 'record_start', '开始录音', sync: false);
    _transcript = null;
    onStateChanged();

    late final bool granted;
    try {
      granted = await _audio.hasPermission();
    } catch (e) {
      _requested = false;
      _starting = false;
      onNotice('麦克风权限检查失败：$e');
      _endOp('permission_error');
      return;
    }
    if (!_requested || generation != _generation || _disposed) {
      _starting = false;
      _endOp('cancelled');
      return;
    }
    if (!granted) {
      _requested = false;
      _starting = false;
      onNotice('需要麦克风权限', duration: const Duration(seconds: 2));
      OpLogService.instance.record(
        _opId!,
        'record_perm_denied',
        '缺少麦克风权限',
        level: 'warn',
        sync: false,
      );
      _endOp('perm_denied');
      return;
    }

    try {
      await _startCapture();
      if (!_requested || generation != _generation || _disposed) {
        await _abortCapture();
        _starting = false;
        _endOp('cancelled');
        return;
      }
      _recording = true;
      _seconds = 0;
      _starting = false;
      onStateChanged();
      _startTimer();
      onRecordingChanged?.call(true);
    } catch (e) {
      _requested = false;
      _starting = false;
      OpLogService.instance.record(
        _opId!,
        'record_start_err',
        '录音启动失败: $e',
        level: 'error',
        sync: false,
      );
      onNotice('录音启动失败：$e', duration: const Duration(seconds: 2));
      _endOp('record_error');
    }
  }

  Future<void> _startCapture() async {
    final realtimeEnabled =
        createRealtimeSession != null && (isRealtimeAsrEnabled?.call() ?? true);
    if (!realtimeEnabled) {
      await _audio.start();
      return;
    }
    void onText(String text, {required bool finalText}) {
      if (_disposed || (!_recording && !_requested)) return;
      _transcript = text;
      onStateChanged();
    }

    final session = createRealtimeSession!(onText);
    if (session == null) {
      await _audio.start();
      return;
    }
    _realtime = session;
    try {
      await session.start(opId: _opId);
    } catch (error) {
      await session.cancel();
      await session.dispose();
      _realtime = null;
      OpLogService.instance.record(
        _opId!,
        'stream_connect_err',
        '实时识别连接失败，改用兼容录音模式: $error',
        level: 'warn',
        sync: false,
      );
      await _audio.start();
    }
  }

  Future<void> _abortCapture() async {
    final realtime = _realtime;
    if (realtime != null) {
      _realtime = null;
      await realtime.cancel();
      await realtime.dispose();
    } else if (_audio.isRecording) {
      await _audio.stop();
    }
  }

  Future<void> finish() async {
    if (!_recording) {
      _requested = false;
      _starting = false;
      _generation++;
      _stopTimer();
      return;
    }
    _requested = false;
    _starting = false;
    _generation++;
    _stopTimer();
    _recording = false;
    _processing = true;
    _seconds = 0;
    onStateChanged();
    onRecordingChanged?.call(false);
    onProcessingChanged?.call(true);
    final opId = _opId ?? '';
    try {
      late final Uint8List bytes;
      String? realtimeText;
      final realtime = _realtime;
      if (realtime != null) {
        try {
          final result = await realtime.stop();
          bytes = result.wavBytes;
          realtimeText = result.text;
        } on RealtimeAsrException catch (error) {
          bytes = error.result.wavBytes;
          realtimeText = null;
          OpLogService.instance.record(
            opId,
            'transcribe_fallback',
            '实时识别失败，切换批量云端识别: ${error.cause}',
            level: 'warn',
            sync: false,
          );
        } finally {
          await realtime.dispose();
          _realtime = null;
        }
      } else {
        bytes = await _audio.stop();
      }
      final text = await _resolveTranscript(
        bytes: bytes,
        realtimeUsed: realtime != null,
        realtimeText: realtimeText,
        opId: opId,
      );
      if (text == null) return;
      if (text.trim().isEmpty) {
        onNotice('未识别到语音，请再说一次', duration: const Duration(seconds: 2));
        OpLogService.instance.record(
          opId,
          'transcribe_empty',
          '未识别到语音',
          level: 'warn',
          sync: false,
        );
        _endOp('no_speech');
        return;
      }
      if (_disposed) {
        _endOp('page_disposed');
        return;
      }
      _endOp('chat');
      onTranscriptSubmitted(text);
    } catch (e) {
      onNotice('录音结束失败：$e', duration: const Duration(seconds: 2));
      _endOp('error');
    } finally {
      _processing = false;
      onStateChanged();
      onProcessingChanged?.call(false);
    }
  }

  Future<String?> _resolveTranscript({
    required Uint8List bytes,
    required bool realtimeUsed,
    required String? realtimeText,
    required String opId,
  }) async {
    try {
      final trimmedRealtime = realtimeText?.trim() ?? '';
      final String text;
      if (trimmedRealtime.isNotEmpty) {
        text = trimmedRealtime;
      } else if (realtimeUsed && bytes.length <= wavHeaderBytes) {
        // 实时流未录到有效 PCM 采样（仅 ≤44B WAV 头），视为空语音提示重录。
        text = '';
      } else {
        text = await transcribeAudio(bytes, opId: opId);
      }
      _transcript = text;
      onStateChanged();
      OpLogService.instance.record(
        opId,
        'transcribe_ok',
        '转写成功',
        data: {'text': text},
        sync: false,
      );
      return text;
    } catch (e) {
      OpLogService.instance.record(
        opId,
        'transcribe_err',
        '转写失败: $e',
        level: 'error',
        sync: false,
      );
      onNotice('识别失败：$e', duration: const Duration(seconds: 2));
      _endOp('transcribe_error');
      return null;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _startedAt = DateTime.now();
    _seconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed || !_recording) {
        _stopTimer();
        return;
      }
      final wallSeconds = _startedAt == null
          ? 0
          : DateTime.now().difference(_startedAt!).inSeconds;
      final nextSeconds = min(
        max(timer.tick, wallSeconds),
        maxDuration.inSeconds,
      );
      if (nextSeconds != _seconds) {
        _seconds = nextSeconds;
        onStateChanged();
      }
      if (nextSeconds >= maxDuration.inSeconds) {
        _stopTimer();
        unawaited(finish());
      }
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
  }

  void _endOp(String outcome) {
    final opId = _opId;
    _opId = null;
    if (opId == null) return;
    OpLogService.instance.record(
      opId,
      'op_end',
      '本次操作结束',
      data: {'outcome': outcome},
      sync: false,
    );
  }

  void detach() {
    _requested = false;
    _generation++;
    _starting = false;
    _stopTimer();
    _endOp('page_disposed');
    final realtime = _realtime;
    _realtime = null;
    if (realtime != null) {
      unawaited(realtime.dispose());
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detach();
  }
}
