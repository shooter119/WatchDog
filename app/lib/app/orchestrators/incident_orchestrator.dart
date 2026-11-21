import 'dart:async';

import '../../core/network/network.dart';
import '../../core/sync/sync_store.dart';
import '../../features/auth/state/session_store.dart';
import '../../features/incident/data/incident_repository.dart';
import '../../features/incident/data/models/external_incident.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/incident/state/incident_store.dart';
import '../../features/roster/state/roster_store.dart';
import '../../services/settings.dart';
import '../../services/sync_reducer.dart';
import 'incident_mutation_helper.dart';
import 'incident_sync_dispatcher.dart';
import 'orchestrator_contracts.dart';

/// 警情生命周期与实时同步分发编排器。
///
/// 统筹警情选择、新建、外部认领、归档、退出及实时同步协调器启停与快照/事件分发；
/// 所有跨警情切换均原子清空当前警情与人员/日志/力量域状态，杜绝串场污染。
class IncidentOrchestrator {
  final SessionStore sessionStore;
  final SyncStore syncStore;
  final IncidentStore incidentStore;
  final RosterStore rosterStore;
  final IncidentOrchestratorConfig _config;

  IncidentSyncDriver? _syncDriver;
  Future<void>? _realtimeStartFuture;
  Future<void>? _syncFuture;
  bool _disposed = false;

  IncidentOrchestrator({
    required this.sessionStore,
    required this.syncStore,
    required this.incidentStore,
    required this.rosterStore,
    required IncidentOrchestratorConfig config,
  }) : _config = config;

  bool get isDisposed => _disposed;
  bool get isSyncDriverRunning => _syncDriver?.running == true;
  Future<void>? get realtimeStartFuture => _realtimeStartFuture;
  IncidentDomainHooks get _hooks => _config.domainHooks;
  bool get _inForeground => _config.readAppInForeground?.call() ?? true;

  bool _isCurrentSession(ApiConfig? expectedConfig, int generation) =>
      !_disposed &&
      generation == _config.readSessionGeneration() &&
      identical(sessionStore.config, expectedConfig);

  void _syncContextToStore({bool notify = false}) {
    syncStore.updateSyncContext(
      authenticated: sessionStore.authenticated,
      isGuest: sessionStore.isGuest,
      coordinatorRunning: isSyncDriverRunning,
      realtimeStarting: _realtimeStartFuture != null,
      notify: notify,
    );
  }

  /// 原子切换当前警情上下文，防止跨警情串场污染并重建同步通道。
  Future<void> _commitIncidentTransition({
    required String incidentId,
    required Incident? nextIncident,
    required bool enteredWithoutIncident,
    required bool awaitSyncCompletion,
    bool backgroundSyncWhenKnown = false,
  }) async {
    await Settings.setCurrentIncidentId(incidentId);
    _config.bumpSessionGeneration();
    _syncFuture = null;
    sessionStore.setEnteredWithoutIncident(enteredWithoutIncident, notify: false);
    sessionStore.setHasCurrentIncident(nextIncident != null, notify: false);
    _hooks.onClearIncidentDomainData?.call();
    if (nextIncident != null) {
      incidentStore.selectLocalIncident(
        nextIncident,
        clearForces: true,
        notify: false,
      );
    } else {
      incidentStore.clearCurrentIncident(notify: false);
    }
    unawaited(_hooks.onClearScheduledNotifications?.call());
    _hooks.onResetAlertSession?.call();
    syncStore.resetSessionHealth(notify: false);
    _syncContextToStore(notify: true);
    incidentStore.setCurrentIncident(incidentStore.currentIncident);
    sessionStore.notifyStateChanged();

    await _config.refreshConfig();
    if (_disposed) return;
    unawaited(_hooks.onSyncKeepAlive?.call());

    if (backgroundSyncWhenKnown) {
      if (!syncStore.syncStarted) {
        if (sessionStore.authenticated) {
          startSync();
        } else {
          unawaited(sync());
        }
      }
      return;
    }

    if (sessionStore.authenticated) {
      if (!syncStore.syncStarted) startSync();
      if (awaitSyncCompletion) {
        await (_realtimeStartFuture ?? Future<void>.value());
      }
    } else if (!syncStore.syncStarted) {
      await sync();
    }
  }

