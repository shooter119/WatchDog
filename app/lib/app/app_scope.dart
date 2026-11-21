import 'dart:async';

import '../core/sync/sync_store.dart';
import '../features/auth/state/session_store.dart';
import '../features/incident/state/incident_store.dart';
import '../features/roster/state/roster_store.dart';
import '../features/settings/state/update_store.dart';
import '../services/local_asr_service.dart';
import '../services/video_playback_session.dart';
import 'orchestrators/incident_orchestrator.dart';
import 'orchestrators/orchestrator_contracts.dart';
import 'orchestrators/session_auth_helper.dart';
import 'orchestrators/session_orchestrator.dart';

/// 应用轻量级依赖装配容器（DI Scope）。
///
/// 统一创建、持有并按逆序安全释放 M2 底座全部 5 个独立 Store、2 个跨域编排器以及
/// 冻结服务实例（[VideoPlaybackSession]、[LocalAsrService]），支持测试按需注入任意覆写。
class AppScope {
  final SyncStore syncStore;
  final SessionStore sessionStore;
  final IncidentStore incidentStore;
  final RosterStore rosterStore;
  final UpdateStore updateStore;
  final SessionOrchestrator sessionOrchestrator;
  final IncidentOrchestrator incidentOrchestrator;
  final VideoPlaybackSession videoPlaybackSession;
  final LocalAsrService? localAsrService;

  bool _disposed = false;

  AppScope._({
    required this.syncStore,
    required this.sessionStore,
    required this.incidentStore,
    required this.rosterStore,
    required this.updateStore,
    required this.sessionOrchestrator,
    required this.incidentOrchestrator,
    required this.videoPlaybackSession,
    required this.localAsrService,
  });

  factory AppScope({
    SyncStore? syncStore,
    SessionStore? sessionStore,
    IncidentStore? incidentStore,
    RosterStore? rosterStore,
    UpdateStore? updateStore,
    SessionOrchestrator? sessionOrchestrator,
    IncidentOrchestrator? incidentOrchestrator,
    VideoPlaybackSession? videoPlaybackSession,
    LocalAsrService? localAsrService,
    bool createDefaultLocalAsr = true,
    ApiTransportFactory transportFactory = defaultApiTransportFactory,
    IncidentSyncDriverFactory? syncDriverFactory,
    IncidentDomainHooks domainHooks = IncidentDomainHooks.empty,
    OfflineQueueDrainerCallback? offlineQueueDrainer,
    OfflinePendingRowsProvider? offlinePendingRowsProvider,
    int Function()? nowMs,
    Future<String> Function()? deviceIdProvider,
    Duration sessionRefreshInterval =
        SessionOrchestrator.sessionRefreshCheckInterval,
    Duration adminCapabilityInterval =
        SessionOrchestrator.adminCapabilityCheckInterval,
    bool enableStartupMaintenance = true,
    bool Function()? isAssistantBusy,
    void Function({required bool inForeground, required bool syncConnected})?
    reportLifecycle,
  }) {
    final resolvedNowMs = nowMs ?? SessionOrchestratorConfig.defaultNowMs;
    final resolvedLocalAsr =
        localAsrService ?? (createDefaultLocalAsr ? LocalAsrService() : null);
    final resolvedVideo = videoPlaybackSession ?? VideoPlaybackSession();

    final resolvedSyncStore = syncStore ?? SyncStore(nowMs: resolvedNowMs);
    final resolvedSessionStore = sessionStore ?? SessionStore();
    final resolvedIncidentStore = incidentStore ?? IncidentStore();
    final resolvedRosterStore =
        rosterStore ?? RosterStore(localAsr: resolvedLocalAsr);
    final resolvedUpdateStore =
        updateStore ?? UpdateStore(nowMs: resolvedNowMs);

    late final SessionOrchestrator resolvedSession;
    late final IncidentOrchestrator resolvedIncident;

    resolvedSession =
        sessionOrchestrator ??
        SessionOrchestrator(
          sessionStore: resolvedSessionStore,
          syncStore: resolvedSyncStore,
          incidentStore: resolvedIncidentStore,
          rosterStore: resolvedRosterStore,
          updateStore: resolvedUpdateStore,
          config: SessionOrchestratorConfig(
            transportFactory: transportFactory,
            nowMs: resolvedNowMs,
            deviceIdProvider: deviceIdProvider,
            sessionRefreshInterval: sessionRefreshInterval,
            adminCapabilityInterval: adminCapabilityInterval,
            enableStartupMaintenance: enableStartupMaintenance,
            domainHooks: domainHooks,
            reportLifecycle: reportLifecycle,
            syncBridge: SessionSyncBridge(
              onStartSync: () => resolvedIncident.startSync(),
              onRestartRealtimeSync: () =>
                  resolvedIncident.restartRealtimeSync(),
              onStopSyncCoordinator: () => resolvedIncident.stopSyncDriver(),
              onCheckpointNow: () => resolvedIncident.checkpointNow(),
              isCoordinatorRunning: () => resolvedIncident.isSyncDriverRunning,
              readRealtimeStartFuture: () =>
                  resolvedIncident.realtimeStartFuture,
            ),
          ),
        );

    resolvedIncident =
        incidentOrchestrator ??
        IncidentOrchestrator(
          sessionStore: resolvedSessionStore,
          syncStore: resolvedSyncStore,
          incidentStore: resolvedIncidentStore,
          rosterStore: resolvedRosterStore,
          config: IncidentOrchestratorConfig(
            readSessionGeneration: () => resolvedSession.sessionGeneration,
            bumpSessionGeneration: () => resolvedSession.bumpSessionGeneration(),
            readTransport: () => resolvedSession.transport,
            refreshConfig: () => resolvedSession.refreshConfig(),
            refreshSession: ({bool force = false}) =>
                resolvedSession.refreshSession(force: force),
            ensureSessionReady: () => resolvedSession.ensureReady(),
            invalidateAuthenticationOnce: () =>
                resolvedSession.invalidateAuthenticationOnce(),
            refreshAdminCapability: () =>
                resolvedSession.refreshAdminCapability(),
            refreshPendingMembers: () =>
                resolvedSession.refreshPendingMembers(),
            readAppInForeground: () => resolvedSession.appInForeground,
            syncDriverFactory: syncDriverFactory,
            transportFactory: transportFactory,
            domainHooks: domainHooks,
            offlineQueueDrainer: offlineQueueDrainer,
            offlinePendingRowsProvider: offlinePendingRowsProvider,
            isAssistantBusy: isAssistantBusy,
            reportLifecycle: reportLifecycle,
            nowMs: resolvedNowMs,
          ),
        );

    return AppScope._(
      syncStore: resolvedSyncStore,
      sessionStore: resolvedSessionStore,
      incidentStore: resolvedIncidentStore,
      rosterStore: resolvedRosterStore,
      updateStore: resolvedUpdateStore,
      sessionOrchestrator: resolvedSession,
      incidentOrchestrator: resolvedIncident,
      videoPlaybackSession: resolvedVideo,
      localAsrService: resolvedLocalAsr,
    );
  }

  bool get isDisposed => _disposed;

  /// 按编排器 -> 冻结服务 -> 领域 Store 逆序安全释放，重复调用幂等。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sessionOrchestrator.dispose();
    incidentOrchestrator.dispose();
    videoPlaybackSession.dispose();
    final asr = localAsrService;
    if (asr != null) unawaited(asr.dispose());
    syncStore.dispose();
    sessionStore.dispose();
    incidentStore.dispose();
    rosterStore.dispose();
    updateStore.dispose();
  }
}
