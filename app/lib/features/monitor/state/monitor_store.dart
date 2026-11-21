import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/diagnostics/app_logger.dart';
import '../../../core/network/api_exceptions.dart';
import '../../../services/offline_queue.dart';
import '../../../services/op_log_service.dart';
import '../../../services/settings.dart';
import '../data/models/calc_config.dart';
import '../data/models/entry.dart';
import '../data/monitor_repository.dart';
import 'monitor_projection.dart';

export 'monitor_projection.dart' show MonitorRiskSummary;

typedef MonitorRepositoryProvider = MonitorRepository? Function();
typedef MonitorIncidentIdProvider = String? Function();
typedef MonitorUnitIdProvider = String Function();
typedef MonitorMemberIdProvider = Future<String> Function();
typedef MonitorSyncCallback = Future<void> Function();
typedef MonitorNoteCallback = Future<void> Function(String text, {required String category});
typedef MonitorActionLogCallback = Future<void> Function({
  required List<String> names,
  required String action,
  required String category,
  String? opId,
});
typedef MonitorSpeakCallback = void Function(String text);
typedef MonitorOfflineEnqueuer = Future<void> Function({
  required String incidentId,
  required String type,
  required int occurredAt,
  required String clientOpId,
  required Map<String, dynamic> payload,
  Map<String, String>? owner,
});

/// 现场监控（人员空呼安全）域状态容器。
///
/// 独立持有人员列表、[CalcConfig]、危险分级排序、风险统计及离线乐观投影；
/// 通过回调与外部同步/日志/播报解耦，严禁反向依赖其他 Store 或 `app/`。
class MonitorStore extends ChangeNotifier {
  static const Set<String> conflictErrorCodes = <String>{
    'VERSION_CONFLICT',
    'ENTRY_EXITED',
    'STALE_PRESSURE',
  };

  static CalcConfig defaultCalcConfig() => CalcConfig(
    cylinderVolL: 6.8,
    fullPressureMpa: 30,
    consumptionLpm: 80,
    warnMin: 10,
    alarmMin: 5,
  );

  MonitorStore({
    List<Entry> initialEntries = const <Entry>[],
    CalcConfig? initialCalcConfig,
    MonitorRepositoryProvider? repositoryProvider,
    MonitorIncidentIdProvider? incidentIdProvider,
    MonitorUnitIdProvider? unitIdProvider,
    MonitorMemberIdProvider? memberIdProvider,
    MonitorSyncCallback? onSync,
    MonitorNoteCallback? onAddNote,
    MonitorActionLogCallback? onAddActionLog,
    MonitorSpeakCallback? onSpeak,
    MonitorOfflineEnqueuer? offlineEnqueuer,
    int Function()? nowMs,
  }) : _entries = List<Entry>.of(initialEntries),
       _calcConfig = initialCalcConfig ?? defaultCalcConfig(),
       _repositoryProvider = repositoryProvider,
       _incidentIdProvider = incidentIdProvider,
       _unitIdProvider = unitIdProvider,
       _memberIdProvider = memberIdProvider,
       _onSync = onSync,
       _onAddNote = onAddNote,
       _onAddActionLog = onAddActionLog,
       _onSpeak = onSpeak,
       _offlineEnqueuer = offlineEnqueuer,
       _nowMs = nowMs ?? _defaultNowMs;

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

  final MonitorRepositoryProvider? _repositoryProvider;
  final MonitorIncidentIdProvider? _incidentIdProvider;
  final MonitorUnitIdProvider? _unitIdProvider;
  final MonitorMemberIdProvider? _memberIdProvider;
  final MonitorSyncCallback? _onSync;
  final MonitorNoteCallback? _onAddNote;
  final MonitorActionLogCallback? _onAddActionLog;
  final MonitorSpeakCallback? _onSpeak;
  final MonitorOfflineEnqueuer? _offlineEnqueuer;
  final int Function() _nowMs;

  List<Entry> _entries;
  CalcConfig _calcConfig;
  bool _disposed = false;