  Future<void> selectIncident(String id, {Incident? knownIncident}) async {
    await _config.refreshSession();
    if (sessionStore.needsAuthentication) {
      throw StateError('认证会话已过期，请重新认证');
    }
    await _commitIncidentTransition(
      incidentId: id,
      nextIncident: knownIncident,
      enteredWithoutIncident: false,
      awaitSyncCompletion: knownIncident == null,
      backgroundSyncWhenKnown: knownIncident != null,
    );
  }

  Future<Incident> createIncident() => _createOrClaimIncident(
    opPrefix: 'incident-create',
    failStage: 'incident_create_fail',
    failLabel: '新建警情失败',
    write: (repo, name, opId) => repo.createIncident(realName: name, opId: opId),
  );

  Future<Incident> claimExternalIncident(ExternalIncident externalIncident) =>
      _createOrClaimIncident(
        opPrefix: 'incident-claim',
        failStage: 'incident_claim_fail',
        failLabel: '认领警情失败',
        write: (repo, name, opId) => repo.claimExternalIncident(
          externalIncident,
          realName: name,
          opId: opId,
        ),
      );

  Future<Incident> _createOrClaimIncident({
    required String opPrefix,
    required String failStage,
    required String failLabel,
    required Future<Incident> Function(
      IncidentRepository repo,
      String actorName,
      String opId,
    )
    write,
  }) async {
    final name = await requireAuthenticatedActor(
      sessionStore: sessionStore,
      ensureSessionReady: _config.ensureSessionReady,
      refreshSession: _config.refreshSession,
    );
    final opId = '$opPrefix-${_config.nowMs()}';
    final incident = await runIncidentWriteWithFallback(
      existingTransport: _config.readTransport(),
      transportFactory: _config.transportFactory,
      actorName: name,
      opId: opId,
      failStage: failStage,
      failLabel: failLabel,
      onInvalidateAuthentication: _config.invalidateAuthenticationOnce,
      action: (repo) => write(repo, name, opId),
    );
    await _commitIncidentTransition(
      incidentId: incident.id,
      nextIncident: incident,
      enteredWithoutIncident: false,
      awaitSyncCompletion: false,
    );
    return incident;
  }

  Future<void> archiveCurrent() async {
    final transport = _config.readTransport();
    final current = incidentStore.currentIncident;
    if (transport == null || current == null) throw StateError('未选择警情');
    await IncidentRepository(transport).archiveIncident(current.id);
    incidentStore.setActiveIncidents(
      incidentStore.activeIncidents
          .where((item) => item.id != current.id)
          .toList(),
      notify: false,
    );
    await _commitIncidentTransition(
      incidentId: '',
      nextIncident: null,
      enteredWithoutIncident: true,
      awaitSyncCompletion: false,
    );
  }

  /// 退出当前警情只清除本机选择，不归档服务器档案；之后仍可从活跃列表重新加入。
  Future<void> exitCurrentIncident() async {
    if (incidentStore.currentIncident == null) return;
    await _commitIncidentTransition(
      incidentId: '',
      nextIncident: null,
      enteredWithoutIncident: true,
      awaitSyncCompletion: false,
    );
  }

  Future<Incident> renameCurrent(String title) async {
    final incident = incidentStore.currentIncident;
    final transport = _config.readTransport();
    if (incident == null || transport == null) throw StateError('未选择警情');
    final updated = await IncidentRepository(transport).updateIncidentTitle(
      incident.id,
      title.trim().isEmpty ? null : title.trim(),
      expectedVersion: incident.version,
    );
    incidentStore.applyUpdatedIncident(updated);
    return updated;
  }

  bool Function() _sessionGuard() {
    final activeConfig = sessionStore.config;
    final generation = _config.readSessionGeneration();
    return () => _isCurrentSession(activeConfig, generation);
  }

  Future<void> refreshIncidentData(String id) => refreshIncidentAndForces(
    incidentId: id,
    transport: _config.readTransport(),
    incidentStore: incidentStore,
    isStillCurrent: _sessionGuard(),
  );

