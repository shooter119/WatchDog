import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../services/op_log_service.dart';
import '../data/models/voice_parse.dart';
import 'voice_draft_person.dart';
import 'voice_session_types.dart';

export 'voice_session_types.dart'
    show
        VoiceActionLogFn,
        VoiceActiveEntry,
        VoiceConfirmAllResult,
        VoiceCreateEntryFn,
        VoiceEntryConflictException,
        VoiceExitResult,
        VoiceMarkExitedFn,
        VoiceMergePressureFn,
        VoiceRouteOutcome,
        VoiceRouteType,
        VoiceSameNameChoice,
        VoiceSameNameResolver,
        VoiceShowMessageFn;

enum _SingleSubmitStatus { created, merged, cancelled, error }

/// 全局语音 5 类意图路由器与进出场事务编排器。
///
/// 通过回调注入与 `MonitorStore` / `NotesStore` / `SameNameConflictSheet` 解耦，
/// 保证 `features/voice/` 对其他 Feature 保持零导入。
class VoiceIntentRouter {
  const VoiceIntentRouter({
    required this.activeEntriesProvider,
    required this.onCreateEntry,
    required this.onMergeEntryPressure,
    required this.onMarkExited,
    required this.onResolveSameName,
    required this.onWriteActionLog,
    required this.onRouteNote,
    required this.onRouteAsk,
    this.onConfirmAllExit,
    this.onNotifyNoActiveEntriesForAllExit,
    this.onEntryConfirmed,
    this.onSpeak,
    this.onShowMessage,
    this.onFlushOpLogs,
  });

  static const String _deployCategory = '部署';
  static const String _withdrawCategory = '撤离';

  final List<VoiceActiveEntry> Function() activeEntriesProvider;
  final VoiceCreateEntryFn onCreateEntry;
  final VoiceMergePressureFn onMergeEntryPressure;
  final VoiceMarkExitedFn onMarkExited;
  final VoiceSameNameResolver onResolveSameName;
  final VoiceActionLogFn onWriteActionLog;
  final Future<void> Function(String text) onRouteNote;
  final void Function(String text) onRouteAsk;
  final Future<bool> Function(List<VoiceActiveEntry> active, String voiceText)?
  onConfirmAllExit;
  final Future<void> Function()? onNotifyNoActiveEntriesForAllExit;
  final VoidCallback? onEntryConfirmed;
  final void Function(String text)? onSpeak;
  final VoiceShowMessageFn? onShowMessage;
  final VoidCallback? onFlushOpLogs;

  /// 按 `ParseResult` 精确分类为 5 大意图（进场含无姓名拦截、出场区分指定/全员）。
  VoiceRouteType classify(ParseResult parsed) {
    if (parsed.intent == VoiceIntent.note) return VoiceRouteType.note;
    if (parsed.intent == VoiceIntent.ask) return VoiceRouteType.ask;
    if (parsed.intent == VoiceIntent.ignore) return VoiceRouteType.ignore;
    if (parsed.intent == VoiceIntent.exit || parsed.action == 'exit') {
      return parsed.people.isNotEmpty
          ? VoiceRouteType.exitNamed
          : VoiceRouteType.exitAll;
    }
    return parsed.people.isEmpty
        ? VoiceRouteType.entryEmpty
        : VoiceRouteType.entryConfirm;
  }

