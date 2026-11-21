import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/network/network.dart';
import '../../core/sync/sync_store.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/auth/state/session_store.dart';
import '../../features/incident/data/incident_repository.dart';
import '../../features/incident/state/incident_store.dart';
import '../../features/monitor/data/models/calc_config.dart';
import '../../features/monitor/data/models/entry.dart';
import '../../features/monitor/data/monitor_repository.dart';
import '../../features/notes/data/models/note.dart';
import '../../features/notes/data/notes_repository.dart';
import '../../features/roster/data/roster_repository.dart';
import '../../features/roster/state/roster_store.dart';
import '../../services/foreground_keep_alive.dart';
import '../../services/offline_queue.dart';
import '../../services/op_log_service.dart';
import '../../services/scoped_json_cache.dart';
import '../../services/settings.dart';
import '../../services/sync_reducer.dart';
import 'orchestrator_contracts.dart';

/// 将当前在场人员摘要上报给后台值守服务。
void reportMainSnapshotToKeepAlive({
  required IncidentDomainHooks domainHooks,
  required bool inForeground,
  required bool syncConnected,
}) {
  final entries = domainHooks.readEntries?.call() ?? const <Entry>[];
  final activeEntries = entries.where((entry) => entry.isActive).toList()
    ..sort((a, b) => a.exitAt.compareTo(b.exitAt));
  final activeCount = activeEntries.length;
  final earliestExitAt = activeEntries.isEmpty ? 0 : activeEntries.first.exitAt;
  final customReporter = domainHooks.onReportMainSnapshot;
  if (customReporter != null) {
    customReporter(
      activeCount: activeCount,
      earliestExitAt: earliestExitAt,
      mainInForeground: inForeground,
      mainSyncConnected: syncConnected,
    );
    return;
  }
  ForegroundKeepAlive.reportMainSnapshot(
    activeCount: activeCount,
    earliestExitAt: earliestExitAt,
    mainInForeground: inForeground,
    mainSyncConnected: syncConnected,
  );
}

/// 处理实时同步连接状态变更：鉴权失效时触发吊销，否则更新同步健康度与保活生命周期。
void dispatchSyncConnectionState({
  required SyncConnectionState state,
  required Object? error,
  required bool coordinatorRunning,
  required bool inForeground,
  required SyncStore syncStore,
  required IncidentDomainHooks domainHooks,
  required Future<void> Function() onInvalidateAuthentication,
  void Function({required bool inForeground, required bool syncConnected})?
  reportLifecycle,
}) {
  if (error != null && isApiAuthenticationFailure(error)) {
    unawaited(onInvalidateAuthentication());
    return;
  }
  final shouldLog = syncStore.applyConnectionState(
    state,
    error: error,
    coordinatorRunning: coordinatorRunning,
    notify: true,
  );
  if (shouldLog) {
    OpLogService.instance.record('realtime-sync', 'sync_retry', '$error', level: 'warn');
    debugPrint('WatchDog realtime sync retry: $error');
  }
  (reportLifecycle ?? ForegroundKeepAlive.reportMainLifecycle)(
    inForeground: inForeground,
    syncConnected: syncStore.isSyncConnected,
  );
  if (state == SyncConnectionState.connected) {
    reportMainSnapshotToKeepAlive(
      domainHooks: domainHooks,
      inForeground: inForeground,
      syncConnected: true,
    );
  }
}

