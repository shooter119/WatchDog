import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../services/audio_service.dart';
import '../../../services/chat_history.dart';
import '../../../services/op_log_service.dart';
import '../data/models/chat_message.dart';
import '../data/models/vision_analysis.dart';
import 'copilot_gateway.dart';
import 'copilot_voice_recorder.dart';

export 'copilot_gateway.dart';
export 'copilot_voice_recorder.dart'
    show
        CopilotNoticeCallback,
        CopilotRealtimeSession,
        CopilotRealtimeTextCallback,
        RealtimeAsrSessionAdapter;

/// 智能辅助（Copilot）核心状态容器。
///
/// 完整保留作用域隔离、历史并发代际防覆盖、清空防回写、45s 超时取消、
/// 拍照压缩与识险、60s 就地语音录音与实时/批量双轨降级策略。
class CopilotStore extends ChangeNotifier {
  static const Duration maxRecordingDuration = CopilotVoiceRecorder.maxDuration;
  static const Duration recordingWarningDuration =
      CopilotVoiceRecorder.warningDuration;
  static const int maxVisionWidth = 1600;
  static const int visionJpegQuality = 82;
  static const int maxVisionBytes = 8 * 1024 * 1024;
  static const int wavHeaderBytes = CopilotVoiceRecorder.wavHeaderBytes;

  CopilotStore({
    required this.gateway,
    AudioService? audioService,
    this.requestTimeout = const Duration(seconds: 45),
    Uint8List Function(Uint8List raw)? imageCompressor,
  }) : _audio = audioService ?? AudioService(),
       _ownsAudio = audioService == null,
       _imageCompressor = imageCompressor ?? defaultCompressVisionImage {
    _scope = gateway.readScope();
    _hasIncidentContext = gateway.hasIncidentContext?.call() ?? false;
    _voice = CopilotVoiceRecorder(
      audioService: _audio,
      transcribeAudio: gateway.transcribeAudio,
      isRealtimeAsrEnabled: gateway.isRealtimeAsrEnabled,
      createRealtimeSession: gateway.createRealtimeSession,
      onStateChanged: _notify,
      onNotice: _emitNotice,
      onTranscriptSubmitted: (text) => unawaited(submitQuestion(text)),
    );
    gateway.scopeListenable?.addListener(_handleScopeListenableChanged);
  }

  final CopilotGateway gateway;
  final AudioService _audio;
  final bool _ownsAudio;
  final Duration requestTimeout;
  final Uint8List Function(Uint8List raw) _imageCompressor;
  late final CopilotVoiceRecorder _voice;

  List<ChatMessage> _messages = const [];
  String _scope = '';
  bool _hasIncidentContext = false;
  bool _loading = false;
  bool _sending = false;
  bool _visionBusy = false;
  bool _clearing = false;
  String? _error;
  String? _activeStreamId;

  int _requestGeneration = 0;
  int _historyGeneration = 0;
  bool _historyCleared = false;

  CopilotStreamCallbacks? _streamCallbacks;
  CopilotNoticeCallback? _onNotice;
  ValueChanged<bool>? _onSendingChanged;
  bool _disposed = false;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  String get scope => _scope;
  bool get hasIncidentContext => _hasIncidentContext;
  bool get loading => _loading;
  bool get sending => _sending;
  bool get visionBusy => _visionBusy;
  bool get recording => _voice.recording;
  bool get processing => _voice.processing;
  bool get clearing => _clearing;
  bool get busy => _sending || _visionBusy || _clearing;
  String? get transcript => _voice.transcript;
  String? get error => _error;
  String? get activeStreamId => _activeStreamId;
  int get recordingSeconds => _voice.recordingSeconds;
  int get requestGeneration => _requestGeneration;
  bool get isRecordingWarning => _voice.isWarning;
  int get recordingRemainingSeconds => _voice.remainingSeconds;

  /// 默认图片压缩：宽 ≤ 1600px、JPG quality=82。无法解码时返回空数组。
  static Uint8List defaultCompressVisionImage(Uint8List original) =>
      compressCopilotVisionImage(
        original,
        maxWidth: maxVisionWidth,
        quality: visionJpegQuality,
      );

  /// 将结构化识险响应格式化为 4 段 Markdown 与免责声明。
  static String formatVisionAnalysis(VisionAnalysis analysis) =>
      formatCopilotVisionAnalysis(analysis);

  /// 挂接 UI 回调与流式揭示器。
  void attachUi({
    CopilotStreamCallbacks? streamCallbacks,
    CopilotNoticeCallback? onNotice,
    ValueChanged<bool>? onRecordingChanged,
    ValueChanged<bool>? onProcessingChanged,
    ValueChanged<bool>? onSendingChanged,
  }) {
    _streamCallbacks = streamCallbacks;
    _onNotice = onNotice;
    _voice.onRecordingChanged = onRecordingChanged;
    _voice.onProcessingChanged = onProcessingChanged;
    _onSendingChanged = onSendingChanged;
  }

