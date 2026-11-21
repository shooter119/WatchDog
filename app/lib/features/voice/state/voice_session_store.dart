import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../services/audio_service.dart';
import '../../../services/local_asr_service.dart';
import '../../../services/local_parser.dart';
import '../../../services/op_log_service.dart';
import '../data/models/voice_parse.dart';
import 'voice_draft_person.dart';
import 'voice_recognition_pipeline.dart';
import 'voice_session_types.dart';

export 'voice_session_types.dart'
    show RealtimeAsrSessionAdapter, VoiceCloudParseFn, VoiceCloudTranscribeFn,
        VoiceFinishOutcome, VoiceFinishOutcomeType, VoiceRealtimeSession,
        VoiceRealtimeSessionFactory, VoiceSessionStatus;

/// 全局语音中枢状态机。
///
/// 统一托管跨页录音态、60 秒限时（50 秒预警）、`_recordingGeneration` 慢权限防重入、
/// 实时流式→云端批量→本地 [LocalAsrService] 回退链，以及分批累加的待确认人员队列。
class VoiceSessionStore extends ChangeNotifier {
  VoiceSessionStore({
    AudioService? audioService,
    VoiceRealtimeSessionFactory? realtimeSessionFactory,
    bool Function()? isCloudAsrEnabled,
    bool Function()? isCloudParseEnabled,
    VoiceCloudTranscribeFn? cloudTranscribe,
    VoiceCloudParseFn? cloudParse,
    LocalAsrService? localAsr,
    LocalParser? localParser,
    List<String> Function()? rosterNamesProvider,
    List<String> Function()? asrHotwordsProvider,
    VoiceCalcParams Function()? calcParamsProvider,
    VoidCallback? onFlushOpLogs,
    void Function(VoiceFinishOutcome outcome)? onAutoFinished,
    DateTime Function()? now,
  }) : _rosterNamesProvider = rosterNamesProvider ?? _emptyStrings,
       _calcParamsProvider = calcParamsProvider ?? _defaultCalcParams,
       _onFlushOpLogs = onFlushOpLogs,
       _onAutoFinished = onAutoFinished,
       _now = now ?? DateTime.now,
       _capture = VoiceCaptureController(
         audioService: audioService,
         realtimeSessionFactory: realtimeSessionFactory,
         isCloudAsrEnabled: isCloudAsrEnabled ?? _alwaysFalse,
       ),
       _pipeline = VoiceRecognitionPipeline(
         isCloudAsrEnabled: isCloudAsrEnabled ?? _alwaysFalse,
         isCloudParseEnabled: isCloudParseEnabled ?? _alwaysFalse,
         cloudTranscribe: cloudTranscribe,
         cloudParse: cloudParse,
         localAsr: localAsr,
         localParser: localParser,
         rosterNamesProvider: rosterNamesProvider ?? _emptyStrings,
         asrHotwordsProvider: asrHotwordsProvider ?? _emptyStrings,
       );

  static const Duration maxRecordingDuration = Duration(seconds: 60);
  static const Duration warningRecordingDuration = Duration(seconds: 50);

  static bool _alwaysFalse() => false;
  static List<String> _emptyStrings() => const <String>[];
  static VoiceCalcParams _defaultCalcParams() => const VoiceCalcParams();

  final List<String> Function() _rosterNamesProvider;
  final VoiceCalcParams Function() _calcParamsProvider;
  final VoidCallback? _onFlushOpLogs;
  final void Function(VoiceFinishOutcome outcome)? _onAutoFinished;
  final DateTime Function() _now;
  final VoiceCaptureController _capture;
  final VoiceRecognitionPipeline _pipeline;
  final Random _random = Random();

  StreamSubscription<double>? _ampSub;
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;

  VoiceSessionStatus _status = VoiceSessionStatus.idle;
  int _recordingSeconds = 0;
  double _amplitude = 0.15;
  String? _transcript;
  ParseResult? _lastParseResult;
  String? _errorMessage;
  String? _inlineError;
  bool _permissionDenied = false;
  String? _opId;
  double? _statedVolumeL;

  bool _recordingRequested = false;
  bool _recordingStarting = false;
  int _recordingGeneration = 0;
  int _draftSeed = 0;
  bool _disposed = false;
  final List<VoiceDraftPerson> _drafts = <VoiceDraftPerson>[];

