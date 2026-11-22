part of 'app_controller.dart';

mixin _AppControllerLifecycleMixin on _AppControllerBase {
  void setPipActive(bool active) {
    if (_pipActive == active) return;
    _pipActive = active;
    if (_tickTimer != null) {
      _restartTickTimer();
    }
  }

  @override
  void _restartTickTimer() {
    _tickTimer?.cancel();
    if (_disposed) return;
    final interval = (_appInForeground || _pipActive)
        ? AppController.foregroundTickInterval
        : AppController.backgroundTickInterval;
    _tickTimer = Timer.periodic(interval, (_) {
      final lost = connectionLost;
      if (lost != _lastConnectionLost) {
        _lastConnectionLost = lost;
        _recomputeSyncing();
        _notify();
      }
      _checkThresholds();
      clockTick.value++;
    });
  }

  void handleAppPaused() {
    _appInForeground = false;
    if (_tickTimer != null) {
      _restartTickTimer();
    }
    ForegroundKeepAlive.reportMainLifecycle(
      inForeground: _appInForeground,
      syncConnected: syncConnectionState == SyncConnectionState.connected,
    );
  }

  /// 启动静默检查更新：失败不打扰用户，只更新状态供设置页展示
  Future<void> checkUpdateSilently() async {
    final opId = 'release-check-${DateTime.now().millisecondsSinceEpoch}';
    void trace(String stage, String message, String level) {
      OpLogService.instance.record(
        opId,
        stage,
        message,
        level: level,
        data: {'source': 'ALI OTA'},
      );
    }

    try {
      final (info, error) = await UpdateService(
        logger: (stage, message, level) => trace(stage, message, level),
      ).checkForUpdate();
      pendingUpdate = info;
      updateCheckError = error;
    } catch (e) {
      // 网络/解析失败静默，用户可在设置页手动检查
      updateCheckError = '$e';
      trace('release_check_fail', '$e', 'error');
    }
    updateCheckDone = true;
    _notify();
  }

  /// 记录一次版本检查结果（设置页手动检查后调用，刷新共享提示状态）
  void recordUpdateCheck(UpdateInfo? info, String? error) {
    pendingUpdate = info;
    updateCheckError = error;
    updateCheckDone = true;
    _notify();
  }

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initInternal();
    _initFuture = future;
    future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        // 初始化失败允许用户稍后重试，不能把一次插件/配置异常永久缓存。
        if (identical(_initFuture, future)) _initFuture = null;
      },
    );
    return future;
  }

  /// 补登记异常退出时没来得及入库的拍摄文件。
  Future<void> _recoverMediaFiles() async {
    try {
      await MediaCaptureService.recoverOrphanedFiles();
    } catch (_) {
      // 恢复属于兜底逻辑，失败不影响启动
    }
  }

  /// 清理超过保留期的本机照片与录像（默认 30 天）。
  Future<void> _purgeExpiredMedia() async {
    try {
      await MediaCaptureService.purgeExpired();
    } catch (_) {
      // 清理属于维护任务，失败留到下次启动再试
    }
  }

  Future<void> _initInternal() async {
    // 诊断日志独立于核心同步链路，初始化失败也不能阻塞 App 启动。
    unawaited(DiagnosticLogService.instance.init());
    // 现场媒体按保留期自动清理；并补登记上次异常退出遗留的拍摄文件。
    unawaited(_purgeExpiredMedia());
    unawaited(_recoverMediaFiles());
    if (_offlineQueueDrainer == null) {
      unawaited(NoteMediaUploadQueue.instance.loadCache().catchError((_) {}));
    }
    // 先建立 API 客户端。首次安装必须先完成单位认证，认证前不拉取业务数据。
    await refreshConfig();
    if (_disposed) return;
    final sessionToken = await Settings.sessionToken;
    _authenticated =
        (await Settings.realName).isNotEmpty &&
        (await Settings.unitId).isNotEmpty &&
        (await Settings.unitName).isNotEmpty &&
        sessionToken.isNotEmpty;
    if (_authenticated) {
      _noteMediaMemberId = await Settings.memberId;
      final expiresAt = await Settings.sessionExpiresAt;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (expiresAt > 0 && expiresAt <= now) {
        await _invalidateAuthenticationOnce();
      } else if (expiresAt <= 0) {
        // 兼容升级前没有保存 expires_at 的会话：启动时立即向服务端校验并补齐。
        try {
          await _refreshSession(force: true);
        } on ApiException catch (error) {
          if (!ApiClient.isAuthenticationFailure(error)) rethrow;
        }
      }
    } else {
      _isGuest = await Settings.isGuestMode;
      if (_isGuest) {
        _initGuestIncident();
        unawaited(_ensureOptionalServices());
      }
    }
    // 认证前只恢复本地名单，不向服务端发送未认证请求；认证成功后由
    // _startAuthenticatedServices 统一发起一次远端刷新。
    await _ensureLocalRoster();
    if (_authenticated) {
      _startAuthenticatedServices();
    } else {
      _notify();
    }
  }

  @override
  void _startAuthenticatedServices() {
    if (_disposed || !_authenticated || _syncStarted) return;
    unawaited(_restoreCachedExternalIncidents());
    _startSessionRefreshTimer();
    _adminCapabilityTimer?.cancel();
    _adminCapabilityTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_appInForeground) {
        unawaited(refreshAdminCapability());
        unawaited(refreshPendingMembersCount());
      }
    });
    final previousStartFuture = _realtimeStartFuture;
    startSync();
    final startFuture = _realtimeStartFuture;
    if (startFuture != null && !identical(startFuture, previousStartFuture)) {
      final generation = _sessionGeneration;
      unawaited(
        startFuture.whenComplete(() {
          unawaited(_runPostBootstrapStartupTasks(generation: generation));
        }),
      );
      unawaited(_ensureOptionalServices());
      return;
    }
    unawaited(refreshAdminCapability());
    // 认证前的名单请求会被服务端拒绝；认证完成后重新拉取，拿到单位当前名单。
    unawaited(loadRoster());
    // 启动后同步个人设置（服务器较新拉取、本地较新推送）
    syncSettings();
    // 启动后补传上次未上传完的操作日志（fire-and-forget）
    OpLogService.instance.flush(api: api);
    // 管理员拉取待审批成员数
    unawaited(refreshPendingMembersCount());
    // 报警、TTS 和后台值守在后台初始化，任何系统权限/插件问题都不影响
    // 活跃警情列表与新建警情。
    unawaited(_ensureOptionalServices());
  }

  Future<void> _runPostBootstrapStartupTasks({required int generation}) async {
    if (_disposed || !_authenticated || generation != _sessionGeneration) {
      return;
    }
    unawaited(refreshAdminCapability());
    if (!_syncSnapshotApplied) {
      unawaited(loadRoster());
      unawaited(refreshPendingMembersCount());
    }
    unawaited(syncSettings());
    final activeApi = api;
    if (activeApi != null) {
      unawaited(OpLogService.instance.flush(api: activeApi));
      final incidentId =
          currentIncident?.id ?? await Settings.currentIncidentId;
      if (_disposed ||
          !_authenticated ||
          generation != _sessionGeneration ||
          !identical(api, activeApi)) {
        return;
      }
      if (incidentId.isNotEmpty) {
        unawaited(DiagnosticLogService.instance.flush(api: activeApi));
      }
    }
  }

  void _startSessionRefreshTimer() {
    _sessionRefreshTimer?.cancel();
    if (_disposed || !_authenticated) return;
    _sessionRefreshTimer = Timer.periodic(AppController.sessionRefreshCheckInterval, (_) {
      unawaited(
        _refreshSession().catchError((Object error, StackTrace stackTrace) {
          if (!ApiClient.isAuthenticationFailure(error)) {
            AppLogger.error('WatchDog session refresh failed', tag: 'auth', error: error);
          }
        }),
      );
    });
  }

  /// App 从后台回到前台时立即核对会话，避免后台挂起期间错过定时续期。
  Future<void> handleAppResumed() async {
    _appInForeground = true;
    if (_tickTimer != null) {
      _restartTickTimer();
    }
    ForegroundKeepAlive.reportMainLifecycle(
      inForeground: _appInForeground,
      syncConnected: syncConnectionState == SyncConnectionState.connected,
    );
    final lost = connectionLost;
    if (lost != _lastConnectionLost) {
      _lastConnectionLost = lost;
      _recomputeSyncing();
      _notify();
    }
    unawaited(refreshPendingMembersCount());
    try {
      await _refreshSession();
    } catch (error) {
      if (!ApiClient.isAuthenticationFailure(error) && error is! StateError) {
        AppLogger.error('WatchDog resume session check failed', tag: 'auth', error: error);
      }
    }
    if (!_disposed &&
        _authenticated &&
        _syncCoordinator != null &&
        _syncCoordinator!.running &&
        syncConnectionState != SyncConnectionState.connected) {
      unawaited(_syncCoordinator!.checkpointNow());
    }
  }

  Future<void> _initOptionalServices(int generation) async {
    try {
      await tts.init();
    } catch (e) {
      AppLogger.error('TtsService init failed', tag: 'tts', error: e);
    }
    try {
      await alarm.init();
      if (_disposed || generation != _sessionGeneration || !_authenticated) {
        return;
      }
      _alarmReady = true;
      await _rescheduleNotifications();
    } catch (e) {
      AppLogger.error('AlarmService init failed', tag: 'alarm', error: e);
    }
    if (_disposed || generation != _sessionGeneration || !_authenticated) {
      return;
    }
    try {
      await syncKeepAlive();
    } catch (e) {
      AppLogger.error('ForegroundKeepAlive start failed', tag: 'keep_alive', error: e);
    }
  }

  /// 可选插件初始化失败时允许在用户刷新或下一轮同步时重试，但用短暂
  /// 闸门避免故障插件导致重复初始化和刷日志。
  @override
  Future<void> _ensureOptionalServices({bool force = false}) {
    if (_disposed || !_authenticated) return Future<void>.value();
    if (_alarmReady) return Future<void>.value();
    final existing = _optionalServicesFuture;
    if (existing != null) return existing;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastOptionalServicesAttemptAt < 30000) {
      return Future<void>.value();
    }
    _lastOptionalServicesAttemptAt = now;
    final future = _initOptionalServices(_sessionGeneration);
    _optionalServicesFuture = future;
    future.then<void>(
      (_) {
        if (identical(_optionalServicesFuture, future)) {
          _optionalServicesFuture = null;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_optionalServicesFuture, future)) {
          _optionalServicesFuture = null;
        }
      },
    );
    return future;
  }

  /// 等待启动初始化完成。某些页面在初始化 Future 完成前就可以交互，
  /// 需要使用 API 的操作必须先经过这里。
  @override
  Future<void> _ensureApiReady() async {
    if (api != null) return;
    final initFuture = _initFuture;
    if (initFuture != null) await initFuture;
    if (api == null && !_disposed) await refreshConfig();
  }

  /// 保活服务与本地设置同步：开启时启动并更新配置，关闭时停止
}