  List<Entry> get entries => _entries;
  CalcConfig get calcConfig => _calcConfig;
  bool get disposed => _disposed;

  static int severityOf(String status) => monitorSeverityOf(status);

  static String statusOf(Entry entry, CalcConfig config, {int? nowMs}) =>
      monitorStatusOf(entry, config, nowMs: nowMs);

  static String formatPressure(double value) => formatMonitorPressure(value);

  static bool isConflictError(Object error) =>
      error is ApiException && conflictErrorCodes.contains(error.code);

  static bool isNetworkError(Object error) =>
      error is TimeoutException ||
      (error is ApiException && (error.statusCode ?? 0) >= 500) ||
      error.toString().contains('SocketException') ||
      error.toString().contains('ClientException') ||
      error.toString().contains('Connection closed');

  static List<Entry> applyOfflineOperationProjection({
    required Iterable<Map<String, Object?>> rows,
    required List<Entry> entries,
    required CalcConfig calcConfig,
  }) => projectOfflineMonitorOperations(
    rows: rows,
    entries: entries,
    calcConfig: calcConfig,
  );

  /// 在场人员按危险等级排序（超时 > 告警 > 注意 > 安全），同级按 `exitAt` 升序。
  List<Entry> sortedActiveEntries({int? nowMs}) {
    final active = _entries.where((e) => e.isActive).toList()
      ..sort((a, b) {
        final sa = severityOf(statusOf(a, _calcConfig, nowMs: nowMs));
        final sb = severityOf(statusOf(b, _calcConfig, nowMs: nowMs));
        return sa != sb ? sa.compareTo(sb) : a.exitAt.compareTo(b.exitAt);
      });
    return active;
  }

  List<Entry> get activeEntries => sortedActiveEntries(nowMs: _nowMs());

  List<Entry> dangerEntries({int? nowMs}) {
    final ts = nowMs ?? _nowMs();
    return sortedActiveEntries(nowMs: ts)
        .where((e) => statusOf(e, _calcConfig, nowMs: ts) != 'normal')
        .toList();
  }

  MonitorRiskSummary riskSummary({int? nowMs}) => computeMonitorRiskSummary(
    entries: _entries,
    calcConfig: _calcConfig,
    nowMs: nowMs ?? _nowMs(),
  );