  /// 解除 UI 挂接并中止进行中的流式请求与实时录音。
  void detachUi() {
    _streamCallbacks = null;
    _onNotice = null;
    _voice.onRecordingChanged = null;
    _voice.onProcessingChanged = null;
    _onSendingChanged = null;
    _voice.detach();
    gateway.cancelAssistantRequest();
  }

  /// 预处理拍照/相册原图，强制校验可解码性与 8MB 上限。
  CopilotPreparedImage prepareVisionImage(Uint8List original) {
    final bytes = _imageCompressor(original);
    if (bytes.isEmpty) {
      return const CopilotPreparedImage.error('无法读取图片，请重新选择');
    }
    if (bytes.length > maxVisionBytes) {
      return const CopilotPreparedImage.error('图片过大，请重新拍摄');
    }
    return CopilotPreparedImage.ok(bytes);
  }

  void _handleScopeListenableChanged() {
    if (_disposed) return;
    final nextContext = gateway.hasIncidentContext?.call() ?? false;
    final contextChanged = nextContext != _hasIncidentContext;
    _hasIncidentContext = nextContext;
    final nextScope = gateway.readScope();
    if (nextScope != _scope) {
      syncScope(nextScope);
      return;
    }
    if (contextChanged) _notify();
  }

  /// 作用域（单位/账号/警情）切换时重置当前会话并重新拉取对应历史。
  void syncScope(String nextScope) {
    if (_disposed || nextScope == _scope) return;
    _scope = nextScope;
    _requestGeneration++;
    _historyGeneration++;
    _historyCleared = false;
    _activeStreamId = null;
    _streamCallbacks?.onStop();
    _messages = const [];
    _error = null;
    _sending = false;
    _visionBusy = false;
    _notify();
    _onSendingChanged?.call(false);
    unawaited(loadHistory());
  }

  Future<void> loadHistory() async {
    final loadGeneration = _historyGeneration;
    final loadScope = _scope;
    try {
      final history = await gateway.fetchHistory();
      if (_disposed || loadScope != _scope) return;
      final cleaned = history
          .where((m) => m.role != 'assistant' || m.content.trim().isNotEmpty)
          .toList(growable: false);
      if (_historyCleared) {
        // 清空已完成：丢弃清空前发起的晚到历史快照。
      } else if (loadGeneration == _historyGeneration) {
        _messages = cleaned;
      } else {
        final currentIds = _messages.map((m) => m.id).toSet();
        _messages = [
          ...cleaned.where((m) => !currentIds.contains(m.id)),
          ..._messages,
        ];
      }
      _loading = false;
      if (!_historyCleared) _error = null;
      _notify();
    } catch (e) {
      if (_disposed || loadScope != _scope) return;
      _loading = false;
      _error = '加载问答记录失败：$e';
      _notify();
    }
  }

  Future<List<ChatMessage>> loadLegacyHistory() =>
      gateway.loadLegacyHistory?.call() ?? ChatHistory.load();

  /// 更新当前流式回复气泡可见内容（由揭示器逐字回调）。
  void updateStreamingMessage(String streamId, String visibleContent) {
    if (_disposed) return;
    final index = _messages.indexWhere((m) => m.id == streamId);
    if (index < 0) return;
    final current = _messages[index];
    if (current.content == visibleContent) return;
    final updated = List<ChatMessage>.of(_messages);
    updated[index] = ChatMessage(
      id: current.id,
      role: current.role,
      content: visibleContent,
      createdAt: current.createdAt,
    );
    _messages = updated;
    _notify();
  }

