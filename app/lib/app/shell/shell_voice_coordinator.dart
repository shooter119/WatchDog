import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/monitor/data/models/entry.dart';
import '../../features/monitor/data/monitor_exceptions.dart';
import '../../features/monitor/ui/sheets/same_name_conflict_sheet.dart';
import '../../features/voice/state/voice_draft_person.dart';
import '../../features/voice/state/voice_intent_router.dart';
import '../../features/voice/state/voice_session_store.dart';
import '../../features/voice/ui/voice_confirm_sheet.dart';
import '../../features/voice/ui/voice_exit_confirm_sheet.dart';
import '../../features/voice/ui/voice_recording_overlay.dart';
import '../../services/op_log_service.dart';
import '../../services/realtime_asr_service.dart';
import '../../state/app_controller.dart';
import 'shell_voice_bridge.dart';

/// 新外壳全局语音协调器（M3b 接线层）。
///
/// 协调 [VoiceSessionStore]、[VoiceIntentRouter]、[VoiceRecordingOverlay]、
/// [VoiceConfirmSheet]、[VoiceExitConfirmSheet] 与 [SameNameConflictSheet]，
/// 在 Tab 0/1/3 长按中置语音键时实现跨页原地录音与 5 类意图分发。
class ShellVoiceCoordinator extends ChangeNotifier {
  ShellVoiceCoordinator({
    required this.controller,
    required this.voiceBridge,
    required this.navigatorKey,
    required this.findEntryById,
    required this.onShowMessage,
    required this.onSelectTab,
    VoiceSessionStore? sessionStoreOverride,
    VoiceIntentRouter? routerOverride,
  }) : _ownsSessionStore = sessionStoreOverride == null {
    sessionStore = sessionStoreOverride ?? _buildDefaultSessionStore();
    router = routerOverride ?? _buildDefaultRouter();
    sessionStore.addListener(_onSessionChanged);
    _syncBridgeState();
  }

  final AppController controller;
  final ShellVoiceBridge voiceBridge;
  final GlobalKey<NavigatorState> navigatorKey;
  final Entry? Function(String id) findEntryById;
  final ShellVoiceMessageCallback onShowMessage;
  final ValueChanged<int> onSelectTab;
  final bool _ownsSessionStore;

  late final VoiceSessionStore sessionStore;
  late final VoiceIntentRouter router;

  final Map<String, Entry> _conflictEntries = <String, Entry>{};
  bool _confirmSheetOpen = false;
  bool _preserveDraftsOnSheetClose = false;
  bool _submittingConfirm = false;
  bool _disposed = false;

  /// 当前是否需要在外壳根部渲染全局录音/识别/错误浮层。
  bool get shouldShowOverlay {
    if (_disposed) return false;
    return switch (sessionStore.status) {
      VoiceSessionStatus.recording => true,
      VoiceSessionStatus.error => true,
      VoiceSessionStatus.processing => !_confirmSheetOpen,
      VoiceSessionStatus.idle || VoiceSessionStatus.confirming => false,
    };
  }

  /// 长按启动跨页原地录音。
  Future<void> beginRecording() async {
    if (_disposed) return;
    await sessionStore.beginRecording();
  }

  /// 松手或点击兜底按钮结束录音并执行 5 类意图路由。
  Future<void> finishRecording() async {
    if (_disposed) return;
    final outcome = await sessionStore.finishRecording();
    await _handleFinishOutcome(outcome);
  }

  /// 构建挂载于外壳根部的全局语音录音/识别/错误浮层。
  Widget buildOverlay(BuildContext context) {
    if (!shouldShowOverlay) return const SizedBox.shrink();
    return VoiceRecordingOverlay(
      status: sessionStore.status,
      recordingSeconds: sessionStore.recordingSeconds,
      amplitude: sessionStore.amplitude,
      liveTranscript: sessionStore.transcript,
      pendingDraftCount: sessionStore.drafts.length,
      errorMessage: sessionStore.errorMessage,
      permissionDenied: sessionStore.permissionDenied,
      onStopRecording: () => unawaited(finishRecording()),
      onRetry: sessionStore.retry,
      onReturnToConfirm: sessionStore.hasPendingDrafts
          ? () {
              sessionStore.showPendingConfirm();
              _ensureConfirmSheetOpen();
            }
          : null,
      onDismiss: sessionStore.dismissError,
    );
  }