/// 将实时同步全量快照分发到各域 Store 与 M3a/M3c 域插槽，避免单次快照引发重复根重建。
void dispatchSyncSnapshot({
  required Map<String, dynamic> snapshot,
  required ApiConfig? activeConfig,
  required SessionStore sessionStore,
  required SyncStore syncStore,
  required IncidentStore incidentStore,
  required RosterStore rosterStore,
  required IncidentDomainHooks domainHooks,
  required bool inForeground,
  Future<void> Function()? onRefreshPendingMembers,
}) {
  syncStore.setSyncSnapshotApplied(true, notify: false);
  unawaited(onRefreshPendingMembers?.call());

  final roster = snapshot['roster'] is Map
      ? Map<String, dynamic>.from(snapshot['roster'] as Map)
      : <String, dynamic>{};
  final unitId = (snapshot['unit'] as Map?)?['id']?.toString();
  final cacheScope = activeConfig?.cacheScope ?? '';
  rosterStore.applySnapshot(
    roster: roster,
    stations: snapshot.containsKey('stations') ? snapshot['stations'] : null,
    unitId: unitId,
    cacheScope: cacheScope,
    persistCache: unitId != null && unitId.isNotEmpty,
    syncHotwords: true,
    notify: true,
  );

  if (cacheScope.isNotEmpty && snapshot['unit_stations'] is List) {
    unawaited(
      ScopedJsonCache.write(
        cacheScope,
        'directory:active',
        snapshot['unit_stations'] as List,
      ),
    );
  }

  final incidentSnapshot = snapshot['incident_snapshot'];
  if (incidentSnapshot is Map) {
    final data = Map<String, dynamic>.from(incidentSnapshot);
    final details = data['incident_details'];
    if (cacheScope.isNotEmpty && details is Map) {
      unawaited(
        ScopedJsonCache.write(
          cacheScope,
          'details:${details['incident_id']}',
          details,
        ),
      );
    }
    final entries = (data['entries'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Entry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final notes = (data['notes'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Note.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    domainHooks.onApplySnapshotDomainData?.call(entries: entries, notes: notes);
  }

  final applyResult = incidentStore.applySyncSnapshot(snapshot, notify: true);
  if (applyResult.currentIncidentCleared) {
    domainHooks.onClearIncidentDomainData?.call();
  }
  sessionStore.setHasCurrentIncident(
    incidentStore.hasCurrentIncident,
    notify: false,
  );
  syncStore.recordSyncSuccess(snapshotApplied: true, notify: true);
  reportMainSnapshotToKeepAlive(
    domainHooks: domainHooks,
    inForeground: inForeground,
    syncConnected: syncStore.isSyncConnected,
  );
  unawaited(domainHooks.onRescheduleNotifications?.call());
}

/// 将单条实时增量同步事件分发至对应域 Store 或 M3a/M3c 域插槽。
void dispatchSyncEvent({
  required SyncEvent event,
  required ApiHttpTransport? activeTransport,
  required ApiConfig? activeConfig,
  required SessionStore sessionStore,
  required SyncStore syncStore,
  required IncidentStore incidentStore,
  required RosterStore rosterStore,
  required IncidentDomainHooks domainHooks,
  required bool inForeground,
  Future<void> Function()? onRefreshPendingMembers,
  Future<void> Function()? onRefreshAdminCapability,
  Future<void> Function(String incidentId)? onRefreshIncidentData,
}) {
  final payload = event.payload;
  final cacheScope = activeConfig?.cacheScope ?? '';
  switch (event.eventType) {
    case 'members.applications_changed':
      unawaited(onRefreshPendingMembers?.call());
    case 'admin.capability_changed':
      unawaited(onRefreshPendingMembers?.call());
      if (sessionStore.shouldRefreshAdminCapabilityForEvent(
        payload['memberId']?.toString(),
      )) {
        sessionStore.clearAdminCapability(notify: true);
        unawaited(onRefreshAdminCapability?.call());
      }
    case 'incident.created':
    case 'incident.updated':
    case 'incident.archived':
    case 'force.upserted':
    case 'force.deleted':
      final res = incidentStore.applySyncEvent(
        eventType: event.eventType,
        payload: payload,
        aggregateId: event.aggregateId,
        notify: true,
      );
      if (res.currentIncidentCleared) {
        domainHooks.onClearIncidentDomainData?.call();
        sessionStore.setHasCurrentIncident(false, notify: true);
      }
    case 'import.applied':
      if (cacheScope.isNotEmpty && payload['details'] is Map) {
        final details = payload['details'] as Map;
        unawaited(
          ScopedJsonCache.write(
            cacheScope,
            'details:${details['incident_id']}',
            details,
          ),
        );
      }
      incidentStore.applySyncEvent(
        eventType: event.eventType,
        payload: payload,
        aggregateId: event.aggregateId,
        notify: true,
      );
    case 'entry.created':
    case 'entry.pressure_updated':
    case 'entry.exited':
      if (payload.isNotEmpty) {
        domainHooks.onEntryEvent?.call(Entry.fromJson(payload));
      }
    case 'note.created':
    case 'note.updated':
      if (payload.isNotEmpty) {
        domainHooks.onNoteUpserted?.call(Note.fromJson(payload));
      }
    case 'note.deleted':
      final id = event.aggregateId ?? payload['id']?.toString();
      if (id != null) domainHooks.onNoteDeleted?.call(id);
    case 'directory.updated':
      if (activeTransport != null) {
        unawaited(
          RosterRepository(activeTransport)
              .fetchUnitStations()
              .catchError((_) => <Map<String, dynamic>>[]),
        );
      }
    case 'details.updated':
      if (cacheScope.isNotEmpty && payload['incident_id'] != null) {
        unawaited(
          ScopedJsonCache.write(
            cacheScope,
            'details:${payload['incident_id']}',
            payload,
          ),
        );
      }
      final currentId = incidentStore.currentIncident?.id;
      if (currentId != null) unawaited(onRefreshIncidentData?.call(currentId));
    case 'roster.firefighter_added':
    case 'roster.firefighter_removed':
    case 'roster.hotword_added':
    case 'roster.hotword_removed':
    case 'roster.station_added':
    case 'roster.station_removed':
      rosterStore.applySyncEvent(
        event,
        unitId: activeConfig?.unitId ?? '',
        cacheScope: cacheScope,
        persistCache: true,
        syncHotwords: true,
        notify: true,
      );
  }
  syncStore.recordSyncSuccess(notify: true);
  reportMainSnapshotToKeepAlive(
    domainHooks: domainHooks,
    inForeground: inForeground,
    syncConnected: syncStore.isSyncConnected,
  );
  unawaited(domainHooks.onRescheduleNotifications?.call());
}

/// 离线队列未补传操作投影：从本地离线队列读取待补传操作并叠加到服务端快照。
Future<void> applyOfflineProjectionForIncident({
  required String incidentId,
  required List<Entry> entries,
  required List<Note> notes,
  required IncidentDomainHooks domainHooks,
  required OfflinePendingRowsProvider? pendingRowsProvider,
  required bool hasCustomDrainer,
}) async {
  if (incidentId.isEmpty) return;
  if (pendingRowsProvider == null && hasCustomDrainer) return;
  final rows = await (pendingRowsProvider ??
      OfflineQueue.instance.pendingOperations)(incidentId);
  if (rows.isEmpty) return;
  final author = await Settings.realName;
  final calcConfig =
      domainHooks.readCalcConfig?.call() ??
      CalcConfig(
        cylinderVolL: 6.8,
        fullPressureMpa: 30,
        consumptionLpm: 80,
        warnMin: 10,
        alarmMin: 5,
      );
  final projected = projectOfflineOperations(
    rows: rows,
    entries: entries,
    notes: notes,
    calcConfig: calcConfig,
    author: author,
  );
  domainHooks.onApplySnapshotDomainData?.call(
    entries: projected.$1,
    notes: projected.$2,
  );
}

/// 旧路径 HTTP 同步拉取（无运行中实时驱动时的兜底同步通道）。
Future<void> executeLegacySyncPull({
  required ApiHttpTransport transport,
  required ApiConfig config,
  required bool Function() isStillCurrent,
  required SessionStore sessionStore,
  required SyncStore syncStore,
  required IncidentStore incidentStore,
  required IncidentDomainHooks domainHooks,
  required bool Function() readAppInForeground,
  required Future<void> Function() onInvalidateAuthentication,
  OfflineQueueDrainerCallback? offlineQueueDrainer,
  OfflinePendingRowsProvider? offlinePendingRowsProvider,
}) async {
  final opToken = syncStore.beginLegacySync(notify: true);
  try {
    if (offlineQueueDrainer == null && (await Settings.memberId).isEmpty) {
      final identity = await AuthRepository(transport).fetchAuthIdentity();
      if (!isStillCurrent()) return;
      await Settings.setMemberId(identity['member_id']?.toString() ?? '');
    }
    final incidentRepo = IncidentRepository(transport);
    final fetchedActive = await incidentRepo.fetchIncidents(status: 'active');
    if (!isStillCurrent()) return;
    incidentStore.setActiveIncidents(fetchedActive, notify: false);
    final savedId = await Settings.currentIncidentId;
    final allowedIds = <String>{
      ...fetchedActive.map((item) => item.id),
      if (savedId.isNotEmpty) savedId,
    };
    if (offlineQueueDrainer != null) {
      final reviewCount = await offlineQueueDrainer(config, allowedIds);
      if (!isStillCurrent()) return;
      sessionStore.setOfflineReviewCount(reviewCount, notify: false);
    }
    if (!isStillCurrent()) return;
    if (savedId.isEmpty) {
      incidentStore.clearCurrentIncident(notify: false);
      domainHooks.onClearIncidentDomainData?.call();
      sessionStore.setHasCurrentIncident(false, notify: false);
    } else {
      final incident = await incidentRepo.fetchIncident(savedId);
      if (!isStillCurrent()) return;
      if (!incident.isActive) {
        incidentStore.clearCurrentIncident(notify: false);
        await Settings.setCurrentIncidentId('');
        domainHooks.onClearIncidentDomainData?.call();
        sessionStore.setHasCurrentIncident(false, notify: false);
      } else {
        final entries = await MonitorRepository(transport).fetchEntries();
        if (!isStillCurrent()) return;
        var notes = domainHooks.readNotes?.call() ?? const <Note>[];
        try {
          notes = await NotesRepository(transport).fetchNotes();
        } catch (_) {}
        var forces = incidentStore.forces;
        try {
          forces = await incidentRepo.fetchIncidentForces();
        } catch (_) {}
        if (!isStillCurrent()) return;
        incidentStore.applyIncidentAndForces(
          incident: incident,
          forces: forces,
          notify: false,
        );
        sessionStore.setHasCurrentIncident(true, notify: false);
        domainHooks.onApplySnapshotDomainData?.call(
          entries: entries,
          notes: notes,
        );
        try {
          await applyOfflineProjectionForIncident(
            incidentId: savedId,
            entries: entries,
            notes: notes,
            domainHooks: domainHooks,
            pendingRowsProvider: offlinePendingRowsProvider,
            hasCustomDrainer: offlineQueueDrainer != null,
          );
        } catch (error) {
          debugPrint('WatchDog offline projection failed: $error');
        }
      }
    }
    syncStore.recordSyncSuccess(notify: false);
    reportMainSnapshotToKeepAlive(
      domainHooks: domainHooks,
      inForeground: readAppInForeground(),
      syncConnected: syncStore.isSyncConnected,
    );
    await domainHooks.onRescheduleNotifications?.call();
    unawaited(domainHooks.onEnsureOptionalServices?.call());
  } catch (error) {
    if (!isStillCurrent()) return;
    if (error is ApiException && error.code == 'INCIDENT_NOT_FOUND') {
      await Settings.setCurrentIncidentId('');
      if (!isStillCurrent()) return;
      incidentStore.clearCurrentIncident(notify: false);
      domainHooks.onClearIncidentDomainData?.call();
      sessionStore.setHasCurrentIncident(false, notify: false);
      syncStore.recordLegacySyncFailure(clearFailureWindow: true);
      await domainHooks.onStopKeepAlive?.call();
      await domainHooks.onClearScheduledNotifications?.call();
      return;
    }
    if (error is ApiException &&
        const {
          'UNIT_INVALID',
          'UNIT_AUTH_REQUIRED',
          'SESSION_REQUIRED',
          'SESSION_INVALID',
          'SESSION_EXPIRED',
        }.contains(error.code)) {
      await onInvalidateAuthentication();
      return;
    }
    final shouldLog = syncStore.recordLegacySyncFailure(error: error);
    if (shouldLog) {
      OpLogService.instance.record('sync', 'sync_retry', '$error', level: 'warn');
    }
    debugPrint('WatchDog sync failed: $error');
  } finally {
    syncStore.endLegacySync(opToken, notify: true);
    incidentStore.setActiveIncidents(incidentStore.activeIncidents);
    sessionStore.notifyStateChanged();
  }
}