  VoiceSessionStatus get status => _status;
  bool get isIdle => _status == VoiceSessionStatus.idle;
  bool get isRecording => _status == VoiceSessionStatus.recording;
  bool get isProcessing => _status == VoiceSessionStatus.processing;
  bool get isConfirming => _status == VoiceSessionStatus.confirming;
  bool get hasError => _status == VoiceSessionStatus.error;
  int get recordingSeconds => _recordingSeconds;
  int get remainingSeconds =>
      max(0, maxRecordingDuration.inSeconds - _recordingSeconds);
  bool get isWarningPhase =>
      _recordingSeconds >= warningRecordingDuration.inSeconds;
  double get amplitude => _amplitude;
  String? get transcript => _transcript;
  ParseResult? get lastParseResult => _lastParseResult;
  String? get errorMessage => _errorMessage;
  String? get inlineError => _inlineError;
  bool get permissionDenied => _permissionDenied;
  String? get currentOpId => _opId;
  double? get statedVolumeL => _statedVolumeL;
  List<VoiceDraftPerson> get drafts => List<VoiceDraftPerson>.unmodifiable(_drafts);
  bool get hasPendingDrafts => _drafts.isNotEmpty;
  VoiceCalcParams get calcParams => _calcParamsProvider();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 开始录音（长按触发）。具备 `_recordingGeneration` 防重入保护，防止慢权限弹窗重复启动。
  Future<void> beginRecording() async {
    if (_disposed || isRecording || isProcessing || _recordingRequested || _recordingStarting) {
      return;
    }
    final generation = ++_recordingGeneration;
    _recordingRequested = true;
    _recordingStarting = true;
    _opId = 'op-${_now().millisecondsSinceEpoch}-${_random.nextInt(0xFFFF).toRadixString(16)}';
    OpLogService.instance.record(_opId!, 'record_start', '开始录音');
    _clearTransientFields();
    _notify();

    late final bool granted;
    try {
      granted = await _capture.hasPermission();
    } catch (error) {
      _failStart('麦克风权限检查失败: $error', outcome: 'permission_error');
      return;
    }
    if (!_recordingRequested || generation != _recordingGeneration || _disposed) {
      _recordingStarting = false;
      _endOp('cancelled');
      return;
    }
    if (!granted) {
      OpLogService.instance.record(_opId!, 'record_perm_denied', '缺少麦克风权限', level: 'warn');
      _failStart('需要麦克风权限', outcome: 'perm_denied', permDenied: true);
      return;
    }

    try {
      await _capture.start(
        opId: _opId!,
        onText: (String text, {required bool finalText}) {
          if (_disposed || (!isRecording && !_recordingRequested)) return;
          _transcript = text;
          _notify();
        },
      );
      if (!_recordingRequested || generation != _recordingGeneration || _disposed) {
        await _capture.abortStartedCapture();
        _recordingStarting = false;
        _endOp('cancelled');
        return;
      }
      _status = VoiceSessionStatus.recording;
      _recordingSeconds = 0;
      _recordingStarting = false;
      _startRecordingTimer();
      await _ampSub?.cancel();
      _ampSub = _capture.amplitudeStream().listen((double value) {
        if (_disposed || !isRecording) return;
        _amplitude = value;
        _notify();
      });
      _notify();
    } catch (error) {
      OpLogService.instance.record(_opId!, 'record_start_err', '录音启动失败: $error', level: 'error');
      _failStart('录音启动失败: $error', outcome: 'record_error');
    }
  }

  void _failStart(String message, {required String outcome, bool permDenied = false}) {
    _recordingRequested = false;
    _recordingStarting = false;
    _errorMessage = message;
    _permissionDenied = permDenied;
    _status = VoiceSessionStatus.error;
    _endOp(outcome);
    _notify();
  }

  void _stopRecordingState({required bool resetCounters}) {
    _recordingRequested = false;
    _recordingStarting = false;
    _recordingGeneration++;
    _stopRecordingTimer();
    if (resetCounters) {
      _amplitude = 0.15;
      _recordingSeconds = 0;
    }
  }