  VoiceSessionStore _buildDefaultSessionStore() {
    return VoiceSessionStore(
      isCloudAsrEnabled: () =>
          controller.asrCloudEnabled && controller.api != null,
      isCloudParseEnabled: () =>
          controller.parseCloudEnabled && controller.api != null,
      realtimeSessionFactory: (onText) {
        final api = controller.api!;
        return RealtimeAsrSessionAdapter(
          RealtimeAsrService(api: api, onText: onText),
        );
      },
      cloudTranscribe: (bytes, {opId}) =>
          controller.api!.transcribe(bytes, opId: opId),
      cloudParse: (text, {opId}) => controller.api!.parse(text, opId: opId),
      localAsr: controller.localAsr,
      localParser: controller.localParser,
      rosterNamesProvider: () => controller.orgDirectory.parserNames,
      asrHotwordsProvider: () => controller.orgDirectory.asrTerms,
      calcParamsProvider: () => VoiceCalcParams(
        cylinderVolL: controller.calcConfig.cylinderVolL,
        consumptionLpm: controller.calcConfig.consumptionLpm,
      ),
      onFlushOpLogs: _flushOpLogs,
      onAutoFinished: (outcome) => unawaited(_handleFinishOutcome(outcome)),
    );
  }

  VoiceIntentRouter _buildDefaultRouter() {
    return VoiceIntentRouter(
      activeEntriesProvider: _activeEntriesSnapshot,
      onCreateEntry: _createEntry,
      onMergeEntryPressure: _mergeEntryPressure,
      onMarkExited: _markExited,
      onResolveSameName: _resolveSameName,
      onWriteActionLog: _writeActionLog,
      onRouteNote: _routeNote,
      onRouteAsk: voiceBridge.routeAskIntent,
      onConfirmAllExit: _confirmAllExit,
      onNotifyNoActiveEntriesForAllExit: _notifyNoActiveEntries,
      onEntryConfirmed: voiceBridge.routeEntryConfirmed,
      onSpeak: controller.tts.speak,
      onShowMessage: onShowMessage,
      onFlushOpLogs: _flushOpLogs,
    );
  }

  void _onSessionChanged() {
    if (_disposed) return;
    _syncBridgeState();
    notifyListeners();
  }

  void _syncBridgeState() {
    voiceBridge.setCommandRecording(sessionStore.isRecording);
    voiceBridge.setCommandProcessing(sessionStore.isProcessing);
  }

  Future<void> _handleFinishOutcome(VoiceFinishOutcome outcome) async {
    if (_disposed) return;
    switch (outcome.type) {
      case VoiceFinishOutcomeType.entryConfirm:
        _ensureConfirmSheetOpen();
        return;
      case VoiceFinishOutcomeType.ignored:
        sessionStore.dismissError();
        onShowMessage(
          outcome.errorMessage ?? '未识别到有效指令，请重新录入',
          duration: const Duration(seconds: 2),
        );
        return;
      case VoiceFinishOutcomeType.note:
      case VoiceFinishOutcomeType.ask:
      case VoiceFinishOutcomeType.exit:
        final parsed = outcome.parseResult;
        if (parsed == null) return;
        final routed = await router.routeParsed(
          text: outcome.transcript ?? '',
          parsed: parsed,
          opId: outcome.opId,
        );
        if (_disposed) return;
        if (routed.type == VoiceRouteType.exitNamed &&
            routed.errorMessage != null &&
            !(routed.exitResult?.hasExited ?? false)) {
          onShowMessage(
            routed.errorMessage!,
            duration: const Duration(seconds: 3),
          );
        }
        return;
      case VoiceFinishOutcomeType.cancelled:
      case VoiceFinishOutcomeType.noSpeech:
      case VoiceFinishOutcomeType.entryEmpty:
      case VoiceFinishOutcomeType.error:
        return;
    }
  }

