import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/network/network.dart';
import '../../core/sync/sync_store.dart';
import '../../features/auth/state/session_store.dart';
import '../../features/incident/state/incident_store.dart';
import '../../features/roster/state/roster_store.dart';
import '../../features/settings/state/update_store.dart';
import '../../services/foreground_keep_alive.dart';
import '../../services/op_log_service.dart';
import '../../services/settings.dart';
import 'orchestrator_contracts.dart';
import 'session_auth_helper.dart';

/// 会话与生命周期跨域编排器。
///
/// 唯一持有 `_sessionGeneration` 递增权，统筹 `init`、`authenticate`、
/// `enterGuestMode`、`leaveUnit`、`invalidateAuthenticationOnce`（401 并发去重）、
/// 15 分钟会话续期定时器及前后台生命周期，协调 5 个独立 Store 而不引入任何 Store 间互调。
class SessionOrchestrator {
  static const Duration sessionRefreshCheckInterval = Duration(minutes: 15);
  static const Duration sessionRefreshLeadTime = Duration(hours: 1);
  static const Duration adminCapabilityCheckInterval = Duration(seconds: 30);

  final SessionStore sessionStore;
  final SyncStore syncStore;
  final IncidentStore incidentStore;
  final RosterStore rosterStore;
  final UpdateStore updateStore;
  final SessionOrchestratorConfig _config;

  ApiHttpTransport? _transport;
  Future<void>? _initFuture;
  Future<void>? _authenticateFuture;
  Future<void>? _refreshConfigFuture;
  Future<void>? _syncSettingsFuture;
  Future<void>? _sessionRefreshFuture;
  Future<void>? _authenticationInvalidationFuture;
  Timer? _sessionRefreshTimer;
  Timer? _adminCapabilityTimer;
  bool _refreshConfigAgain = false;
  bool _appInForeground = true;
  bool _disposed = false;
  int _sessionGeneration = 0;

  SessionOrchestrator({
    required this.sessionStore,
    required this.syncStore,
    required this.incidentStore,
    required this.rosterStore,
    required this.updateStore,
    SessionOrchestratorConfig config = const SessionOrchestratorConfig(),
  }) : _config = config;

  int get sessionGeneration => _sessionGeneration;
  bool get appInForeground => _appInForeground;
  bool get isDisposed => _disposed;
  ApiHttpTransport? get transport => _transport;
  ApiConfig? get activeConfig => sessionStore.config;
  SessionSyncBridge get _syncBridge => _config.syncBridge;
  IncidentDomainHooks get _hooks => _config.domainHooks;

  Future<String> _readDeviceId() =>
      (_config.deviceIdProvider ?? () => OpLogService.instance.deviceId)();

  void _reportLifecycle(bool inForeground) {
    final reporter =
        _config.reportLifecycle ?? ForegroundKeepAlive.reportMainLifecycle;
    reporter(
      inForeground: inForeground,
      syncConnected: syncStore.isSyncConnected,
    );
  }

  /// 唯一会话代际递增出口，供本编排器与 `IncidentOrchestrator` 在原子切场时调用。
  int bumpSessionGeneration() => ++_sessionGeneration;

  bool isCurrentSession(ApiConfig? expectedConfig, int generation) =>
      !_disposed &&
      generation == _sessionGeneration &&
      identical(sessionStore.config, expectedConfig);

