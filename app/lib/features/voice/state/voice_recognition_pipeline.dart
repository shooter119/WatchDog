import 'dart:async';
import 'dart:typed_data';

import '../../../services/audio_service.dart';
import '../../../services/local_asr_service.dart';
import '../../../services/local_parser.dart';
import '../../../services/op_log_service.dart';
import '../../../services/realtime_asr_service.dart';
import '../data/models/voice_parse.dart';
import 'voice_draft_person.dart';
import 'voice_session_types.dart';

/// 单次音频采集结果（实时流文本 + WAV 音频字节）。
class VoiceCaptureResult {
  const VoiceCaptureResult({
    required this.bytes,
    required this.realtimeText,
    required this.usedRealtime,
  });

  final Uint8List bytes;
  final String? realtimeText;
  final bool usedRealtime;
}

/// 统一封装实时流式采集与本地 WAV 兼容采集（含实时建连失败回退）。
class VoiceCaptureController {
  VoiceCaptureController({
    AudioService? audioService,
    VoiceRealtimeSessionFactory? realtimeSessionFactory,
    required bool Function() isCloudAsrEnabled,
  }) : _audio = audioService ?? AudioService(),
       _ownsAudio = audioService == null,
       _realtimeSessionFactory = realtimeSessionFactory,
       _isCloudAsrEnabled = isCloudAsrEnabled;

  final AudioService _audio;
  final bool _ownsAudio;
  final VoiceRealtimeSessionFactory? _realtimeSessionFactory;
  final bool Function() _isCloudAsrEnabled;
  VoiceRealtimeSession? _realtime;

  bool get _realtimeEnabled =>
      _isCloudAsrEnabled() && _realtimeSessionFactory != null;

  Future<bool> hasPermission() => _audio.hasPermission();

  Stream<double> amplitudeStream() =>
      _realtime?.amplitudeStream() ?? _audio.amplitudeStream();

  Future<void> start({
    required String opId,
    required RealtimeTextCallback onText,
  }) async {
    if (!_realtimeEnabled) {
      await _audio.start();
      return;
    }
    _realtime = _realtimeSessionFactory!(onText);
    try {
      await _realtime!.start(opId: opId);
    } catch (error) {
      await disposeRealtimeSafely(cancelFirst: true);
      OpLogService.instance.record(
        opId,
        'stream_connect_err',
        '实时识别连接失败，改用兼容录音模式: $error',
        level: 'warn',
      );
      await _audio.start();
    }
  }

  Future<VoiceCaptureResult> stop({required String opId}) async {
    final realtime = _realtime;
    if (realtime == null) {
      return VoiceCaptureResult(
        bytes: await _audio.stop(),
        realtimeText: null,
        usedRealtime: false,
      );
    }
    try {
      final result = await realtime.stop();
      return VoiceCaptureResult(
        bytes: result.wavBytes,
        realtimeText: result.text,
        usedRealtime: true,
      );
    } on RealtimeAsrException catch (error) {
      OpLogService.instance.record(
        opId,
        'transcribe_fallback',
        '实时云端识别失败，切换批量云端识别: ${error.cause}',
        level: 'warn',
      );
      return VoiceCaptureResult(
        bytes: error.result.wavBytes,
        realtimeText: null,
        usedRealtime: true,
      );
    } finally {
      await disposeRealtimeSafely(cancelFirst: false);
    }
  }

  Future<void> abortStartedCapture() async {
    if (_realtime != null) {
      await disposeRealtimeSafely(cancelFirst: true);
    } else if (_audio.isRecording) {
      try {
        await _audio.stop();
      } catch (_) {}
    }
  }

  Future<void> disposeRealtimeSafely({required bool cancelFirst}) async {
    final realtime = _realtime;
    _realtime = null;
    if (realtime == null) return;
    if (cancelFirst) {
      try {
        await realtime.cancel();
      } catch (_) {}
    }
    try {
      await realtime.dispose();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await disposeRealtimeSafely(cancelFirst: true);
    if (_ownsAudio) {
      try {
        await _audio.dispose();
      } catch (_) {}
    }
  }
}

/// 语音转写与语义解析回退链（云端实时→云端批量→本地 [LocalAsrService] / [LocalParser]）。
class VoiceRecognitionPipeline {
  VoiceRecognitionPipeline({
    required bool Function() isCloudAsrEnabled,
    required bool Function() isCloudParseEnabled,
    VoiceCloudTranscribeFn? cloudTranscribe,
    VoiceCloudParseFn? cloudParse,
    LocalAsrService? localAsr,
    LocalParser? localParser,
    required List<String> Function() rosterNamesProvider,
    required List<String> Function() asrHotwordsProvider,
  }) : _isCloudAsrEnabled = isCloudAsrEnabled,
       _isCloudParseEnabled = isCloudParseEnabled,
       _cloudTranscribe = cloudTranscribe,
       _cloudParse = cloudParse,
       _localAsr = localAsr,
       _localParser = localParser ?? LocalParser(),
       _rosterNamesProvider = rosterNamesProvider,
       _asrHotwordsProvider = asrHotwordsProvider;