  void _ensureConfirmSheetOpen() {
    if (_disposed || _confirmSheetOpen) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    _confirmSheetOpen = true;
    _preserveDraftsOnSheetClose = false;
    notifyListeners();

    unawaited(
      showVoiceConfirmSheet(
        context: ctx,
        sheetBuilder: (BuildContext sheetContext) {
          return ListenableBuilder(
            listenable: Listenable.merge(<Listenable>[sessionStore, controller]),
            builder: (BuildContext context, _) {
              final activeNames = controller.entries
                  .where((e) => e.isActive)
                  .map((e) => e.name)
                  .toSet();
              return VoiceConfirmSheet(
                drafts: sessionStore.drafts,
                calcParams: sessionStore.calcParams,
                transcript: sessionStore.transcript,
                inlineError: sessionStore.inlineError,
                rosterNames: controller.orgDirectory.parserNames,
                activeEntryNames: activeNames,
                isProcessing: sessionStore.isProcessing,
                onNameChanged: sessionStore.updateDraftName,
                onPressureChanged: sessionStore.updateDraftPressure,
                onVolumeChanged: sessionStore.updateDraftVolume,
                onRemoveAt: (int idx) {
                  sessionStore.removeDraftAt(idx);
                  if (!sessionStore.hasPendingDrafts) {
                    _closeConfirmSheet(preserveDrafts: false);
                  }
                },
                onConfirmAll: () => unawaited(_confirmAll()),
                onContinueVoice: () {
                  _closeConfirmSheet(preserveDrafts: true);
                  unawaited(beginRecording());
                },
                onRetry: () {
                  sessionStore.retry();
                  _closeConfirmSheet(preserveDrafts: false);
                },
              );
            },
          );
        },
      ).whenComplete(() {
        final preserve = _preserveDraftsOnSheetClose;
        _confirmSheetOpen = false;
        _preserveDraftsOnSheetClose = false;
        if (!_disposed && !preserve && sessionStore.isConfirming) {
          sessionStore.retry();
        }
        if (!_disposed) notifyListeners();
      }),
    );
  }