  /// 分发单次语音解析结果（`note`/`ask`/`ignore`/`exitNamed`/`exitAll`/`entry*`）。
  Future<VoiceRouteOutcome> routeParsed({
    required String text,
    required ParseResult parsed,
    String? opId,
  }) async {
    final type = classify(parsed);
    switch (type) {
      case VoiceRouteType.note:
        try {
          await onRouteNote(text);
          return const VoiceRouteOutcome(
            type: VoiceRouteType.note,
            noteSaved: true,
          );
        } catch (error) {
          OpLogService.instance.record(
            opId ?? 'note-${DateTime.now().millisecondsSinceEpoch}',
            'note_add_fail',
            '自动记日志失败：$error',
            level: 'error',
            data: <String, dynamic>{'text': text},
          );
          onShowMessage?.call(
            '记日志失败：$error',
            duration: const Duration(seconds: 3),
          );
          return VoiceRouteOutcome(
            type: VoiceRouteType.note,
            noteSaved: false,
            errorMessage: '$error',
          );
        }
      case VoiceRouteType.ask:
        onRouteAsk(text);
        return const VoiceRouteOutcome(type: VoiceRouteType.ask);
      case VoiceRouteType.ignore:
        return const VoiceRouteOutcome(
          type: VoiceRouteType.ignore,
          errorMessage: '未识别到有效指令，请重新录入',
        );
      case VoiceRouteType.exitNamed:
        final exitResult = await executeNamedExit(
          parsed.people.map((p) => p.name).toList(growable: false),
          opId: opId,
        );
        return VoiceRouteOutcome(
          type: VoiceRouteType.exitNamed,
          exitResult: exitResult,
          errorMessage: exitResult.errorMessage,
        );
      case VoiceRouteType.exitAll:
        final exitResult = await executeAllExit(text, opId: opId);
        return VoiceRouteOutcome(
          type: VoiceRouteType.exitAll,
          exitResult: exitResult,
          errorMessage: exitResult.errorMessage,
        );
      case VoiceRouteType.entryEmpty:
        return const VoiceRouteOutcome(
          type: VoiceRouteType.entryEmpty,
          errorMessage: '未识别到进场人员姓名，请重新报：姓名+压力',
        );
      case VoiceRouteType.entryConfirm:
        return const VoiceRouteOutcome(type: VoiceRouteType.entryConfirm);
    }
  }

  /// 执行指定人员批量退场并同步写 `撤离` 火场日志。
  Future<VoiceExitResult> executeNamedExit(
    List<String> names, {
    String? opId,
  }) async {
    final activeAll = activeEntriesProvider();
    final notFound = <String>[];
    final exitedNames = <String>[];
    for (final name in names) {
      final matches = activeAll.where((e) => e.name == name).toList();
      if (matches.isEmpty) {
        notFound.add(name);
        OpLogService.instance.record(
          opId ?? '',
          'exit_skip',
          '未找到在场人员「$name」',
          level: 'warn',
        );
        continue;
      }
      for (final entry in matches) {
        await onMarkExited(
          id: entry.id,
          expectedVersion: entry.version,
          opId: '${opId ?? 'exit'}-${entry.id}',
        );
        OpLogService.instance.record(
          opId ?? '',
          'exit_ok',
          '已登记「$name」出火场',
          data: <String, dynamic>{'entryId': entry.id, 'name': name},
        );
      }
      exitedNames.add(name);
    }

    String? actionLogError;
    if (exitedNames.isNotEmpty) {
      actionLogError = await _writeActionLogSafely(
        exitedNames,
        action: '出场',
        category: _withdrawCategory,
        opId: opId,
        opSuffix: 'exit-note',
      );
      final joined = exitedNames.join('、');
      onSpeak?.call('$joined 已登记出火场');
      onShowMessage?.call('$joined 已登记出火场', duration: const Duration(seconds: 2));
    }
    _recordOpEnd(opId, exitedNames.isNotEmpty ? 'exit_ok' : 'exit_none');
    return VoiceExitResult(
      exitedNames: exitedNames,
      notFoundNames: notFound,
      errorMessage: notFound.isEmpty ? null : '未找到在场人员「${notFound.join('、')}」',
      actionLogError: actionLogError,
    );
  }