  final bool Function() _isCloudAsrEnabled;
  final bool Function() _isCloudParseEnabled;
  final VoiceCloudTranscribeFn? _cloudTranscribe;
  final VoiceCloudParseFn? _cloudParse;
  final LocalAsrService? _localAsr;
  final LocalParser _localParser;
  final List<String> Function() _rosterNamesProvider;
  final List<String> Function() _asrHotwordsProvider;

  /// 汇总实时结果或触发批量云端→本地回退转写。
  Future<String> resolveTranscript({
    required VoiceCaptureResult capture,
    required String opId,
    required int Function() elapsedMs,
  }) async {
    try {
      final trimmedRealtime = capture.realtimeText?.trim() ?? '';
      final String text;
      if (trimmedRealtime.isNotEmpty) {
        text = trimmedRealtime;
      } else if (capture.usedRealtime && capture.bytes.length <= 44) {
        // 实时流仅含 44 字节 WAV 头、无有效 PCM 采样，直接视为空语音。
        text = '';
      } else {
        text = await _transcribeWithFallback(capture.bytes, opId: opId);
      }
      OpLogService.instance.record(
        opId,
        'transcribe_ok',
        '转写成功',
        data: <String, dynamic>{'text': text, 'ms': elapsedMs()},
      );
      return text;
    } catch (error) {
      OpLogService.instance.record(
        opId,
        'transcribe_err',
        '转写失败: $error',
        level: 'error',
      );
      rethrow;
    }
  }

  Future<String> _transcribeWithFallback(
    Uint8List bytes, {
    required String opId,
  }) async {
    if (_isCloudAsrEnabled() && _cloudTranscribe != null) {
      try {
        final text = await _cloudTranscribe(bytes, opId: opId);
        if (text.trim().isNotEmpty) return text;
      } catch (error) {
        if (_localAsr == null) rethrow;
        OpLogService.instance.record(
          opId,
          'transcribe_fallback',
          '云端转写失败，切换本地识别: $error',
          level: 'warn',
        );
      }
    }
    final asr = _localAsr;
    if (asr == null) throw StateError('未配置本地语音识别');
    final hotwords = _asrHotwordsProvider();
    OpLogService.instance.record(
      opId,
      'local_asr_hotwords',
      '本地识别热词 ${hotwords.length} 个',
      data: <String, dynamic>{
        'count': hotwords.length,
        'sample': hotwords.take(8).toList(),
      },
    );
    final text = await asr.transcribe(bytes, hotwords: hotwords);
    if (text.trim().isEmpty) throw StateError('本地识别未听清，请再说一遍');
    return text;
  }

  /// 云端语义解析优先，失败或开关关闭时切换本地规则解析。
  Future<ParseResult> parseWithFallback(
    String text, {
    required String opId,
    required int Function() elapsedMs,
  }) async {
    try {
      ParseResult parsed;
      if (_isCloudParseEnabled() && _cloudParse != null) {
        try {
          parsed = await _cloudParse(text, opId: opId);
        } catch (error) {
          OpLogService.instance.record(
            opId,
            'parse_fallback',
            '云端解析失败，切换本地解析: $error',
            level: 'warn',
          );
          parsed = _localParser.parse(
            text,
            firefighters: _rosterNamesProvider(),
          );
        }
      } else {
        parsed = _localParser.parse(text, firefighters: _rosterNamesProvider());
      }
      OpLogService.instance.record(
        opId,
        'parse_ok',
        '语义解析完成',
        data: <String, dynamic>{
          'text': text,
          'parsed': parsed.toJson(),
          'ms': elapsedMs(),
        },
      );
      return parsed;
    } catch (error) {
      OpLogService.instance.record(
        opId,
        'parse_err',
        '解析失败: $error',
        level: 'error',
      );
      rethrow;
    }
  }
}

/// 将新解析出的进场人员合并至现有待确认草稿（同名更正压力，新名按名单过滤追加）。
void mergeParsedPeopleIntoDrafts({
  required List<VoiceDraftPerson> drafts,
  required List<ParsePerson> people,
  required List<String> rosterNames,
  required double defaultVolumeL,
  required String Function() nextId,
}) {
  final normalizedVol = normalizeCylinderVolume(defaultVolumeL);
  for (final person in people) {
    final idx = drafts.indexWhere(
      (d) =>
          (d.trimmedName == person.name && d.trimmedName.isNotEmpty) ||
          d.sourceName == person.name,
    );
    if (idx >= 0) {
      if (person.pressureMpa != null) {
        drafts[idx] = drafts[idx].copyWith(
          pressureText: VoiceDraftPerson.formatPressureInput(
            person.pressureMpa,
          ),
        );
      }
      continue;
    }
    final known = isKnownRosterName(person.name, rosterNames);
    drafts.add(
      VoiceDraftPerson(
        id: nextId(),
        name: known ? person.name : '',
        sourceName: known ? null : person.name,
        pressureText: VoiceDraftPerson.formatPressureInput(person.pressureMpa),
        volumeL: normalizedVol,
      ),
    );
  }
}

/// 解析完成后的纯状态转移计算结果。
class VoiceParsedTransition {
  const VoiceParsedTransition({
    required this.nextStatus,
    required this.outcome,
    this.keepTranscript = false,
    this.errorMessage,
    this.endOpKey,
    this.statedVolumeL,
  });

