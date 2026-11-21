import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/network/network.dart';
import '../../core/sync/sync_store.dart';
import '../../features/monitor/data/models/calc_config.dart';
import '../../features/monitor/data/models/entry.dart';
import '../../features/notes/data/models/note.dart';
import '../../features/notes/data/models/note_category.dart';
import '../../services/sync_reducer.dart';

/// HTTP 传输层工厂：支持在测试中替换底层 `http.Client` 或拦截传输。
typedef ApiTransportFactory = ApiHttpTransport Function(ApiConfig config);

/// 默认 HTTP 传输层工厂。
ApiHttpTransport defaultApiTransportFactory(ApiConfig config) =>
    ApiHttpTransport(config);

/// 实时同步协调器抽象接口。
///
/// 由外层装配（如 `AppController` / `AppScope`）将冻结的 `SyncCoordinator`
/// 适配到此接口，确保编排层不反向依赖旧 `api/api_client.dart`，同时允许单元测试
/// 注入轻量级替身验证快照与事件分发。
abstract class IncidentSyncDriver {
  bool get running;

  Future<void> start({String? incidentId});

  Future<void> switchIncident(String? incidentId);

  Future<void> checkpointNow({bool force = false});

  Future<void> stop();
}

/// 实时同步驱动工厂签名。
typedef IncidentSyncDriverFactory =
    IncidentSyncDriver Function({
      required ApiConfig config,
      required void Function(Map<String, dynamic> snapshot) onSnapshot,
      required void Function(SyncEvent event) onEvent,
      required void Function(SyncConnectionState state, Object? error) onState,
      required void Function(String staleIncidentId) onStaleIncident,
    });

/// 会话编排器向警情同步编排器下发控制的回调桥接（保持两大编排器文件间零环）。
class SessionSyncBridge {
  final VoidCallback? onStartSync;
  final VoidCallback? onRestartRealtimeSync;
  final Future<void> Function()? onStopSyncCoordinator;
  final Future<void> Function()? onCheckpointNow;
  final bool Function()? isCoordinatorRunning;
  final Future<void>? Function()? readRealtimeStartFuture;

  const SessionSyncBridge({
    this.onStartSync,
    this.onRestartRealtimeSync,
    this.onStopSyncCoordinator,
    this.onCheckpointNow,
    this.isCoordinatorRunning,
    this.readRealtimeStartFuture,
  });

  static const SessionSyncBridge empty = SessionSyncBridge();
}

/// 警情编排器依赖配置包（桥接会话编排器与外层可注入设施，保持文件间零环）。
class IncidentOrchestratorConfig {
  final int Function() readSessionGeneration;
  final int Function() bumpSessionGeneration;
  final ApiHttpTransport? Function() readTransport;
  final Future<void> Function() refreshConfig;
  final Future<void> Function({bool force}) refreshSession;
  final Future<void> Function() ensureSessionReady;
  final Future<void> Function() invalidateAuthenticationOnce;
  final Future<void> Function()? refreshAdminCapability;
  final Future<void> Function()? refreshPendingMembers;
  final bool Function()? readAppInForeground;
  final IncidentSyncDriverFactory? syncDriverFactory;
  final ApiTransportFactory transportFactory;
  final IncidentDomainHooks domainHooks;
  final OfflineQueueDrainerCallback? offlineQueueDrainer;
  final OfflinePendingRowsProvider? offlinePendingRowsProvider;
  final bool Function()? isAssistantBusy;
  final void Function({required bool inForeground, required bool syncConnected})?
  reportLifecycle;
  final int Function() nowMs;

  const IncidentOrchestratorConfig({
    required this.readSessionGeneration,
    required this.bumpSessionGeneration,
    required this.readTransport,
    required this.refreshConfig,
    required this.refreshSession,
    required this.ensureSessionReady,
    required this.invalidateAuthenticationOnce,
    this.refreshAdminCapability,
    this.refreshPendingMembers,
    this.readAppInForeground,
    this.syncDriverFactory,
    this.transportFactory = defaultApiTransportFactory,
    this.domainHooks = IncidentDomainHooks.empty,
    this.offlineQueueDrainer,
    this.offlinePendingRowsProvider,
    this.isAssistantBusy,
    this.reportLifecycle,
    this.nowMs = defaultNowMs,
  });