  /// 执行全员离场二次确认并批量标记在场人员离场。
  Future<VoiceExitResult> executeAllExit(
    String voiceText, {
    String? opId,
  }) async {
    final active = activeEntriesProvider();
    if (active.isEmpty) {
      await onNotifyNoActiveEntriesForAllExit?.call();
      _recordOpEnd(opId, 'exit_all_none');
      return const VoiceExitResult(noActiveEntries: true);
    }

    final confirmed =
        await (onConfirmAllExit?.call(active, voiceText) ?? Future<bool>.value(false));
    if (!confirmed) {
      OpLogService.instance.record(opId ?? '', 'exit_all_cancelled', '用户取消全员离场');
      onShowMessage?.call('已取消全员离场', duration: const Duration(seconds: 2));
      _recordOpEnd(opId, 'exit_all_cancel');
      return const VoiceExitResult(cancelled: true);
    }

    final exitedNames = <String>[];
    for (final entry in active) {
      await onMarkExited(
        id: entry.id,
        expectedVersion: entry.version,
        opId: '${opId ?? 'exit'}-${entry.id}',
      );
      OpLogService.instance.record(
        opId ?? '',
        'exit_all_ok',
        '全员离场已登记「${entry.name}」',
        data: <String, dynamic>{'entryId': entry.id, 'name': entry.name},
      );
      exitedNames.add(entry.name);
    }

    final actionLogError = await _writeActionLogSafely(
      exitedNames,
      action: '出场',
      category: _withdrawCategory,
      opId: opId,
      opSuffix: 'exit-all-note',
    );
    onSpeak?.call('全体人员已登记离场');
    onShowMessage?.call(
      '已全员离场（${exitedNames.length} 人）',
      duration: const Duration(seconds: 2),
    );
    _recordOpEnd(opId, 'exit_all', data: <String, dynamic>{'count': exitedNames.length});
    return VoiceExitResult(exitedNames: exitedNames, actionLogError: actionLogError);
  }

  /// 一次性确认全部待确认人员进场：先全量校验，再逐人提交（含同名冲突处理与动作日志）。
  Future<VoiceConfirmAllResult> confirmAllEntries(
    List<VoiceDraftPerson> drafts, {
    String? transcript,
    String? opId,
  }) async {
    if (drafts.isEmpty) {
      return const VoiceConfirmAllResult(errorMessage: '未识别到人员信息，请重新语音输入');
    }
    final validationErrors = validateVoiceDrafts(drafts);
    if (validationErrors.isNotEmpty) {
      return VoiceConfirmAllResult(
        keptDrafts: List<VoiceDraftPerson>.unmodifiable(drafts),
        validationErrors: validationErrors,
      );
    }

    final results = <({VoiceDraftPerson draft, _SingleSubmitStatus status})>[];
    String? lastError;
    for (final draft in drafts) {
      final outcome = await _submitSingle(draft, transcript: transcript, opId: opId);
      if (outcome.error != null) lastError = outcome.error;
      _logSingleSubmit(draft, outcome.status, opId: opId);
      results.add((draft: draft, status: outcome.status));
      if (outcome.status == _SingleSubmitStatus.cancelled) break;
    }

    final done = <String>[];
    final donePressures = <String, double>{};
    final failed = <String>[];
    final kept = <VoiceDraftPerson>[];
    for (final item in results) {
      final ok = item.status == _SingleSubmitStatus.created ||
          item.status == _SingleSubmitStatus.merged;
      if (ok) {
        done.add(item.draft.trimmedName);
        donePressures[item.draft.trimmedName] = item.draft.pressureMpa!;
      } else {
        failed.add(item.draft.trimmedName);
        kept.add(item.draft);
      }
    }
    for (var i = results.length; i < drafts.length; i++) {
      kept.add(drafts[i]);
    }

    if (done.isNotEmpty) {
      final joined = done.join('、');
      onSpeak?.call('$joined，已开始倒计时');
      onShowMessage?.call('$joined 已入火场，开始倒计时', duration: const Duration(seconds: 2));
    }
    final allDone = failed.isEmpty && kept.isEmpty;
    if (!allDone && failed.isNotEmpty) {
      onShowMessage?.call(
        '未登记：${failed.join('、')}，请修正后再次确认',
        duration: const Duration(seconds: 3),
      );
    }

    String? actionLogError;
    if (allDone) {
      // 进场登记成功后先跳转现场监控，日志写入作为后置动作不阻塞视图切换。
      onEntryConfirmed?.call();
      actionLogError = await _writeActionLogSafely(
        done,
        action: '进场',
        pressuresMpa: donePressures,
        category: _deployCategory,
        opId: opId,
        opSuffix: 'entry-note',
      );
      _recordOpEnd(opId, 'enter_ok', data: <String, dynamic>{'names': done});
    }

    return VoiceConfirmAllResult(
      succeededNames: done,
      succeededPressures: donePressures,
      failedNames: failed,
      keptDrafts: kept,
      allDone: allDone,
      errorMessage: lastError,
      actionLogError: actionLogError,
    );
  }