  Future<void> init() {
    if (_initFuture != null) return _initFuture!;
    final future = _initInternal();
    _initFuture = future;
    future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        if (identical(_initFuture, future)) _initFuture = null;
      },
    );
    return future;
  }

  Future<void> _initInternal() async {
    if (_config.enableStartupMaintenance) triggerStartupMaintenance();
    await refreshConfig();
    if (_disposed) return;
    final authenticated = await hasStoredSessionCredentials();
    sessionStore.setAuthenticated(authenticated, notify: false);
    if (authenticated) {
      final expiresAt = await Settings.sessionExpiresAt;
      if (expiresAt > 0 && expiresAt <= _config.nowMs()) {
        await invalidateAuthenticationOnce();
      } else if (expiresAt <= 0) {
        try {
          await refreshSession(force: true);
        } on ApiException catch (error) {
          if (!isApiAuthenticationFailure(error)) rethrow;
        }
      }
    } else if (await Settings.isGuestMode) {
      sessionStore.setGuestMode(true, notify: false);
      incidentStore.initGuestIncident(notify: false);
      sessionStore.setHasCurrentIncident(true, notify: false);
      unawaited(_config.domainHooks.onEnsureOptionalServices?.call());
    }
    await rosterStore.ensureLocalRoster(
      authenticated: sessionStore.authenticated,
    );
    syncStore.updateSyncContext(
      authenticated: sessionStore.authenticated,
      isGuest: sessionStore.isGuest,
    );
    if (sessionStore.authenticated) {
      startAuthenticatedServices();
    } else {
      incidentStore.setCurrentIncident(incidentStore.currentIncident);
      sessionStore.notifyStateChanged();
    }
  }

  Future<void> ensureReady() async {
    if (_transport != null && sessionStore.config != null) return;
    if (_initFuture != null) await _initFuture;
    if ((_transport == null || sessionStore.config == null) && !_disposed) {
      await refreshConfig();
    }
  }

  void startAuthenticatedServices() {
    if (_disposed || !sessionStore.authenticated || syncStore.syncStarted) return;
    final config = sessionStore.config;
    if (config != null && config.cacheScope.isNotEmpty) {
      unawaited(
        incidentStore.restoreCachedExternalIncidents(
          cacheScope: config.cacheScope,
          protectedDataEpoch: () => sessionStore.protectedDataEpoch,
          sessionGeneration: () => _sessionGeneration,
          isStillCurrent: () =>
              !_disposed && !sessionStore.needsAuthentication && identical(sessionStore.config, config),
        ),
      );
    }
    _startSessionRefreshTimer();
    _adminCapabilityTimer?.cancel();
    _adminCapabilityTimer = Timer.periodic(_config.adminCapabilityInterval, (_) {
      if (!_appInForeground) return;
      unawaited(refreshAdminCapability());
      unawaited(refreshPendingMembers());
    });
    final prev = _syncBridge.readRealtimeStartFuture?.call();
    _syncBridge.onStartSync?.call();
    final next = _syncBridge.readRealtimeStartFuture?.call();
    if (next != null && !identical(next, prev)) {
      final gen = _sessionGeneration;
      unawaited(next.whenComplete(() => unawaited(_runPostBootstrapStartupTasks(gen))));
      unawaited(_hooks.onEnsureOptionalServices?.call());
      return;
    }
    unawaited(refreshAdminCapability());
    unawaited(loadRoster());
    unawaited(syncSettings());
    if (config != null) unawaited(_hooks.onFlushOpLogs?.call(config));
    unawaited(refreshPendingMembers());
    unawaited(_hooks.onEnsureOptionalServices?.call());
  }

  Future<void> _runPostBootstrapStartupTasks(int generation) async {
    if (_disposed || !sessionStore.authenticated || generation != _sessionGeneration) return;
    unawaited(refreshAdminCapability());
    if (!syncStore.syncSnapshotApplied) {
      unawaited(loadRoster());
      unawaited(refreshPendingMembers());
    }
    unawaited(syncSettings());
    final config = sessionStore.config;
    if (config == null) return;
    unawaited(_hooks.onFlushOpLogs?.call(config));
    final incidentId = incidentStore.currentIncident?.id ?? await Settings.currentIncidentId;
    if (!isCurrentSession(config, generation) || !sessionStore.authenticated) return;
    if (incidentId.isNotEmpty) unawaited(_hooks.onFlushDiagnosticLogs?.call(config));
  }

  void _startSessionRefreshTimer() {
    _sessionRefreshTimer?.cancel();
    if (_disposed || !sessionStore.authenticated) return;
    _sessionRefreshTimer = Timer.periodic(_config.sessionRefreshInterval, (_) {
      unawaited(
        refreshSession().catchError((Object error, StackTrace _) {
          if (!isApiAuthenticationFailure(error)) debugPrint('WatchDog session refresh failed: $error');
        }),
      );
    });
  }

  void handleAppPaused() {
    _appInForeground = false;
    _hooks.onRestartTickTimer?.call();
    _reportLifecycle(false);
  }

  Future<void> handleAppResumed() async {
    _appInForeground = true;
    _hooks.onRestartTickTimer?.call();
    _reportLifecycle(true);
    syncStore.checkConnectionLostTransition(notify: true);
    unawaited(refreshPendingMembers());
    try {
      await refreshSession();
    } catch (error) {
      if (!isApiAuthenticationFailure(error) && error is! StateError) {
        debugPrint('WatchDog resume session check failed: $error');
      }
    }
    if (!_disposed &&
        sessionStore.authenticated &&
        (_syncBridge.isCoordinatorRunning?.call() ?? false) &&
        !syncStore.isSyncConnected) {
      unawaited(_syncBridge.onCheckpointNow?.call());
    }
  }

  Future<void> refreshSession({bool force = false}) => coalesceAsyncOp(
    () => _sessionRefreshFuture,
    (f) => _sessionRefreshFuture = f,
    () {
      if (_disposed || !sessionStore.authenticated) return Future<void>.value();
      final activeConfig = sessionStore.config;
      final generation = _sessionGeneration;
      return executeSessionRefresh(
        force: force,
        nowMs: _config.nowMs(),
        leadTime: sessionRefreshLeadTime,
        activeTransport: _transport,
        activeConfig: activeConfig,
        isStillAuthenticatedSession: () =>
            isCurrentSession(activeConfig, generation) && sessionStore.authenticated,
        onInvalidateAuthentication: invalidateAuthenticationOnce,
      );
    },
  );

  void handleAuthenticationFailure(ApiException error) {
    if (_disposed || !isApiAuthenticationFailure(error)) return;
    unawaited(invalidateAuthenticationOnce());
  }

  /// 401/会话失效并发去重吊销：多个并发 401 共享同一次清理 Future，
  /// 确保 `_sessionGeneration` 与 `protectedDataEpoch` 原子递增一次且无残留。
  Future<void> invalidateAuthenticationOnce() => coalesceAsyncOp(
    () => _authenticationInvalidationFuture,
    (f) => _authenticationInvalidationFuture = f,
    () => _teardownSession(performLogout: false, clearIdentityProfile: false),
  );

  Future<void> authenticate({
    required String unitName,
    required String realName,
    required String unitCode,
  }) => coalesceAsyncOp(() => _authenticateFuture, (f) => _authenticateFuture = f, () async {
    if (_disposed) throw StateError('应用控制器已释放');
    final generation = _sessionGeneration;
    bool stillCurrent() => !_disposed && generation == _sessionGeneration;
    final ok = await authenticateAndPersistUnit(
      unitName: unitName,
      realName: realName,
      unitCode: unitCode,
      ensureReady: ensureReady,
      transportFactory: _config.transportFactory,
      deviceIdProvider: _readDeviceId,
      rosterStore: rosterStore,
      nowMs: _config.nowMs,
      isStillCurrent: stillCurrent,
    );
    if (!ok || !stillCurrent()) return;
    sessionStore.markAuthenticated(grantProtectedData: true, notify: false);
    await refreshConfig();
    if (!stillCurrent()) return;
    startAuthenticatedServices();
    final realtimeStart = _syncBridge.readRealtimeStartFuture?.call();
    if (realtimeStart != null) await realtimeStart;
    rosterStore.syncHotwordsToAsr();
    sessionStore.notifyStateChanged();
  });

  Future<void> enterGuestMode() async {
    _adminCapabilityTimer?.cancel();
    _adminCapabilityTimer = null;
    incidentStore.revokeProtectedData(notify: false);
    sessionStore.markGuestMode(hasCurrentIncident: true, notify: false);
    await Settings.setIsGuestMode(true);
    incidentStore.initGuestIncident(notify: true);
    syncStore.updateSyncContext(
      authenticated: false,
      isGuest: true,
      notify: true,
    );
    unawaited(_hooks.onEnsureOptionalServices?.call());
    sessionStore.notifyStateChanged();
  }

  Future<void> leaveUnit() =>
      _teardownSession(performLogout: true, clearIdentityProfile: true);

  Future<void> _teardownSession({
    required bool performLogout,
    required bool clearIdentityProfile,
  }) async {
    _adminCapabilityTimer?.cancel();
    _adminCapabilityTimer = null;
    incidentStore.revokeProtectedData(notify: false);
    sessionStore.revokeProtectedData(notify: false);
    sessionStore.setEnteredWithoutIncident(false, notify: false);
    final previousTransport = _transport;
    if (performLogout) {
      await (_hooks.onFlushLocalOpLogs ?? OpLogService.instance.flushLocal)();
    }
    _sessionGeneration++;
    await _syncBridge.onStopSyncCoordinator?.call();
    _hooks.onStopTickTimer?.call();
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    syncStore.resetForStop(resetHealth: true, notify: false);
    if (performLogout) await logoutBestEffort(previousTransport);
    await _hooks.onStopKeepAlive?.call();
    await _hooks.onClearScheduledNotifications?.call();
    _hooks.onResetAlertSession?.call();
    await clearPersistedSessionSettings(
      clearIdentityProfile: clearIdentityProfile,
      nowMs: _config.nowMs(),
    );
    _transport = null;
    previousTransport?.dispose();
    await resetStoresAfterTeardown(
      sessionStore: sessionStore,
      syncStore: syncStore,
      incidentStore: incidentStore,
      rosterStore: rosterStore,
      domainHooks: _hooks,
      refreshConfig: refreshConfig,
    );
  }

  Future<void> refreshConfig() {
    if (_disposed) return Future<void>.value();
    if (_refreshConfigFuture != null) {
      _refreshConfigAgain = true;
      return _refreshConfigFuture!;
    }
    final future = () async {
      do {
        _refreshConfigAgain = false;
        await _refreshConfigOnce();
      } while (!_disposed && _refreshConfigAgain);
    }();
    _refreshConfigFuture = future;
    future.whenComplete(() {
      if (!identical(_refreshConfigFuture, future)) return;
      _refreshConfigFuture = null;
      _refreshConfigAgain = false;
    });
    return future;
  }

  Future<void> _refreshConfigOnce() async {
    if (_disposed) return;
    final previousTransport = _transport;
    await _syncBridge.onStopSyncCoordinator?.call();
    if (_disposed) return;
    syncStore.setSyncSnapshotApplied(false, notify: false);
    final nextConfig = await loadSessionApiConfig(
      deviceIdProvider: _readDeviceId,
      onAuthenticationFailure: handleAuthenticationFailure,
    );
    final nextTransport = _config.transportFactory(nextConfig);
    if (_disposed) {
      nextTransport.dispose();
      return;
    }
    _transport = nextTransport;
    sessionStore.setConfig(nextConfig, notify: false);
    previousTransport?.dispose();
    if (nextConfig.incidentId.isNotEmpty &&
        !shouldDeferColdStartLogFlush(
          syncStarted: syncStore.syncStarted,
          authenticated: sessionStore.authenticated,
          config: nextConfig,
        )) {
      unawaited(_hooks.onFlushDiagnosticLogs?.call(nextConfig));
    }
    updateStore.applyCloudPreferences(
      asrCloudEnabled: await Settings.asrCloudEnabled,
      parseCloudEnabled: await Settings.parseCloudEnabled,
      notify: true,
    );
    await _hooks.onApplyDevicePreferences?.call();
    if (!_refreshConfigAgain && syncStore.syncStarted && sessionStore.authenticated) {
      _syncBridge.onRestartRealtimeSync?.call();
    }
    syncStore.updateSyncContext(
      authenticated: sessionStore.authenticated,
      isGuest: sessionStore.isGuest,
      coordinatorRunning: _syncBridge.isCoordinatorRunning?.call() ?? false,
      realtimeStarting: _syncBridge.readRealtimeStartFuture?.call() != null,
      notify: true,
    );
    sessionStore.notifyStateChanged();
  }

  Future<void> _withTransport(
    Future<void> Function(ApiHttpTransport t, ApiConfig c, bool Function() ok) fn, {
    bool requireAuth = false,
  }) {
    final t = _transport;
    final c = sessionStore.config;
    if (_disposed || t == null || c == null || (requireAuth && !sessionStore.authenticated)) {
      return Future<void>.value();
    }
    final gen = _sessionGeneration;
    return fn(t, c, () => isCurrentSession(c, gen));
  }

  Future<void> refreshAdminCapability() => _withTransport(
    (t, _, ok) => refreshUnitAdminCapability(
      sessionStore: sessionStore, transport: t, isSessionActive: ok,
    ),
  );

  Future<void> refreshPendingMembers() => _withTransport(
    (t, _, ok) => refreshUnitPendingMembers(
      sessionStore: sessionStore, transport: t, isSessionActive: ok,
    ),
  );

  Future<void> loadRoster({bool syncHotwords = false}) => _withTransport(
    (t, c, ok) => loadUnitRoster(
      rosterStore: rosterStore, transport: t, config: c,
      isStillCurrent: ok, syncHotwords: syncHotwords,
    ),
  );

  Future<void> syncSettings() => _withTransport(
    requireAuth: true,
    (t, _, ok) => coalesceAsyncOp(
      () => _syncSettingsFuture, (f) => _syncSettingsFuture = f,
      () => syncRemoteUserSettings(
        transport: t, isStillCurrent: ok, onAppliedRemote: refreshConfig,
      ),
    ),
  );

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionGeneration++;
    _adminCapabilityTimer?.cancel();
    _adminCapabilityTimer = null;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    final activeTransport = _transport;
    _transport = null;
    activeTransport?.dispose();
  }
}
