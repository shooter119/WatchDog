import 'package:flutter/foundation.dart';

import '../../../services/realtime_asr_service.dart';
import '../data/models/voice_parse.dart';
import 'voice_draft_person.dart';

/// 全局语音状态机运行态。
enum VoiceSessionStatus { idle, recording, processing, confirming, error }

/// 单次录音转写与解析的收口结果类型。
enum VoiceFinishOutcomeType {
  ignored,
  cancelled,
  noSpeech,
  error,
  entryConfirm,
  entryEmpty,
  exit,
  note,
  ask,
}

/// 单次 `finishRecording()` 的结构化结果，便于外壳/路由器精确分发。
@immutable
class VoiceFinishOutcome {
  const VoiceFinishOutcome({
    required this.type,
    this.opId,
    this.transcript,
    this.parseResult,
    this.errorMessage,
  });

  final VoiceFinishOutcomeType type;
  final String? opId;
  final String? transcript;
  final ParseResult? parseResult;
  final String? errorMessage;
}

/// 实时流式 ASR 会话抽象，用于解耦 `VoiceSessionStore` 与底层传输创建。
abstract class VoiceRealtimeSession {
  Future<void> start({String? opId});
  Stream<double> amplitudeStream();
  Future<RealtimeAsrResult> stop();
  Future<Uint8List> cancel();
  Future<void> dispose();
}

/// 默认适配器：外层薄包裹冻结服务 [RealtimeAsrService]。
class RealtimeAsrSessionAdapter implements VoiceRealtimeSession {
  RealtimeAsrSessionAdapter(this._service);

  final RealtimeAsrService _service;

  @override
  Future<void> start({String? opId}) => _service.start(opId: opId);

  @override
  Stream<double> amplitudeStream() => _service.amplitudeStream();

  @override
  Future<RealtimeAsrResult> stop() => _service.stop();

  @override
  Future<Uint8List> cancel() => _service.cancel();

  @override
  Future<void> dispose() => _service.dispose();
}

typedef VoiceRealtimeSessionFactory =
    VoiceRealtimeSession Function(RealtimeTextCallback onText);

typedef VoiceCloudTranscribeFn =
    Future<String> Function(Uint8List wavBytes, {String? opId});

typedef VoiceCloudParseFn =
    Future<ParseResult> Function(String text, {String? opId});

/// 语音模块使用的轻量在场人员快照（零依赖 monitor feature）。
@immutable
class VoiceActiveEntry {
  const VoiceActiveEntry({
    required this.id,
    required this.name,
    required this.version,
    this.pressureMpa = 0,
    this.remainingMinutes = 0,
  });

  final String id;
  final String name;
  final int version;
  final double pressureMpa;
  final double remainingMinutes;
}

/// 同名在场冲突处理选择（与 monitor 同名弹窗契约对齐，零跨 Feature 导入）。
enum VoiceSameNameChoice { merge, force }

/// 服务端 409 同名冲突的解耦异常包装。
class VoiceEntryConflictException implements Exception {
  const VoiceEntryConflictException(this.existing);

  final VoiceActiveEntry existing;

  @override
  String toString() => 'VoiceEntryConflictException(${existing.name})';
}

/// 5 类语音意图的细化路由分类。
enum VoiceRouteType {
  entryConfirm,
  entryEmpty,
  exitNamed,
  exitAll,
  note,
  ask,
  ignore,
}

/// 出场指令（指定人员或全员离场）执行结果。
@immutable
class VoiceExitResult {
  const VoiceExitResult({
    this.exitedNames = const <String>[],
    this.notFoundNames = const <String>[],
    this.cancelled = false,
    this.noActiveEntries = false,
    this.errorMessage,
    this.actionLogError,
  });

  final List<String> exitedNames;
  final List<String> notFoundNames;
  final bool cancelled;
  final bool noActiveEntries;
  final String? errorMessage;
  final String? actionLogError;

  bool get hasExited => exitedNames.isNotEmpty;
}

/// 批量确认进场执行结果。
@immutable
class VoiceConfirmAllResult {
  const VoiceConfirmAllResult({
    this.succeededNames = const <String>[],
    this.succeededPressures = const <String, double>{},
    this.failedNames = const <String>[],
    this.keptDrafts = const <VoiceDraftPerson>[],
    this.validationErrors = const <String>[],
    this.allDone = false,
    this.errorMessage,
    this.actionLogError,
  });

  final List<String> succeededNames;
  final Map<String, double> succeededPressures;
  final List<String> failedNames;
  final List<VoiceDraftPerson> keptDrafts;
  final List<String> validationErrors;
  final bool allDone;
  final String? errorMessage;
  final String? actionLogError;
}

/// 单条意图分发执行结果。
@immutable
class VoiceRouteOutcome {
  const VoiceRouteOutcome({
    required this.type,
    this.exitResult,
    this.noteSaved = false,
    this.errorMessage,
  });

  final VoiceRouteType type;
  final VoiceExitResult? exitResult;
  final bool noteSaved;
  final String? errorMessage;
}

typedef VoiceCreateEntryFn =
    Future<void> Function({
      required String name,
      required double pressureMpa,
      required double volumeL,
      String? rawText,
      bool force,
      String? opId,
    });

typedef VoiceMergePressureFn =
    Future<void> Function({
      required String id,
      required int expectedVersion,
      required double pressureMpa,
      String? opId,
    });

typedef VoiceMarkExitedFn =
    Future<void> Function({
      required String id,
      required int expectedVersion,
      String? opId,
    });

typedef VoiceSameNameResolver =
    Future<VoiceSameNameChoice?> Function(
      VoiceActiveEntry existing,
      double pressureMpa,
    );

typedef VoiceActionLogFn =
    Future<void> Function({
      required List<String> names,
      required String action,
      Map<String, double>? pressuresMpa,
      required String category,
      required String opId,
    });

typedef VoiceShowMessageFn = void Function(String message, {Duration duration});