  void _logSingleSubmit(
    VoiceDraftPerson draft,
    _SingleSubmitStatus status, {
    required String? opId,
  }) {
    if (status == _SingleSubmitStatus.created || status == _SingleSubmitStatus.merged) {
      OpLogService.instance.record(
        opId ?? '',
        'confirm_enter',
        '已登记「${draft.trimmedName}」进场',
        data: <String, dynamic>{
          'name': draft.trimmedName,
          'pressure_mpa': draft.pressureMpa,
          'volume_l': draft.volumeL,
          'result': status == _SingleSubmitStatus.created ? 'created' : 'merged',
        },
      );
    } else if (status == _SingleSubmitStatus.error) {
      OpLogService.instance.record(
        opId ?? '',
        'confirm_err',
        '「${draft.trimmedName}」登记进场失败',
        level: 'error',
      );
    }
  }

  Future<({_SingleSubmitStatus status, String? error})> _submitSingle(
    VoiceDraftPerson draft, {
    required String? transcript,
    required String? opId,
  }) async {
    final name = draft.trimmedName;
    final pressure = draft.pressureMpa!;
    final existing = activeEntriesProvider().where((e) => e.name == name);
    if (existing.isNotEmpty) {
      return _resolveSameNameConflict(existing.first, pressure, opId: opId);
    }
    final encodedName = base64Url.encode(utf8.encode(name)).replaceAll('=', '');
    try {
      await onCreateEntry(
        name: name,
        pressureMpa: pressure,
        volumeL: draft.volumeL,
        rawText: transcript,
        force: false,
        opId: '${opId ?? 'entry'}-$encodedName',
      );
      return (status: _SingleSubmitStatus.created, error: null);
    } on VoiceEntryConflictException catch (conflict) {
      return _resolveSameNameConflict(conflict.existing, pressure, opId: opId);
    } catch (error) {
      OpLogService.instance.record(opId ?? '', 'create_err', '登记进场失败: $error', level: 'error');
      return (status: _SingleSubmitStatus.error, error: '$error');
    }
  }

  Future<({_SingleSubmitStatus status, String? error})> _resolveSameNameConflict(
    VoiceActiveEntry existing,
    double pressure, {
    required String? opId,
  }) async {
    final choice = await onResolveSameName(existing, pressure);
    if (choice == null) return (status: _SingleSubmitStatus.cancelled, error: null);
    if (choice == VoiceSameNameChoice.merge) {
      try {
        await onMergeEntryPressure(
          id: existing.id,
          expectedVersion: existing.version,
          pressureMpa: pressure,
          opId: opId,
        );
        return (status: _SingleSubmitStatus.merged, error: null);
      } catch (error) {
        OpLogService.instance.record(opId ?? '', 'merge_err', '合并压力失败: $error', level: 'error');
        return (status: _SingleSubmitStatus.error, error: '$error');
      }
    }
    return (
      status: _SingleSubmitStatus.cancelled,
      error: '请在姓名中补充单位或编号，区分同名人员后重新登记',
    );
  }

  Future<String?> _writeActionLogSafely(
    List<String> names, {
    required String action,
    Map<String, double>? pressuresMpa,
    required String category,
    required String? opId,
    required String opSuffix,
  }) async {
    try {
      await onWriteActionLog(
        names: names,
        action: action,
        pressuresMpa: pressuresMpa,
        category: category,
        opId: '${opId ?? 'action'}-$opSuffix',
      );
      OpLogService.instance.record(
        opId ?? '',
        'action_note_created',
        '同步生成火场日志',
        data: <String, dynamic>{'action': action, 'names': names},
      );
      return null;
    } catch (error) {
      OpLogService.instance.record(
        opId ?? '',
        'action_note_failed',
        '同步生成火场日志失败：$error',
        level: 'error',
        data: <String, dynamic>{'action': action, 'names': names},
      );
      onShowMessage?.call(
        '进出场已登记，但火场日志写入失败：$error',
        duration: const Duration(seconds: 3),
      );
      return '$error';
    }
  }

  void _recordOpEnd(String? opId, String outcome, {Map<String, dynamic>? data}) {
    if (opId == null || opId.isEmpty) return;
    OpLogService.instance.record(
      opId,
      'op_end',
      '本次操作结束',
      data: <String, dynamic>{'outcome': outcome, ...?data},
    );
    onFlushOpLogs?.call();
  }
}