  final VoiceSessionStatus nextStatus;
  final VoiceFinishOutcome outcome;
  final bool keepTranscript;
  final String? errorMessage;
  final String? endOpKey;
  final double? statedVolumeL;
}

/// 根据转写文本与语义解析结果计算状态机转移并同步更新草稿队列。
VoiceParsedTransition evaluateParsedVoiceResult({
  required String text,
  required ParseResult parsed,
  required String opId,
  required List<VoiceDraftPerson> drafts,
  required List<String> rosterNames,
  required double? currentStatedVolumeL,
  required double fallbackVolumeL,
  required String Function() nextDraftId,
}) {
  final statedVol = extractCylinderVolumeL(text);
  if (statedVol != null) {
    OpLogService.instance.record(
      opId,
      'volume_detected',
      '识别到气瓶容积',
      data: <String, dynamic>{'text': text, 'volume_l': statedVol},
    );
    for (var i = 0; i < drafts.length; i++) {
      drafts[i] = drafts[i].copyWith(volumeL: statedVol);
    }
  }
  final effectiveVol = statedVol ?? currentStatedVolumeL;

  if (parsed.intent == VoiceIntent.note || parsed.intent == VoiceIntent.ask) {
    final isNote = parsed.intent == VoiceIntent.note;
    OpLogService.instance.record(
      opId,
      isNote ? 'note_auto' : 'ask_auto',
      isNote ? '识别为火场日志，跳转日志页' : '识别为提问，跳转辅助问答',
      data: <String, dynamic>{'text': text},
    );
    return VoiceParsedTransition(
      nextStatus: VoiceSessionStatus.idle,
      endOpKey: isNote ? 'note' : 'ask',
      statedVolumeL: effectiveVol,
      outcome: VoiceFinishOutcome(
        type: isNote ? VoiceFinishOutcomeType.note : VoiceFinishOutcomeType.ask,
        opId: opId,
        transcript: text,
        parseResult: parsed,
      ),
    );
  }

  if (parsed.intent == VoiceIntent.ignore) {
    OpLogService.instance.record(
      opId,
      'ignore_auto',
      '环境音/无关内容，丢弃',
      data: <String, dynamic>{'text': text},
    );
    const msg = '未识别到有效指令，请重新录入';
    return VoiceParsedTransition(
      nextStatus: VoiceSessionStatus.error,
      errorMessage: msg,
      endOpKey: 'ignore',
      statedVolumeL: effectiveVol,
      outcome: VoiceFinishOutcome(
        type: VoiceFinishOutcomeType.ignored,
        opId: opId,
        transcript: text,
        parseResult: parsed,
        errorMessage: msg,
      ),
    );
  }

  if (parsed.intent == VoiceIntent.exit || parsed.action == 'exit') {
    return VoiceParsedTransition(
      nextStatus: VoiceSessionStatus.idle,
      keepTranscript: true,
      statedVolumeL: effectiveVol,
      outcome: VoiceFinishOutcome(
        type: VoiceFinishOutcomeType.exit,
        opId: opId,
        transcript: text,
        parseResult: parsed,
      ),
    );
  }

  if (parsed.people.isEmpty) {
    OpLogService.instance.record(
      opId,
      'entry_empty',
      '进场意图未识别到姓名',
      data: <String, dynamic>{'text': text},
    );
    const msg = '未识别到进场人员姓名，请重新报：姓名+压力';
    return VoiceParsedTransition(
      nextStatus: VoiceSessionStatus.error,
      errorMessage: msg,
      endOpKey: 'entry_empty',
      statedVolumeL: effectiveVol,
      outcome: VoiceFinishOutcome(
        type: VoiceFinishOutcomeType.entryEmpty,
        opId: opId,
        transcript: text,
        parseResult: parsed,
        errorMessage: msg,
      ),
    );
  }

  mergeParsedPeopleIntoDrafts(
    drafts: drafts,
    people: parsed.people,
    rosterNames: rosterNames,
    defaultVolumeL: effectiveVol ?? fallbackVolumeL,
    nextId: nextDraftId,
  );
  return VoiceParsedTransition(
    nextStatus: VoiceSessionStatus.confirming,
    keepTranscript: true,
    statedVolumeL: effectiveVol,
    outcome: VoiceFinishOutcome(
      type: VoiceFinishOutcomeType.entryConfirm,
      opId: opId,
      transcript: text,
      parseResult: parsed,
    ),
  );
}