  static int defaultNowMs() => DateTime.now().millisecondsSinceEpoch;
}

/// 并发单飞合并器：同一时间只执行一次 [run]，并在完成后仅清理当前句柄。
Future<void> coalesceAsyncOp(
  Future<void>? Function() readSlot,
  void Function(Future<void>?) writeSlot,
  Future<void> Function() run,
) {
  final existing = readSlot();
  if (existing != null) return existing;
  final future = run();
  writeSlot(future);
  future.then<void>(
    (_) {
      if (identical(readSlot(), future)) writeSlot(null);
    },
    onError: (Object _, StackTrace __) {
      if (identical(readSlot(), future)) writeSlot(null);
    },
  );
  return future;
}

/// 离线队列排空回调：返回排空后待人工核对的操作条数。
typedef OfflineQueueDrainerCallback =
    Future<int> Function(ApiConfig config, Set<String> allowedIncidentIds);

/// 读取某一警情尚未补传的本地离线操作行。
typedef OfflinePendingRowsProvider =
    Future<List<Map<String, Object?>>> Function(String incidentId);

/// 跨警情域插槽集合：预留给 M3a `MonitorStore` / `AlertClockStore`、
/// M3c `NotesStore` 与过渡期 `AppController` 门面无侵入接入。
class IncidentDomainHooks {
  final VoidCallback? onClearIncidentDomainData;
  final void Function({
    required List<Entry> entries,
    required List<Note> notes,
  })?
  onApplySnapshotDomainData;
  final void Function(Entry entry)? onEntryEvent;
  final void Function(Note note)? onNoteUpserted;
  final void Function(String noteId)? onNoteDeleted;
  final List<Entry> Function()? readEntries;
  final List<Note> Function()? readNotes;
  final CalcConfig Function()? readCalcConfig;
  final Future<void> Function()? onRescheduleNotifications;
  final Future<void> Function()? onClearScheduledNotifications;
  final VoidCallback? onResetAlertSession;
  final Future<void> Function()? onSyncKeepAlive;
  final Future<void> Function()? onStopKeepAlive;
  final void Function({
    required int activeCount,
    required int earliestExitAt,
    required bool mainInForeground,
    required bool mainSyncConnected,
  })?
  onReportMainSnapshot;
  final Future<void> Function({bool force})? onEnsureOptionalServices;
  final VoidCallback? onRestartTickTimer;
  final VoidCallback? onStopTickTimer;
  final Future<void> Function()? onApplyDevicePreferences;
  final Future<void> Function(ApiConfig config)? onFlushOpLogs;
  final Future<void> Function(ApiConfig config)? onFlushDiagnosticLogs;
  final Future<void> Function()? onFlushLocalOpLogs;

  const IncidentDomainHooks({
    this.onClearIncidentDomainData,
    this.onApplySnapshotDomainData,
    this.onEntryEvent,
    this.onNoteUpserted,
    this.onNoteDeleted,
    this.readEntries,
    this.readNotes,
    this.readCalcConfig,
    this.onRescheduleNotifications,
    this.onClearScheduledNotifications,
    this.onResetAlertSession,
    this.onSyncKeepAlive,
    this.onStopKeepAlive,
    this.onReportMainSnapshot,
    this.onEnsureOptionalServices,
    this.onRestartTickTimer,
    this.onStopTickTimer,
    this.onApplyDevicePreferences,
    this.onFlushOpLogs,
    this.onFlushDiagnosticLogs,
    this.onFlushLocalOpLogs,
  });

  static const IncidentDomainHooks empty = IncidentDomainHooks();
}