  void _closeConfirmSheet({required bool preserveDrafts}) {
    if (!_confirmSheetOpen) return;
    _preserveDraftsOnSheetClose = preserveDrafts;
    final nav = navigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    }
  }

  Future<void> _confirmAll() async {
    if (_disposed || _submittingConfirm) return;
    _submittingConfirm = true;
    sessionStore.setSubmitting(true);
    try {
      final result = await router.confirmAllEntries(
        sessionStore.drafts,
        transcript: sessionStore.transcript,
        opId: sessionStore.currentOpId,
      );
      if (_disposed) return;
      final inlineErr = result.validationErrors.isNotEmpty
          ? result.validationErrors.join('\n')
          : (!result.allDone && result.keptDrafts.isNotEmpty
                ? result.errorMessage
                : null);
      sessionStore.applyConfirmOutcome(
        keptDrafts: result.keptDrafts,
        inlineError: inlineErr,
        errorMessage: result.allDone ? null : result.errorMessage,
      );
      if (result.allDone) {
        _closeConfirmSheet(preserveDrafts: false);
      }
    } finally {
      _submittingConfirm = false;
    }
  }

  List<VoiceActiveEntry> _activeEntriesSnapshot() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return controller.entries
        .where((e) => e.isActive)
        .map(
          (e) => VoiceActiveEntry(
            id: e.id,
            name: e.name,
            version: e.version,
            pressureMpa: e.pressureMpa ?? 0,
            remainingMinutes: (e.exitAt - nowMs) / 60000.0,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _createEntry({
    required String name,
    required double pressureMpa,
    required double volumeL,
    String? rawText,
    bool force = false,
    String? opId,
  }) async {
    try {
      await controller.createEntryFromVoice(
        name: name,
        pressureMpa: pressureMpa,
        volumeL: volumeL,
        rawText: rawText,
        force: force,
        opId: opId,
      );
    } on EntryConflictException catch (conflict) {
      final existing = conflict.existing;
      _conflictEntries[existing.id] = existing;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      throw VoiceEntryConflictException(
        VoiceActiveEntry(
          id: existing.id,
          name: existing.name,
          version: existing.version,
          pressureMpa: existing.pressureMpa ?? 0,
          remainingMinutes: (existing.exitAt - nowMs) / 60000.0,
        ),
      );
    }
  }

  Future<void> _mergeEntryPressure({
    required String id,
    required int expectedVersion,
    required double pressureMpa,
    String? opId,
  }) async {
    await controller.mergeEntryPressure(
      id: id,
      expectedVersion: expectedVersion,
      pressureMpa: pressureMpa,
      opId: opId,
    );
  }

  Future<void> _markExited({
    required String id,
    required int expectedVersion,
    String? opId,
  }) async {
    await controller.markExited(
      id,
      expectedVersion: expectedVersion,
      opId: opId,
    );
  }

  Future<VoiceSameNameChoice?> _resolveSameName(
    VoiceActiveEntry existing,
    double pressureMpa,
  ) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return null;
    final entry =
        _conflictEntries.remove(existing.id) ??
        findEntryById(existing.id) ??
        _fallbackEntry(existing);
    final durationMin = controller.calcConfig
        .durationMinFor(pressureMpa, cylinderVolL: entry.cylinderVolL)
        .round();
    final choice = await showSameNameConflictSheet(
      ctx,
      existing: entry,
      pressureMpa: pressureMpa,
      durationMin: durationMin,
    );
    return switch (choice) {
      SameNameChoice.merge => VoiceSameNameChoice.merge,
      SameNameChoice.force => VoiceSameNameChoice.force,
      null => null,
    };
  }

  Entry _fallbackEntry(VoiceActiveEntry existing) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final remainMin = existing.remainingMinutes.round();
    return Entry(
      id: existing.id,
      name: existing.name,
      pressureMpa: existing.pressureMpa > 0 ? existing.pressureMpa : null,
      durationMin: remainMin > 0 ? remainMin : 0,
      entryAt: nowMs,
      exitAt: nowMs + remainMin * 60000,
      source: 'voice',
      version: existing.version,
    );
  }

  Future<void> _writeActionLog({
    required List<String> names,
    required String action,
    Map<String, double>? pressuresMpa,
    required String category,
    required String opId,
  }) async {
    await controller.addActionLog(
      names: names,
      action: action,
      pressuresMpa: pressuresMpa,
      category: category,
      opId: opId,
    );
  }

  Future<void> _routeNote(String text) async {
    if (controller.needsIncidentSelection) return;
    if (controller.requiresIncident) {
      controller.requestIncidentSelection();
      return;
    }
    await controller.addNote(text);
    onShowMessage('已记入火场日志', duration: const Duration(seconds: 2));
    onSelectTab(ShellVoiceBridge.commandTabIndex);
  }

  Future<bool> _confirmAllExit(
    List<VoiceActiveEntry> active,
    String voiceText,
  ) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final confirmed = await showVoiceExitConfirmSheet(
      context: ctx,
      entries: active,
      voiceText: voiceText,
      isAllExit: true,
    );
    return confirmed == true;
  }

  Future<void> _notifyNoActiveEntries() async {
    onShowMessage('当前火场暂无在场人员', duration: const Duration(seconds: 2));
  }

  void _flushOpLogs() {
    unawaited(OpLogService.instance.flush(api: controller.api));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sessionStore.removeListener(_onSessionChanged);
    if (_ownsSessionStore) {
      sessionStore.dispose();
    }
    super.dispose();
  }
}