  /// 结束录音（松手或到达 60 秒上限）并执行「转写 → 解析 → 状态流转」。
  Future<VoiceFinishOutcome> finishRecording() async {
    if (!isRecording) {
      _stopRecordingState(resetCounters: false);
      return const VoiceFinishOutcome(type: VoiceFinishOutcomeType.cancelled);
    }
    _stopRecordingState(resetCounters: true);
    _status = VoiceSessionStatus.processing;
    final ampSub = _ampSub;
    _ampSub = null;
    if (ampSub != null) unawaited(ampSub.cancel());
    _notify();

    final opId = _opId ?? '';
    try {
      final sw = Stopwatch()..start();
      final capture = await _capture.stop(opId: opId);
      OpLogService.instance.record(
        opId,
        'record_stop',
        '录音结束',
        data: <String, dynamic>{'bytes': capture.bytes.length, 'ms': sw.elapsedMilliseconds},
      );
      final text = await _pipeline.resolveTranscript(
        capture: capture,
        opId: opId,
        elapsedMs: () => sw.elapsedMilliseconds,
      );
      if (_disposed) return const VoiceFinishOutcome(type: VoiceFinishOutcomeType.cancelled);
      if (text.isEmpty) {
        OpLogService.instance.record(opId, 'transcribe_empty', '未识别到语音，请再说一次', level: 'warn');
        _status = VoiceSessionStatus.error;
        _errorMessage = '未识别到语音，请再说一次';
        _endOp('no_speech');
        _notify();
        return VoiceFinishOutcome(
          type: VoiceFinishOutcomeType.noSpeech,
          opId: opId,
          errorMessage: _errorMessage,
        );
      }
      final parsed = await _pipeline.parseWithFallback(
        text,
        opId: opId,
        elapsedMs: () => sw.elapsedMilliseconds,
      );
      if (_disposed) return const VoiceFinishOutcome(type: VoiceFinishOutcomeType.cancelled);
      return _applyParsedResult(text: text, parsed: parsed, opId: opId);
    } catch (error) {
      if (_disposed) return const VoiceFinishOutcome(type: VoiceFinishOutcomeType.cancelled);
      _status = VoiceSessionStatus.error;
      _errorMessage = '$error';
      _endOp('error');
      _notify();
      return VoiceFinishOutcome(
        type: VoiceFinishOutcomeType.error,
        opId: opId,
        errorMessage: _errorMessage,
      );
    }
  }

  /// 取消当前正在启动或进行中的录音，不触发转写。
  Future<void> cancelRecording() async {
    _stopRecordingState(resetCounters: true);
    await _ampSub?.cancel();
    _ampSub = null;
    await _capture.abortStartedCapture();
    if (isRecording) {
      _status = _drafts.isNotEmpty ? VoiceSessionStatus.confirming : VoiceSessionStatus.idle;
    }
    _endOp('cancelled');
    _notify();
  }

  /// 外部（如智能辅助页就地录音）识别为进出场时，直接注入结果进入确认态。
  void applyExternalVoiceResult(String text, ParseResult parsed) {
    _errorMessage = null;
    _inlineError = null;
    _applyParsedResult(text: text, parsed: parsed, opId: _opId ?? '');
  }

  void _mutateDraft(int index, VoiceDraftPerson Function(VoiceDraftPerson) fn) {
    if (index < 0 || index >= _drafts.length) return;
    _drafts[index] = fn(_drafts[index]);
    _inlineError = null;
    _notify();
  }

  void updateDraftName(int index, String name) =>
      _mutateDraft(index, (d) => d.copyWith(name: name));

  void updateDraftPressure(int index, String pressureText) =>
      _mutateDraft(index, (d) => d.copyWith(pressureText: pressureText));

  void updateDraftVolume(int index, double volumeL) => _mutateDraft(
    index,
    (d) => d.copyWith(volumeL: normalizeCylinderVolume(volumeL)),
  );

  void _clearTransientFields() {
    _transcript = null;
    _lastParseResult = null;
    _errorMessage = null;
    _inlineError = null;
    _permissionDenied = false;
  }

  void removeDraftAt(int index) {
    if (index < 0 || index >= _drafts.length) return;
    _drafts.removeAt(index);
    if (_drafts.isEmpty) {
      _clearTransientFields();
      _status = VoiceSessionStatus.idle;
    }
    _notify();
  }

  void retry() {
    _recordingRequested = false;
    _recordingStarting = false;
    _drafts.clear();
    _clearTransientFields();
    _status = VoiceSessionStatus.idle;
    _notify();
  }