  Future<void> updateIncidentLevel(String level, {String? disasterCategory}) =>
      updateIncidentLevelAndReload(
        level: level,
        disasterCategory: disasterCategory,
        transport: _config.readTransport(),
        activeConfig: sessionStore.config,
        transportFactory: _config.transportFactory,
        incidentStore: incidentStore,
        nowMs: _config.nowMs(),
        isStillCurrent: _sessionGuard(),
      );

  Future<void> saveForce({
    String? forceId,
    required String stationName,
    String? stationId,
    required int vehicleCount,
    required int personnelCount,
    int? expectedVersion,
  }) => saveIncidentForceAndReload(
    transport: _config.readTransport(),
    incidentStore: incidentStore,
    isStillCurrent: _sessionGuard(),
    forceId: forceId,
    stationName: stationName,
    stationId: stationId,
    vehicleCount: vehicleCount,
    personnelCount: personnelCount,
    expectedVersion: expectedVersion,
  );

  Future<void> removeForce(String forceId) => removeIncidentForceAndReload(
    forceId: forceId,
    transport: _config.readTransport(),
    incidentStore: incidentStore,
    isStillCurrent: _sessionGuard(),
  );

  Future<void> fetchExternalIncidents({bool forceRefresh = false}) =>
      fetchExternalIncidentsWithGuard(
        forceRefresh: forceRefresh,
        sessionStore: sessionStore,
        incidentStore: incidentStore,
        config: _config,
        isNotDisposed: () => !_disposed,
      );

  Future<void> reorganizeExternalIncidents() =>
      reorganizeExternalIncidentsWithGuard(
        sessionStore: sessionStore,
        incidentStore: incidentStore,
        config: _config,
        isNotDisposed: () => !_disposed,
      );

  void startSync() {
    if (_disposed || sessionStore.needsAuthentication) return;
    if (syncStore.syncStarted) {
      unawaited(checkpointNow());
      return;
    }
    syncStore.setSyncStarted(true, notify: false);
    _hooks.onRestartTickTimer?.call();
    _trackRealtimeStart(_startRealtimeSync());
    syncStore.notifyStateChanged();
  }

  void restartRealtimeSync() {
    if (_disposed || !sessionStore.authenticated || !syncStore.syncStarted) {
      return;
    }
    _trackRealtimeStart(_startRealtimeSync());
  }

  Future<void> stopSyncDriver() async {
    final driver = _syncDriver;
    _syncDriver = null;
    _realtimeStartFuture = null;
    _syncFuture = null;
    if (driver != null) await driver.stop();
    _syncContextToStore(notify: false);
  }

  Future<void> checkpointNow({bool force = false}) =>
      _syncDriver?.checkpointNow(force: force) ?? Future<void>.value();

  void _trackRealtimeStart(Future<void> future) {
    _realtimeStartFuture = future;
    _syncContextToStore(notify: false);
    unawaited(
      future.whenComplete(() {
        if (!identical(_realtimeStartFuture, future)) return;
        _realtimeStartFuture = null;
        _syncContextToStore(notify: true);
      }),
    );
  }

  Future<void> _startRealtimeSync() async {
    final factory = _config.syncDriverFactory;
    final activeConfig = sessionStore.config;
    bool stillActive() =>
        !_disposed &&
        sessionStore.authenticated &&
        identical(sessionStore.config, activeConfig);
    if (!stillActive() || activeConfig == null || factory == null) return;
    final incidentId = await Settings.currentIncidentId;
    if (!stillActive()) return;
    final previous = _syncDriver;
    if (previous != null) {
      _syncDriver = null;
      await previous.stop();
    }
    if (!stillActive()) return;
    final driver = factory(
      config: activeConfig,
      onSnapshot: applySyncSnapshot,
      onEvent: applySyncEvent,
      onState: handleSyncState,
      onStaleIncident: handleStaleBootstrapIncident,
    );
    _syncDriver = driver;
    await driver.start(incidentId: incidentId.isEmpty ? null : incidentId);
    _syncContextToStore(notify: false);
  }