/// 将仍在本地待补传的业务操作按发生顺序叠加到服务端快照。
///
/// 返回新列表且不修改传入集合，保持与原 `AppController.applyOfflineOperationProjection`
/// 100% 一致的离线投影语义，便于 M3a `MonitorStore` 与 M3c `NotesStore` 直接复用。
(List<Entry>, List<Note>) projectOfflineOperations({
  required Iterable<Map<String, Object?>> rows,
  required List<Entry> entries,
  required List<Note> notes,
  required CalcConfig calcConfig,
  required String author,
}) {
  var projectedEntries = List<Entry>.of(entries);
  var projectedNotes = List<Note>.of(notes);
  for (final row in rows) {
    try {
      final rawPayload = row['payload'];
      if (rawPayload is! String) continue;
      final decoded = jsonDecode(rawPayload);
      if (decoded is! Map) continue;
      final payload = Map<String, dynamic>.from(decoded);
      final type = row['type']?.toString();
      final occurredAt = (row['occurred_at'] as num?)?.toInt() ?? 0;
      if (occurredAt <= 0) continue;
      switch (type) {
        case 'entry':
          final id = payload['entry_id']?.toString();
          final name = payload['name']?.toString();
          final pressure = _offlineNumber(payload['pressure_mpa']);
          if (id == null || id.isEmpty || name == null || name.isEmpty) {
            continue;
          }
          if (pressure == null || pressure <= 0) continue;
          final volume =
              _offlineNumber(payload['volume_l']) ?? calcConfig.cylinderVolL;
          final consumption =
              _offlineNumber(payload['consumption_lpm']) ??
              calcConfig.consumptionLpm;
          final duration = calcConfig
              .durationMinFor(
                pressure,
                cylinderVolL: volume,
                consumptionLpm: consumption,
              )
              .round();
          final entry = Entry(
            id: id,
            name: name,
            pressureMpa: pressure,
            durationMin: duration,
            entryAt: occurredAt,
            exitAt: occurredAt + duration * 60000,
            source: 'offline',
            rawText: payload['raw_text']?.toString(),
            cylinderVolL: volume,
            consumptionLpm: consumption,
          );
          projectedEntries = [
            entry,
            ...projectedEntries.where((item) => item.id != id),
          ];
        case 'pressure':
          final id = payload['entry_id']?.toString();
          final pressure = _offlineNumber(payload['pressure_mpa']);
          if (id == null || id.isEmpty || pressure == null || pressure <= 0) {
            continue;
          }
          final index = projectedEntries.indexWhere((item) => item.id == id);
          if (index < 0) continue;
          final current = projectedEntries[index];
          final volume =
              _offlineNumber(payload['volume_l']) ??
              current.cylinderVolL ??
              calcConfig.cylinderVolL;
          final consumption =
              _offlineNumber(payload['consumption_lpm']) ??
              current.consumptionLpm ??
              calcConfig.consumptionLpm;
          final duration = calcConfig
              .durationMinFor(
                pressure,
                cylinderVolL: volume,
                consumptionLpm: consumption,
              )
              .round();
          projectedEntries = [
            for (final item in projectedEntries)
              item.id == id
                  ? item.copyWith(
                      pressureMpa: pressure,
                      durationMin: duration,
                      exitAt: occurredAt + duration * 60000,
                      cylinderVolL: volume,
                      consumptionLpm: consumption,
                    )
                  : item,
          ];
        case 'exit':
          final id = payload['entry_id']?.toString();
          if (id == null || id.isEmpty) continue;
          projectedEntries = [
            for (final item in projectedEntries)
              item.id == id ? item.copyWith(exitedAt: occurredAt) : item,
          ];
        case 'note':
          final id = payload['note_id']?.toString();
          final text = payload['text']?.toString();
          if (id == null || id.isEmpty || text == null || text.isEmpty) {
            continue;
          }
          projectedNotes = [
            Note(
              id: id,
              text: text,
              category: payload['category']?.toString() ?? NoteCategory.other,
              author: author,
              createdAt: occurredAt,
              updatedAt: occurredAt,
            ),
            ...projectedNotes.where((item) => item.id != id),
          ];
      }
    } catch (_) {
      // 单条损坏的本地记录不能阻塞其他合法操作的恢复。
    }
  }
  return (projectedEntries, projectedNotes);
}

double? _offlineNumber(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}
