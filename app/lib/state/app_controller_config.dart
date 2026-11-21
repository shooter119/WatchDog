part of 'app_controller.dart';

mixin _AppControllerConfigMixin on _AppControllerBase {
  @override
  Future<void> syncKeepAlive() {
    if (_disposed) return Future<void>.value();
    final existing = _keepAliveFuture;
    if (existing != null) return existing;
    final future = _syncKeepAliveInternal(_sessionGeneration);
    _keepAliveFuture = future;
    future.then<void>(
      (_) {
        if (identical(_keepAliveFuture, future)) _keepAliveFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_keepAliveFuture, future)) _keepAliveFuture = null;
      },
    );
    return future;
  }

  Future<void> _syncKeepAliveInternal(int generation) async {
    final enabled = await Settings.keepAliveEnabled;
    if (_disposed || generation != _sessionGeneration) return;
    if (!enabled) {
      await _stopKeepAliveSafely();
      return;
    }
    if (!_authenticated) {
      await _stopKeepAliveSafely();
      return;
    }
    final serverUrl = await Settings.serverUrl;
    final incidentId = await Settings.currentIncidentId;
    final sessionToken = await Settings.sessionToken;
    final unitId = await Settings.unitId;
    final unitCode = await Settings.unitCode;
    if (_disposed || generation != _sessionGeneration || !_authenticated) {
      return;
    }
    if (!shouldRunForegroundKeepAlive(
      enabled: enabled,
      authenticated: _authenticated,
      incidentId: incidentId,
    )) {
      await _stopKeepAliveSafely();
      return;
    }
    await ForegroundKeepAlive.start(
      serverUrl: serverUrl,
      incidentId: incidentId,
      token: '',
      sessionToken: sessionToken,
      unitId: unitId,
      unitCode: unitCode,
      warnMin: calcConfig.warnMin,
      alarmMin: calcConfig.alarmMin,
      mainInForeground: _appInForeground,
    );
  }

  /// 用户设置云同步：服务器较新则拉取覆盖本地并生效，本地较新则推送，一致跳过
  @override
  Future<void> syncSettings() {
    if (_disposed || !_authenticated || api == null) {
      return Future<void>.value();
    }
    final existing = _syncSettingsFuture;
    if (existing != null) return existing;
    final future = _syncSettingsInternal(api!);
    _syncSettingsFuture = future;
    future.then<void>(
      (_) {
        if (identical(_syncSettingsFuture, future)) _syncSettingsFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_syncSettingsFuture, future)) _syncSettingsFuture = null;
      },
    );
    return future;
  }

  Future<void> _syncSettingsInternal(ApiClient a) async {
    try {
      final remote = await a.fetchUserSettings();
      final remoteAt = (remote['updatedAt'] as num?)?.toInt() ?? 0;
      final localAt = await Settings.modifiedAt;
      if (remoteAt > localAt) {
        final remoteSettings = remote['settings'];
        if (remoteSettings is! Map) return;
        await Settings.applyFromServer(
          Map<String, dynamic>.from(remoteSettings),
          updatedAt: remoteAt,
        );
        await refreshConfig();
      } else if (remoteAt < localAt) {
        await a.pushUserSettings(await Settings.toSyncMap());
      }
    } catch (_) {
      // 网络失败静默，下次启动或保存设置时再试
      // 该请求与警情同步共用连接池；不要因为可选设置同步失败而关闭
      // 核心请求池，下一轮同步会自然重试。
    }
  }

  @override
  Future<void> refreshConfig() {
    if (_disposed) return Future<void>.value();
    final existing = _refreshConfigFuture;
    if (existing != null) {
      _refreshConfigAgain = true;
      return existing;
    }
    final future = _refreshConfigLoop();
    _refreshConfigFuture = future;
    future.then<void>(
      (_) {
        if (identical(_refreshConfigFuture, future)) {
          _refreshConfigFuture = null;
          _refreshConfigAgain = false;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_refreshConfigFuture, future)) {
          _refreshConfigFuture = null;
          _refreshConfigAgain = false;
        }
      },
    );
    return future;
  }

  Future<void> _refreshConfigLoop() async {
    do {
      _refreshConfigAgain = false;
      await _refreshConfigOnce();
    } while (!_disposed && _refreshConfigAgain);
  }

  Future<void> _refreshConfigOnce() async {
    if (_disposed) return;
    final previousApi = api;
    final existingCoordinator = _syncCoordinator;
    if (existingCoordinator != null) {
      _syncCoordinator = null;
      await existingCoordinator.stop();
    }
    if (_disposed) return;
    _syncSnapshotApplied = false;
    final serverUrl = await Settings.serverUrl;
    final incidentId = await Settings.currentIncidentId;
    final sessionToken = await Settings.sessionToken;
    final unitId = await Settings.unitId;
    final unitCode = await Settings.unitCode;
    final actorName = await Settings.realName;
    final deviceId = await OpLogService.instance.deviceId;
    final nextApi = (_apiFactory ?? _defaultApiFactory)(
      baseUrl: serverUrl,
      incidentId: incidentId,
      sessionToken: sessionToken,
      deviceId: deviceId,
      actorName: actorName,
      unitId: unitId,
      unitCode: unitCode,
      onAuthenticationFailure: _handleAuthenticationFailure,
    );
    if (_disposed) {
      nextApi.dispose();
      return;
    }
    api = nextApi;
    previousApi?.dispose();
    AppLogger.log(
      'WatchDog config ready: url=$serverUrl, '
      'incident=${incidentId.isEmpty ? 'none' : 'selected'}, '
      'actor=${actorName.isEmpty ? 'empty' : 'configured'}',
      tag: 'config',
    );
    // 有当前警情时顺手补传上次启动/异常遗留的诊断日志；冷启动首轮同步前
    // 先留给 _runPostBootstrapStartupTasks 错峰上传，避免与 bootstrap 并发抢占冷启动通道。
    final deferColdStartLogFlush =
        !_syncStarted &&
        (_authenticated || (sessionToken.isNotEmpty && unitId.isNotEmpty));
    if (incidentId.isNotEmpty && !deferColdStartLogFlush) {
      unawaited(DiagnosticLogService.instance.flush(api: nextApi));
    }
    tts.enabled = await Settings.ttsEnabled;
    alarm.soundEnabled = await Settings.alarmSoundEnabled;
    await ScreenOn.setKeepScreenOn(await Settings.keepScreenOn);
    asrCloudEnabled = await Settings.asrCloudEnabled;
    parseCloudEnabled = await Settings.parseCloudEnabled;
    // 本地设置为准：用户改的消耗率/容量/阈值立即生效，不被服务端配置覆盖
    calcConfig = CalcConfig(
      cylinderVolL: await Settings.cylinderVolL,
      fullPressureMpa: await Settings.fullPressureMpa,
      consumptionLpm: await Settings.consumptionLpm,
      warnMin: await Settings.warnMin,
      alarmMin: await Settings.alarmMin,
    );
    if (!_refreshConfigAgain && _syncStarted && _authenticated) {
      _trackRealtimeStart(_startRealtimeSync());
    }
    _recomputeSyncing();
    _notify();
  }

  @override
  Future<void> _stopKeepAliveSafely() async {
    try {
      await ForegroundKeepAlive.stop();
    } catch (error) {
      AppLogger.error('ForegroundKeepAlive stop failed', tag: 'keep_alive', error: error);
    }
  }

}