  void handleStaleBootstrapIncident(String staleIncidentId) {
    if (_disposed) return;
    if (incidentStore.clearCurrentIncidentIfMatches(staleIncidentId)) {
      _hooks.onClearIncidentDomainData?.call();
      sessionStore.setHasCurrentIncident(false, notify: true);
    }
    unawaited(Settings.setCurrentIncidentId(''));
  }

  void handleSyncState(SyncConnectionState state, Object? error) {
    if (_disposed) return;
    dispatchSyncConnectionState(
      state: state,
      error: error,
      coordinatorRunning: isSyncDriverRunning,
      inForeground: _inForeground,
      syncStore: syncStore,
      domainHooks: _hooks,
      onInvalidateAuthentication: _config.invalidateAuthenticationOnce,
      reportLifecycle: _config.reportLifecycle,
    );
  }

  void applySyncSnapshot(Map<String, dynamic> snapshot) {
    if (_disposed) return;
    dispatchSyncSnapshot(
      snapshot: snapshot, activeConfig: sessionStore.config,
      sessionStore: sessionStore, syncStore: syncStore,
      incidentStore: incidentStore, rosterStore: rosterStore,
      domainHooks: _hooks, inForeground: _inForeground,
      onRefreshPendingMembers: _config.refreshPendingMembers,
    );
  }

  void applySyncEvent(SyncEvent event) {
    if (_disposed) return;
    dispatchSyncEvent(
      event: event, activeTransport: _config.readTransport(),
      activeConfig: sessionStore.config, sessionStore: sessionStore,
      syncStore: syncStore, incidentStore: incidentStore,
      rosterStore: rosterStore, domainHooks: _hooks, inForeground: _inForeground,
      onRefreshPendingMembers: _config.refreshPendingMembers,
      onRefreshAdminCapability: _config.refreshAdminCapability,
      onRefreshIncidentData: refreshIncidentData,
    );
  }

  /// 手动下拉刷新：记录在途手动刷新令牌，强制执行一次同步校准。
  Future<void> refreshNow() async {
    unawaited(_hooks.onEnsureOptionalServices?.call(force: true));
    if (_disposed || sessionStore.isGuest) return;
    final opToken = syncStore.beginManualRefresh(notify: true);
    try {
      await sync(force: true);
    } finally {
      syncStore.endManualRefresh(opToken, notify: true);
    }
  }

  Future<void> sync({bool force = false}) {
    if (_disposed || (_config.isAssistantBusy?.call() ?? false) || _config.readTransport() == null) {
      return Future<void>.value();
    }
    final driver = _syncDriver;
    if (driver != null && driver.running) return driver.checkpointNow(force: force);
    final startFuture = _realtimeStartFuture;
    if (startFuture != null) {
      return startFuture.then((_) {
        if (identical(_realtimeStartFuture, startFuture)) _realtimeStartFuture = null;
        if (_disposed) return Future<void>.value();
        final started = _syncDriver;
        if (started != null && started.running) {
          return (force && !syncStore.isSyncConnected)
              ? started.checkpointNow(force: true)
              : Future<void>.value();
        }
        return sync(force: force);
      });
    }
    final transport = _config.readTransport()!;
    final config = sessionStore.config;
    if (config == null) return Future<void>.value();
    final generation = _config.readSessionGeneration();
    return coalesceAsyncOp(
      () => _syncFuture, (f) => _syncFuture = f,
      () => executeLegacySyncPull(
        transport: transport, config: config,
        isStillCurrent: () => _isCurrentSession(config, generation),
        sessionStore: sessionStore, syncStore: syncStore,
        incidentStore: incidentStore, domainHooks: _hooks,
        readAppInForeground: () => _inForeground,
        onInvalidateAuthentication: _config.invalidateAuthenticationOnce,
        offlineQueueDrainer: _config.offlineQueueDrainer,
        offlinePendingRowsProvider: _config.offlinePendingRowsProvider,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final driver = _syncDriver;
    _syncDriver = null;
    _realtimeStartFuture = null;
    _syncFuture = null;
    if (driver != null) unawaited(driver.stop());
  }
}