  void showPendingConfirm() {
    if (_drafts.isEmpty) return;
    _transcript = '已录入 ${_drafts.length} 人，待统一确认';
    _lastParseResult = ParseResult(
      action: 'enter',
      intent: VoiceIntent.entry,
      people: [
        for (final d in _drafts)
          ParsePerson(
            name: d.trimmedName.isEmpty ? (d.sourceName ?? '') : d.trimmedName,
            pressureMpa: d.pressureMpa,
          ),
      ],
    );
    _errorMessage = null;
    _permissionDenied = false;
    _status = VoiceSessionStatus.confirming;
    _notify();
  }

  void setSubmitting(bool submitting) {
    if (submitting) {
      _status = VoiceSessionStatus.processing;
    } else if (isProcessing) {
      _status = _drafts.isNotEmpty ? VoiceSessionStatus.confirming : VoiceSessionStatus.idle;
    }
    _notify();
  }

  void setInlineError(String? message) {
    _inlineError = message;
    _notify();
  }

  void setError(String message) {
    _errorMessage = message;
    _permissionDenied = false;
    _status = VoiceSessionStatus.error;
    _notify();
  }

  void dismissError() {
    _errorMessage = null;
    _permissionDenied = false;
    if (hasError) _status = VoiceSessionStatus.idle;
    _notify();
  }

  void applyConfirmOutcome({
    required List<VoiceDraftPerson> keptDrafts,
    String? inlineError,
    String? errorMessage,
  }) {
    _drafts
      ..clear()
      ..addAll(keptDrafts);
    _inlineError = inlineError;
    _errorMessage = errorMessage;
    if (_drafts.isEmpty) {
      _transcript = null;
      _lastParseResult = null;
      _status = errorMessage != null ? VoiceSessionStatus.error : VoiceSessionStatus.idle;
    } else {
      _status = VoiceSessionStatus.confirming;
    }
    _notify();
  }

  void endOperation(String outcome, {String level = 'info', Map<String, dynamic>? data}) =>
      _endOp(outcome, level: level, data: data);

  void _startRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingStartedAt = _now();
    _recordingSeconds = 0;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (_disposed || !isRecording) {
        _stopRecordingTimer();
        return;
      }
      final wall = _recordingStartedAt == null
          ? 0
          : _now().difference(_recordingStartedAt!).inSeconds;
      final seconds = min(max(timer.tick, wall), maxRecordingDuration.inSeconds);
      if (seconds != _recordingSeconds) {
        _recordingSeconds = seconds;
        _notify();
      }
      if (seconds >= maxRecordingDuration.inSeconds) {
        _stopRecordingTimer();
        unawaited(_handleAutoFinish());
      }
    });
  }

  Future<void> _handleAutoFinish() async {
    final outcome = await finishRecording();
    _onAutoFinished?.call(outcome);
  }

  void _stopRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingStartedAt = null;
  }

  VoiceFinishOutcome _applyParsedResult({
    required String text,
    required ParseResult parsed,
    required String opId,
  }) {
    final transition = evaluateParsedVoiceResult(
      text: text,
      parsed: parsed,
      opId: opId,
      drafts: _drafts,
      rosterNames: _rosterNamesProvider(),
      currentStatedVolumeL: _statedVolumeL,
      fallbackVolumeL: _calcParamsProvider().cylinderVolL,
      nextDraftId: () => 'draft-${++_draftSeed}',
    );
    _statedVolumeL = transition.statedVolumeL;
    _transcript = transition.keepTranscript ? text : null;
    _lastParseResult = transition.keepTranscript ? parsed : null;
    _errorMessage = transition.errorMessage;
    _inlineError = null;
    _status = transition.nextStatus;
    if (transition.endOpKey != null) {
      _endOp(transition.endOpKey!);
    }
    _notify();
    return transition.outcome;
  }

  void _endOp(String outcome, {String level = 'info', Map<String, dynamic>? data}) {
    final opId = _opId;
    _opId = null;
    if (opId == null) return;
    OpLogService.instance.record(
      opId,
      'op_end',
      '本次操作结束',
      level: level,
      data: <String, dynamic>{'outcome': outcome, ...?data},
    );
    _onFlushOpLogs?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRecordingState(resetCounters: false);
    unawaited(_ampSub?.cancel());
    _ampSub = null;
    unawaited(_capture.dispose());
    super.dispose();
  }
}