  /// 揭示完结后定格终态内容并结束发送态。
  void finalizeStreamReply(String streamId, String fullReply) {
    if (_disposed) return;
    final index = _messages.indexWhere((m) => m.id == streamId);
    _activeStreamId = null;
    if (index >= 0) {
      final current = _messages[index];
      final updated = List<ChatMessage>.of(_messages);
      updated[index] = ChatMessage(
        id: current.id,
        role: current.role,
        content: fullReply,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _messages = updated;
    }
    _sending = false;
    _notify();
    _onSendingChanged?.call(false);
  }

  Future<void> submitQuestion(String text) async {
    final clean = text.trim();
    if (_disposed || clean.isEmpty || _sending || _clearing) return;
    final history = _messages
        .where((m) => m.content.trim().isNotEmpty)
        .toList(growable: false);
    _historyGeneration++;
    final now = DateTime.now().millisecondsSinceEpoch;
    final opId = 'op-$now-${Random().nextInt(0xFFFF).toRadixString(16)}';
    final generation = ++_requestGeneration;
    final placeholderId = 'stream-$opId';
    _streamCallbacks?.onStop();
    _activeStreamId = placeholderId;
    _streamCallbacks?.onStart(placeholderId);
    OpLogService.instance.record(
      opId,
      'chat_submit',
      '提交问题',
      data: {'text': clean},
      sync: false,
    );
    _messages = [
      ..._messages,
      ChatMessage(id: 'local-$opId', role: 'user', content: clean, createdAt: now),
      ChatMessage(id: placeholderId, role: 'assistant', content: '', createdAt: now),
    ];
    _sending = true;
    _error = null;
    _voice.clearTranscript();
    _notify();
    _onSendingChanged?.call(true);

    final fallbackBuffer = StringBuffer();
    try {
      final reply = await gateway
          .askAssistantStream(
            clean,
            opId: opId,
            history: history,
            onChunk: (delta) {
              if (_disposed ||
                  generation != _requestGeneration ||
                  _activeStreamId != placeholderId ||
                  delta.isEmpty) {
                return;
              }
              final callbacks = _streamCallbacks;
              if (callbacks != null) {
                callbacks.onChunk(placeholderId, delta);
              } else {
                fallbackBuffer.write(delta);
                updateStreamingMessage(placeholderId, fallbackBuffer.toString());
              }
            },
          )
          .timeout(
            requestTimeout,
            onTimeout: () {
              gateway.cancelAssistantRequest();
              throw TimeoutException('辅助问答响应超时，请检查网络后重试');
            },
          );
      if (_disposed ||
          generation != _requestGeneration ||
          _activeStreamId != placeholderId) {
        return;
      }
      final callbacks = _streamCallbacks;
      if (callbacks != null) {
        callbacks.onComplete(placeholderId, reply);
      } else {
        finalizeStreamReply(placeholderId, reply);
      }
    } catch (e) {
      gateway.cancelAssistantRequest();
      if (generation == _requestGeneration) _requestGeneration++;
      if (_disposed) return;
      _activeStreamId = null;
      _streamCallbacks?.onStop();
      _messages = _messages.where((m) => m.id != placeholderId).toList();
      _sending = false;
      _error = '辅助回复失败：$e';
      _notify();
      _onSendingChanged?.call(false);
      OpLogService.instance.record(
        opId,
        'chat_err',
        '回复失败: $e',
        level: 'error',
        sync: false,
      );
    }
  }

  /// 提交已预处理的 JPEG 图片字节进行识险分析（受代际号保护防跨警情串写）。
  Future<bool> submitVisionImage(
    Uint8List jpegBytes, {
    required String question,
    int? expectedGeneration,
  }) async {
    final generation = expectedGeneration ?? _requestGeneration;
    if (_disposed || busy || generation != _requestGeneration) return false;
    _visionBusy = true;
    _notify();
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final analysis = await gateway.analyzeVision(
        jpegBytes,
        mimeType: 'image/jpeg',
        message: question,
        opId: 'vision-$now',
      );
      if (_disposed || generation != _requestGeneration) return false;
      final reply = formatVisionAnalysis(analysis);
      final doneAt = DateTime.now().millisecondsSinceEpoch;
      _messages = [
        ..._messages,
        ChatMessage(
          id: 'vision-$doneAt',
          role: 'user',
          content: '图片分析：$question',
          createdAt: doneAt,
        ),
        ChatMessage(
          id: 'vision-result-$doneAt',
          role: 'assistant',
          content: reply,
          createdAt: doneAt,
        ),
      ];
      _notify();
      return true;
    } catch (e) {
      if (!_disposed && generation == _requestGeneration) {
        _emitNotice('图片分析失败：$e');
      }
      return false;
    } finally {
      if (!_disposed && generation == _requestGeneration) {
        _visionBusy = false;
        _notify();
      }
    }
  }

  Future<bool> clearHistory() async {
    if (_disposed || _sending || _clearing) return false;
    _historyGeneration++;
    _clearing = true;
    _notify();
    try {
      await gateway.clearHistory();
      if (_disposed) return false;
      _historyCleared = true;
      _messages = const [];
      _clearing = false;
      _error = null;
      _notify();
      return true;
    } catch (e) {
      if (_disposed) return false;
      _clearing = false;
      _notify();
      _emitNotice('清空失败：$e', duration: const Duration(seconds: 2));
      return false;
    }
  }

  Future<void> beginRecording() => _voice.begin(blockedBySending: _sending);

  Future<void> finishRecording() => _voice.finish();

  void _emitNotice(
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    if (!_disposed) _onNotice?.call(message, duration: duration);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    gateway.scopeListenable?.removeListener(_handleScopeListenableChanged);
    detachUi();
    _voice.dispose();
    if (_ownsAudio) {
      unawaited(_audio.dispose());
    }
    super.dispose();
  }
}