  Entry? findById(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  void setEntries(List<Entry> value, {bool notify = true}) {
    if (_disposed) return;
    _entries = List<Entry>.of(value);
    if (notify) _notify();
  }

  void upsertEntry(Entry entry, {bool notify = true}) {
    if (_disposed) return;
    final idx = _entries.indexWhere((e) => e.id == entry.id);
    _entries = idx >= 0
        ? [for (var i = 0; i < _entries.length; i++) i == idx ? entry : _entries[i]]
        : [entry, ..._entries];
    if (notify) _notify();
  }

  void setCalcConfig(CalcConfig value, {bool notify = true}) {
    if (_disposed) return;
    _calcConfig = value;
    if (notify) _notify();
  }

  void clear({bool notify = true}) {
    if (_disposed) return;
    _entries = <Entry>[];
    if (notify) _notify();
  }

  void applyPendingOfflineRows(
    Iterable<Map<String, Object?>> rows, {
    bool notify = true,
  }) {
    if (_disposed) return;
    _entries = applyOfflineOperationProjection(
      rows: rows,
      entries: _entries,
      calcConfig: _calcConfig,
    );
    if (notify) _notify();
  }

  /// 创建进场记录：断网自动写入离线队列并立即本地投影。
  Future<Entry> createEntryFromVoice({
    required String name,
    required double pressureMpa,
    String? rawText,
    bool force = false,
    double? volumeL,
    String? opId,
  }) async {
    final incidentId = _incidentIdProvider?.call();
    if (incidentId == null || incidentId.isEmpty) {
      throw StateError('请先选择或新建警情');
    }
    final operationRepo = _repositoryProvider?.call();
    final owner = await _buildOwner();
    Entry created;
    try {
      if (operationRepo == null) throw StateError('监控仓储尚未就绪');
      created = await operationRepo.createEntry(
        name: name,
        pressureMpa: pressureMpa,
        source: 'voice',
        rawText: rawText,
        force: force,
        volumeL: volumeL,
        consumptionLpm: _calcConfig.consumptionLpm,
        opId: opId,
      );
    } catch (error) {
      if (!isNetworkError(error)) rethrow;
      final at = _nowMs();
      final id = 'offline-entry-${DateTime.now().microsecondsSinceEpoch}';
      final vol = volumeL ?? _calcConfig.cylinderVolL;
      final dur = _calcConfig
          .durationMinFor(pressureMpa, cylinderVolL: vol)
          .round();
      await _enqueueOffline(
        owner: owner,
        incidentId: incidentId,
        type: 'entry',
        occurredAt: at,
        clientOpId: opId ?? id,
        payload: <String, dynamic>{
          'entry_id': id,
          'name': name,
          'pressure_mpa': pressureMpa,
          'volume_l': vol,
          'consumption_lpm': _calcConfig.consumptionLpm,
          'raw_text': rawText,
        },
      );
      created = Entry(
        id: id,
        name: name,
        pressureMpa: pressureMpa,
        durationMin: dur,
        entryAt: at,
        exitAt: at + dur * 60000,
        source: 'offline',
        rawText: rawText,
        cylinderVolL: vol,
        consumptionLpm: _calcConfig.consumptionLpm,
      );
    }

    if (!_sameRepository(operationRepo)) return created;
    _entries = [created, ..._entries.where((x) => x.id != created.id)];
    _notify();
    await _onSync?.call();
    return created;
  }

  /// 合并同名在场记录：按本次压力重新倒计时，不重复计数。
  Future<Entry> mergeEntryPressure({
    required String id,
    required double pressureMpa,
    String? opId,
    int? expectedVersion,
  }) async {
    if (!_entries.any((entry) => entry.id == id)) await _onSync?.call();
    final updated = await updatePressure(
      id: id,
      pressureMpa: pressureMpa,
      opId: opId,
      expectedVersion: expectedVersion,
    );
    await _onSync?.call();
    return updated;
  }

  /// 提交气瓶压力读数：冲突类错误触发同步并重抛，断网自动入离线队列并投影。
  Future<Entry> updatePressure({
    required String id,
    required double pressureMpa,
    String? opId,
    int? expectedVersion,
    bool recordNote = false,
  }) async {
    final op = opId ?? '';
    OpLogService.instance.record(
      op,
      'pressure_report',
      '更新压力 ${pressureMpa}MPa',
      data: <String, dynamic>{'entryId': id},
    );
    final current = _entries.firstWhere((entry) => entry.id == id);
    final incidentId = _incidentIdProvider?.call();
    final operationRepo = _repositoryProvider?.call();
    final owner = await _buildOwner();
    Entry updated;
    try {
      if (operationRepo == null) throw StateError('监控仓储尚未就绪');
      updated = await operationRepo.updateEntry(
        id: id,
        expectedVersion: expectedVersion ?? current.version,
        pressureMpa: pressureMpa,
        consumptionLpm: _calcConfig.consumptionLpm,
        opId: op,
      );
    } catch (error) {
      if (isConflictError(error)) {
        await _onSync?.call();
        rethrow;
      }
      if (!isNetworkError(error) || incidentId == null || incidentId.isEmpty) {
        rethrow;
      }
      final occurredAt = _nowMs();
      final vol = current.cylinderVolL ?? _calcConfig.cylinderVolL;
      final cons = current.consumptionLpm ?? _calcConfig.consumptionLpm;
      await _enqueueOffline(
        owner: owner,
        incidentId: incidentId,
        type: 'pressure',
        occurredAt: occurredAt,
        clientOpId: op.isEmpty
            ? 'offline-pressure-${DateTime.now().microsecondsSinceEpoch}'
            : op,
        payload: <String, dynamic>{
          'entry_id': id,
          'expected_version': expectedVersion ?? current.version,
          'name': current.name,
          'pressure_mpa': pressureMpa,
          'volume_l': vol,
          'consumption_lpm': cons,
        },
      );
      final dur = _calcConfig
          .durationMinFor(pressureMpa, cylinderVolL: vol, consumptionLpm: cons)
          .round();
      updated = current.copyWith(
        pressureMpa: pressureMpa,
        durationMin: dur,
        exitAt: occurredAt + dur * 60000,
        cylinderVolL: vol,
        consumptionLpm: cons,
      );
    }

    if (!_sameRepository(operationRepo)) return updated;
    _entries = [for (final entry in _entries) entry.id == id ? updated : entry];
    _notify();
    await _onSync?.call();

    if (recordNote && _onAddNote != null) {
      try {
        await _onAddNote(
          '${current.name} 更新气瓶压力为 ${formatPressure(pressureMpa)} MPa',
          category: 'entry',
        );
      } catch (logErr) {
        AppLogger.error('MonitorStore pressure note failed', tag: 'monitor', error: logErr);
      }
    }
    return updated;
  }

  /// 登记人员出火场：冲突类错误触发同步并重抛，断网自动入离线队列并投影。
  Future<void> markExited(
    String id, {
    String? opId,
    int? expectedVersion,
  }) async {
    final current = _entries.firstWhere((e) => e.id == id);
    final incidentId = _incidentIdProvider?.call();
    final operationRepo = _repositoryProvider?.call();
    final owner = await _buildOwner();
    try {
      if (operationRepo == null) throw StateError('监控仓储尚未就绪');
      await operationRepo.markExited(id, opId: opId, expectedVersion: expectedVersion ?? current.version);
      if (_sameRepository(operationRepo)) {
        final exitedAt = _nowMs();
        _entries = [for (final e in _entries) e.id == id ? e.copyWith(exitedAt: exitedAt) : e];
        _notify();
      }
    } catch (error) {
      if (isConflictError(error)) {
        await _onSync?.call();
        rethrow;
      }
      if (!isNetworkError(error) || incidentId == null || incidentId.isEmpty) rethrow;
      final exitedAt = _nowMs();
      await _enqueueOffline(
        owner: owner,
        incidentId: incidentId,
        type: 'exit',
        occurredAt: exitedAt,
        clientOpId: opId ?? 'offline-exit-${DateTime.now().microsecondsSinceEpoch}',
        payload: <String, dynamic>{
          'entry_id': id,
          'expected_version': expectedVersion ?? current.version,
          'name': current.name,
        },
      );
      if (!_sameRepository(operationRepo)) return;
      _entries = [for (final e in _entries) e.id == id ? e.copyWith(exitedAt: exitedAt) : e];
      _notify();
    }
    await _onSync?.call();
  }

  Future<void> recordExitActionLog(Entry entry, {String? opId}) async {
    final hook = _onAddActionLog;
    if (hook == null) return;
    await hook(
      names: <String>[entry.name],
      action: '出场',
      category: 'withdraw',
      opId: opId ?? 'manual-exit-note-${entry.id}-${_nowMs()}',
    );
  }

  void speak(String text) => _onSpeak?.call(text);

  Future<Map<String, String>> _buildOwner() async => <String, String>{
    'unit_id': _unitIdProvider?.call() ?? '',
    'member_id': _memberIdProvider != null
        ? await _memberIdProvider()
        : await Settings.memberId,
  };

  Future<void> _enqueueOffline({
    required Map<String, String> owner,
    required String incidentId,
    required String type,
    required int occurredAt,
    required String clientOpId,
    required Map<String, dynamic> payload,
  }) => _offlineEnqueuer != null
      ? _offlineEnqueuer(
          incidentId: incidentId,
          type: type,
          occurredAt: occurredAt,
          clientOpId: clientOpId,
          payload: payload,
          owner: owner,
        )
      : OfflineQueue.instance.enqueue(
          owner: owner,
          incidentId: incidentId,
          type: type,
          occurredAt: occurredAt,
          clientOpId: clientOpId,
          payload: payload,
        );

  bool _sameRepository(MonitorRepository? operationRepo) =>
      identical(_repositoryProvider?.call(), operationRepo);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
