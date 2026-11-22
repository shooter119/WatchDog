part of 'app_controller.dart';

mixin _AppControllerSyncMixin on _AppControllerBase {
  @override
  void _recomputeSyncing() {
    syncing = shouldShowSyncingIndicator(
      disposed: _disposed,
      isGuest: _isGuest,
      authenticated: _authenticated,
      syncConnectionState: syncConnectionState,
      syncSnapshotApplied: _syncSnapshotApplied,
      connectionLost: connectionLost,
      coordinatorRunning: _syncCoordinator?.running == true,
      realtimeStarting: _realtimeStartFuture != null,
      manualRefreshInFlight: _manualRefreshInFlight,
      legacySyncInFlight: _legacySyncInFlight,
    );
  }

  @override
  void _reportMainSnapshotToKeepAlive() {
    final activeEntries = entries.where((entry) => entry.isActive).toList()
      ..sort((a, b) => a.exitAt.compareTo(b.exitAt));
    ForegroundKeepAlive.reportMainSnapshot(
      activeCount: activeEntries.length,
      earliestExitAt: activeEntries.isEmpty ? 0 : activeEntries.first.exitAt,
      mainInForeground: _appInForeground,
      mainSyncConnected: syncConnectionState == SyncConnectionState.connected,
    );
  }

  @override
  void _trackRealtimeStart(Future<void> future) {
    _realtimeStartFuture = future;
    _recomputeSyncing();
    unawaited(
      future.whenComplete(() {
        if (identical(_realtimeStartFuture, future)) {
          _realtimeStartFuture = null;
          _recomputeSyncing();
          _notify();
        }
      }),
    );
  }

  @override
  void startSync() {
    if (_disposed || needsAuthentication) return;
    if (_syncStarted) {
      unawaited(_syncCoordinator?.checkpointNow() ?? Future<void>.value());
      return;
    }
    _syncStarted = true;
    _restartTickTimer();
    _trackRealtimeStart(_startRealtimeSync());
    _notify();
  }

  @override
  Future<void> sync() => _sync(force: false);

  Future<void> _sync({bool force = false}) {
    if (_disposed || _assistantBusy || api == null) {
      return Future<void>.value();
    }
    final realtime = _syncCoordinator;
    if (realtime != null && realtime.running) {
      return realtime.checkpointNow(force: force);
    }
    final realtimeStart = _realtimeStartFuture;
    if (realtimeStart != null) {
      return realtimeStart.then((_) {
        if (identical(_realtimeStartFuture, realtimeStart)) {
          _realtimeStartFuture = null;
        }
        if (_disposed) return Future<void>.value();
        final started = _syncCoordinator;
        if (started != null && started.running) {
          if (force && syncConnectionState != SyncConnectionState.connected) {
            return started.checkpointNow(force: true);
          }
          return Future<void>.value();
        }
        return _sync(force: force);
      });
    }
    final existing = _syncFuture;
    if (existing != null) return existing;
    final a = api!;
    final generation = _sessionGeneration;
    final future = _syncInternal(a, generation);
    _syncFuture = future;
    future.then<void>(
      (_) {
        if (identical(_syncFuture, future)) _syncFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_syncFuture, future)) _syncFuture = null;
      },
    );
    return future;
  }

  @override
  Future<void> _startRealtimeSync() async {
    final a = api;
    if (_disposed || !_authenticated || a == null) return;
    final incidentId = await Settings.currentIncidentId;
    if (_disposed || !_authenticated || !identical(api, a)) return;
    final previous = _syncCoordinator;
    if (previous != null) {
      _syncCoordinator = null;
      await previous.stop();
    }
    if (_disposed || !_authenticated || !identical(api, a)) return;
    final coordinator = SyncCoordinator(
      api: a,
      onSnapshot: _applySyncSnapshot,
      onEvent: _applySyncEvent,
      onState: _handleSyncState,
      onStaleIncident: _handleStaleBootstrapIncident,
      clientFactory: _syncClientFactory,
    );
    _syncCoordinator = coordinator;
    await coordinator.start(incidentId: incidentId.isEmpty ? null : incidentId);
  }

  void _handleStaleBootstrapIncident(String staleIncidentId) {
    if (_disposed) return;
    if (currentIncident?.id == staleIncidentId) {
      currentIncident = null;
      entries = [];
      notes = [];
      forces = [];
    }
    unawaited(Settings.setCurrentIncidentId(''));
    _notify();
  }

  void _handleSyncState(SyncConnectionState state, Object? error) {
    if (error != null && ApiClient.isAuthenticationFailure(error)) {
      unawaited(_invalidateAuthenticationOnce());
      return;
    }
    if (_disposed) return;
    final now = _nowMs();
    final wasConnected = syncConnectionState == SyncConnectionState.connected;
    syncConnectionState = state;
    if (state == SyncConnectionState.connected) {
      _lastSyncSuccessAt = now;
      _firstSyncFailureAt = 0;
      syncError = null;
    } else if (state == SyncConnectionState.stopped) {
      // 由 shouldShowSyncingIndicator 统一收口状态计算
    } else {
      if (wasConnected) {
        // 实时通道刚掉线：从掉线时刻重新起算 30 秒平滑窗口
        _lastSyncSuccessAt = now;
        _firstSyncFailureAt = now;
      }
      syncError = null;
      if (error != null ||
          state == SyncConnectionState.reconnecting ||
          state == SyncConnectionState.error) {
        _firstSyncFailureAt = _firstSyncFailureAt == 0
            ? now
            : _firstSyncFailureAt;
      }
      if (error != null && now - _lastSyncErrorLogAt >= 15000) {
        _lastSyncErrorLogAt = now;
        OpLogService.instance.record(
          'realtime-sync',
          'sync_retry',
          '$error',
          level: 'warn',
        );
        AppLogger.error('WatchDog realtime sync retry', tag: 'sync', error: error);
      }
    }
    _lastConnectionLost = connectionLost;
    _recomputeSyncing();
    ForegroundKeepAlive.reportMainLifecycle(
      inForeground: _appInForeground,
      syncConnected: syncConnectionState == SyncConnectionState.connected,
    );
    if (state == SyncConnectionState.connected) {
      _reportMainSnapshotToKeepAlive();
      unawaited(drainNoteMediaUploads());
    }
    _notify();
  }

  Future<void> _syncInternal(ApiClient a, int generation) async {
    final opToken = ++_nextSyncOpToken;
    _activeLegacySyncOps.add(opToken);
    _legacySyncInFlight = true;
    _recomputeSyncing();
    // 让页面在慢请求期间立即进入“同步中”，而不是等请求结束后才收到
    // 一次性状态通知；这也避免短请求沿用上一轮“已连接”文案造成误导。
    _notify();
    try {
      if (_offlineQueueDrainer == null && (await Settings.memberId).isEmpty) {
        final identity = await a.fetchAuthIdentity();
        if (!_isCurrentSession(a, generation)) return;
        await Settings.setMemberId(identity['member_id']?.toString() ?? '');
      }
      final fetchedActiveIncidents = await a.fetchIncidents(status: 'active');
      if (!_isCurrentSession(a, generation)) return;
      activeIncidents = fetchedActiveIncidents;
      final savedId = await Settings.currentIncidentId;
      final allowedIncidentIds = {
        ...activeIncidents.map((incident) => incident.id),
        if (savedId.isNotEmpty) savedId,
      };
      final drain = _offlineQueueDrainer;
      if (drain != null) {
        await drain();
      } else {
        await OfflineQueue.instance.drain(
          (id) => a.forIncident(id),
          allowedIncidentIds: allowedIncidentIds,
        );
        unawaited(
          drainNoteMediaUploads(allowedIncidentIds: allowedIncidentIds),
        );
        final reviewCount =
            (await OfflineQueue.instance.reviewOperations()).length +
            await OfflineQueue.instance.legacyReviewCount();
        if (!_isCurrentSession(a, generation)) return;
        offlineReviewCount = reviewCount;
      }
      if (!_isCurrentSession(a, generation)) return;
      if (savedId.isEmpty) {
        currentIncident = null;
        entries = [];
        notes = [];
        forces = [];
      } else {
        final incident = await a.fetchIncident(savedId);
        if (!_isCurrentSession(a, generation)) return;
        if (!incident.isActive) {
          currentIncident = null;
          await Settings.setCurrentIncidentId('');
          entries = [];
          notes = [];
          forces = [];
        } else {
          currentIncident = incident;
          entries = await a.fetchEntries();
          if (!_isCurrentSession(a, generation)) return;
          try {
            notes = await a.fetchNotes();
          } catch (_) {}
          try {
            forces = await a.fetchIncidentForces();
          } catch (_) {}
          // 补传失败时服务端快照仍可能落后于本地。把活动队列按发生顺序
          // 重新投影到刚拉取的快照，避免下一轮同步把离线操作的即时反馈抹掉。
          try {
            await _applyOfflineProjection(savedId);
          } catch (error) {
            AppLogger.error('WatchDog offline projection failed', tag: 'sync', error: error);
          }
        }
      }
      syncError = null;
      _lastSyncSuccessAt = _nowMs();
      _firstSyncFailureAt = 0;
      _lastConnectionLost = connectionLost;
      _reportMainSnapshotToKeepAlive();
      await _rescheduleNotifications();
      unawaited(_ensureOptionalServices());
    } catch (e) {
      if (!_isCurrentSession(a, generation)) return;
      if (e is ApiException && e.code == 'INCIDENT_NOT_FOUND') {
        // 当前单位已无法访问本机保存的警情（例如切换单位、警情被撤销
        // 或服务端权限收紧）。不能继续展示上一单位的缓存快照，避免把
        // 旧警情、人员和压力数据误呈现给当前用户。
        await Settings.setCurrentIncidentId('');
        if (!_isCurrentSession(a, generation)) return;
        currentIncident = null;
        entries = [];
        notes = [];
        forces = [];
        syncError = null;
        _firstSyncFailureAt = 0;
        await _stopKeepAliveSafely();
        await _clearScheduledNotifications();
        return;
      }
      if (e is ApiException &&
          (e.code == 'UNIT_INVALID' ||
              e.code == 'UNIT_AUTH_REQUIRED' ||
              e.code == 'SESSION_REQUIRED' ||
              e.code == 'SESSION_INVALID' ||
              e.code == 'SESSION_EXPIRED')) {
        await _invalidateAuthenticationOnce();
        return;
      }
      // 请求级超时和 HttpClient 的连接/空闲超时负责回收失败连接；不能为了
      // 一次同步失败关闭共享客户端，否则会中断同时进行的日志或其他请求。
      final now = _nowMs();
      _firstSyncFailureAt = _firstSyncFailureAt == 0
          ? now
          : _firstSyncFailureAt;
      syncError = null;
      if (now - _lastSyncErrorLogAt >= 15000) {
        _lastSyncErrorLogAt = now;
        OpLogService.instance.record('sync', 'sync_retry', '$e', level: 'warn');
      }
      AppLogger.error('WatchDog sync failed', tag: 'sync', error: e);
    } finally {
      _activeLegacySyncOps.remove(opToken);
      _legacySyncInFlight = _activeLegacySyncOps.isNotEmpty;
      _lastConnectionLost = connectionLost;
      _recomputeSyncing();
      _notify();
    }
  }

  Future<void> _applyOfflineProjection(String incidentId) async {
    // 测试/嵌入方可注入自己的队列排空器；此时不能偷偷打开全局 sqflite
    // 数据库，否则替身隔离会失效，也会把平台数据库初始化带入核心同步。
    if (incidentId.isEmpty || _offlineQueueDrainer != null) return;
    final rows = await OfflineQueue.instance.pendingOperations(incidentId);
    if (rows.isEmpty) return;
    final author = await Settings.realName;
    final projection = AppController.applyOfflineOperationProjection(
      rows: rows,
      entries: entries,
      notes: notes,
      calcConfig: calcConfig,
      author: author,
    );
    entries = projection.$1;
    notes = projection.$2;
  }

  /// 将仍在本地待补传的业务操作重新叠加到服务端快照。
  /// 返回新列表，不修改传入集合，便于同步逻辑和回归测试复用。
  @override
  Future<void> refreshNow() async {
    unawaited(_ensureOptionalServices(force: true));
    unawaited(drainNoteMediaUploads());
    if (_disposed || _isGuest) return;
    final opToken = ++_nextSyncOpToken;
    _activeManualRefreshOps.add(opToken);
    _manualRefreshInFlight = true;
    _recomputeSyncing();
    _notify();
    try {
      await _sync(force: true);
    } finally {
      _activeManualRefreshOps.remove(opToken);
      _manualRefreshInFlight = _activeManualRefreshOps.isNotEmpty;
      _lastConnectionLost = connectionLost;
      _recomputeSyncing();
      _notify();
    }
  }

  /// 新条目到达时调度本地通知；exitAt 变化（改名/压力复核）时重新调度
}
