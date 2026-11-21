part of 'app_controller.dart';

mixin _AppControllerAuthMixin on _AppControllerBase {
  @override
  Future<void> refreshAdminCapability() async {
    final activeApi = api;
    final epoch = protectedDataEpoch;
    if (!canReadKeySites || activeApi == null) {
      return;
    }
    final request = ++_adminCapabilityRequest;
    try {
      final capability = await activeApi.fetchAdminCapability();
      if (canReadKeySites &&
          api == activeApi &&
          epoch == protectedDataEpoch &&
          request == _adminCapabilityRequest) {
        adminCapability = capability;
        _notify();
      }
    } catch (_) {
      if (api == activeApi &&
          epoch == protectedDataEpoch &&
          request == _adminCapabilityRequest) {
        adminCapability = null;
        _notify();
      }
    }
  }

  /// 从启动层直接进入 App，不选择也不新建警情。
  void enterWithoutIncident() {
    if (currentIncident != null || _isGuest) return;
    _enteredWithoutIncident = true;
    _notify();
  }

  /// 从首页或其他处警入口重新打开警情选择层。
  void requestIncidentSelection() {
    if (currentIncident != null || _isGuest) return;
    _enteredWithoutIncident = false;
    _notify();
  }

  @override
  Future<void> _refreshSession({bool force = false}) {
    final existing = _sessionRefreshFuture;
    if (existing != null) return existing;
    final future = _refreshSessionInternal(force: force);
    _sessionRefreshFuture = future;
    future.then<void>(
      (_) {
        if (identical(_sessionRefreshFuture, future)) {
          _sessionRefreshFuture = null;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_sessionRefreshFuture, future)) {
          _sessionRefreshFuture = null;
        }
      },
    );
    return future;
  }

  Future<void> _refreshSessionInternal({required bool force}) async {
    if (_disposed || !_authenticated) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = await Settings.sessionExpiresAt;
    if (expiresAt > 0 && expiresAt <= now) {
      await _invalidateAuthenticationOnce();
      throw StateError('认证会话已过期，请重新认证');
    }
    if (!force && expiresAt > now + AppController.sessionRefreshLeadTime.inMilliseconds) {
      return;
    }
    final activeApi = api;
    if (activeApi == null || activeApi.sessionToken.isEmpty) {
      await _invalidateAuthenticationOnce();
      throw StateError('认证会话已失效，请重新认证');
    }
    final generation = _sessionGeneration;
    try {
      final result = await activeApi.refreshSession();
      if (!_isCurrentSession(activeApi, generation) || !_authenticated) return;
      final refreshedExpiresAt = _intValue(result['expires_at']);
      if (refreshedExpiresAt <= now) {
        throw ApiException(
          '认证续期响应无效，请重新认证',
          statusCode: 401,
          code: 'SESSION_INVALID',
        );
      }
      await Settings.setSessionExpiresAt(refreshedExpiresAt);
    } catch (error) {
      if (ApiClient.isAuthenticationFailure(error)) {
        await _invalidateAuthenticationOnce();
      }
      rethrow;
    }
  }

  @override
  void _handleAuthenticationFailure(ApiException error) {
    if (_disposed || !ApiClient.isAuthenticationFailure(error)) return;
    unawaited(_invalidateAuthenticationOnce());
  }

  @override
  Future<void> _invalidateAuthenticationOnce() {
    final existing = _authenticationInvalidationFuture;
    if (existing != null) return existing;
    final future = _invalidateAuthentication();
    _authenticationInvalidationFuture = future;
    future.then<void>(
      (_) {
        if (identical(_authenticationInvalidationFuture, future)) {
          _authenticationInvalidationFuture = null;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_authenticationInvalidationFuture, future)) {
          _authenticationInvalidationFuture = null;
        }
      },
    );
    return future;
  }

  Future<void> authenticate({
    required String unitName,
    required String realName,
    required String unitCode,
  }) {
    final existing = _authenticateFuture;
    if (existing != null) return existing;
    final future = _authenticateInternal(
      unitName: unitName,
      realName: realName,
      unitCode: unitCode,
    );
    _authenticateFuture = future;
    future.then<void>(
      (_) {
        if (identical(_authenticateFuture, future)) _authenticateFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_authenticateFuture, future)) _authenticateFuture = null;
      },
    );
    return future;
  }

  Future<void> _authenticateInternal({
    required String unitName,
    required String realName,
    required String unitCode,
  }) async {
    final unit = unitName.trim();
    final name = realName.trim();
    final code = unitCode.trim();
    if (unit.isEmpty) throw StateError('请输入单位名称');
    if (name.isEmpty) throw StateError('请输入真实姓名');
    if (code.isEmpty) throw StateError('请输入单位验证码');
    await _ensureApiReady();
    if (_disposed) throw StateError('应用控制器已释放');
    final bootstrap = ApiClient(
      baseUrl: await Settings.serverUrl,
      incidentId: '',
      deviceId: await OpLogService.instance.deviceId,
      actorName: name,
    );
    late final Map<String, dynamic> result;
    try {
      result = await bootstrap.verifyUnit(
        unitName: unit,
        unitCode: code,
        realName: name,
      );
    } finally {
      bootstrap.dispose();
    }
    final unitInfo = result['unit'] is Map
        ? Map<String, dynamic>.from(result['unit'] as Map)
        : <String, dynamic>{};
    final unitId = unitInfo['id']?.toString().trim() ?? '';
    if (unitId.isEmpty) throw StateError('单位认证响应无效，请稍后重试');
    // 兼容窗口内旧后端可能尚未签发会话令牌；一旦服务端启用强制会话，
    // 受保护探测会返回 SESSION_REQUIRED，随后按统一失效流程回到认证浮层。
    final sessionToken = result['session_token']?.toString().trim() ?? '';
    final sessionExpiresAt = _intValue(result['expires_at']);
    if (sessionToken.isEmpty || sessionExpiresAt <= 0) {
      throw StateError('单位认证响应缺少有效会话，请稍后重试');
    }

    // 在切换门禁和持久化前，使用本次令牌完成第一条受保护请求。
    final protectedProbe = ApiClient(
      baseUrl: await Settings.serverUrl,
      incidentId: '',
      deviceId: await OpLogService.instance.deviceId,
      actorName: name,
      unitId: unitId,
      unitCode: code,
      sessionToken: sessionToken,
    );
    try {
      await protectedProbe.fetchIncidents(status: 'active');
    } finally {
      protectedProbe.dispose();
    }

    // 单位验证码是当前部署的唯一人工认证凭据；认证成功后保存设备会话。
    final userRole = (result['user'] is Map)
        ? (result['user']['role']?.toString() ?? 'member')
        : 'member';
    await Settings.setMemberId(
      result['user'] is Map ? result['user']['id']?.toString() ?? '' : '',
    );
    await Settings.setUserRole(userRole);
    await Settings.setIsGuestMode(false);
    await Settings.clearPendingApplication();
    _isGuest = false;
    _enteredWithoutIncident = false;

    await Settings.setSessionToken(sessionToken);
    await Settings.setSessionExpiresAt(sessionExpiresAt);
    await Settings.setRealName(name);
    await Settings.setUnitId(unitId);
    await Settings.setUnitCode(code);
    await Settings.setUnitName(unitInfo['name']?.toString() ?? unit);
    orgDirectory.applySnapshot(
      roster: result['roster'] is Map
          ? Map<String, dynamic>.from(result['roster'] as Map)
          : null,
      stations: result.containsKey('stations') ? result['stations'] : null,
    );
    await _cacheRoster(unitId);
    await Settings.markModified(DateTime.now().millisecondsSinceEpoch);
    _protectedDataRevoked = false;
    _protectedDataEpoch++;
    _authenticated = true;
    await refreshConfig();
    _startAuthenticatedServices();
    await _realtimeStartFuture;
    _notify();
  }

  /// 进入游客模式：跳过强制登录门禁，使用本地单机功能
  Future<void> enterGuestMode() async {
    _revokeProtectedData();
    _isGuest = true;
    await Settings.setIsGuestMode(true);
    _initGuestIncident();
    _recomputeSyncing();
    unawaited(_ensureOptionalServices());
    _notify();
  }

  @override
  void _initGuestIncident() {
    final now = DateTime.now().millisecondsSinceEpoch;
    currentIncident = Incident(
      id: 'guest-drill-incident',
      number: '单机演练',
      title: '单机演练测试',
      status: 'active',
      createdAt: now,
      lastActivityAt: now,
    );
  }

  /// 申请加入单位：免登录提交入队申请
  Future<Map<String, dynamic>> applyUnitMembership({
    required String unitName,
    required String unitCode,
    required String realName,
    String? stationName,
    String? phone,
    String? applyReason,
  }) async {
    final bootstrap = ApiClient(
      baseUrl: await Settings.serverUrl,
      incidentId: '',
      deviceId: await OpLogService.instance.deviceId,
      actorName: realName.trim(),
    );
    try {
      final res = await bootstrap.applyUnitMembership(
        unitName: unitName,
        unitCode: unitCode,
        realName: realName,
        stationName: stationName,
        phone: phone,
        applyReason: applyReason,
      );
      await Settings.setPendingApplication(
        unitName: unitName,
        unitCode: unitCode,
        realName: realName,
        stationName: stationName,
        phone: phone,
      );
      return res;
    } finally {
      bootstrap.dispose();
    }
  }

  /// Shared unit inbox. Coalesce requests and repeat once if a sync event arrived in flight.
  Future<void> leaveUnit() async {
    _revokeProtectedData();
    _enteredWithoutIncident = false;
    final activeApi = api;
    await OpLogService.instance.flushLocal();
    _sessionGeneration++;
    await _syncCoordinator?.stop();
    _syncCoordinator = null;
    _realtimeStartFuture = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    _syncStarted = false;
    _syncSnapshotApplied = false;
    _syncFuture = null;
    _keepAliveFuture = null;
    _activeManualRefreshOps.clear();
    _manualRefreshInFlight = false;
    _activeLegacySyncOps.clear();
    _legacySyncInFlight = false;
    _recomputeSyncing();
    try {
      await activeApi?.logout();
    } catch (_) {
      // 注销的安全底线是本地凭据清理；网络不可用时服务端会话自然过期。
    }
    await _stopKeepAliveSafely();
    await _clearScheduledNotifications();

    _isGuest = false;
    _clearMemberReview();
    await Settings.setIsGuestMode(false);
    await Settings.setUserRole('member');
    await Settings.setCurrentIncidentId('');
    await Settings.setApiToken('');
    await Settings.setSessionToken('');
    await Settings.setSessionExpiresAt(0);
    await Settings.setRealName('');
    await Settings.setMemberId('');
    await Settings.setUnitId('');
    await Settings.setUnitCode('');
    await Settings.setUnitName('');
    await Settings.markModified(DateTime.now().millisecondsSinceEpoch);

    final previousApi = api;
    api = null;
    previousApi?.dispose();
    currentIncident = null;
    activeIncidents = [];
    entries = [];
    notes = [];
    forces = [];
    firefighters = [];
    hotwords = [];
    stations = [];
    await _clearRosterCache();
    await localAsr?.resetHotwords();
    _authenticated = false;
    _resetSessionHealth();
    await refreshConfig();
    _notify();
  }

  Future<void> _invalidateAuthentication() async {
    _revokeProtectedData();
    _enteredWithoutIncident = false;
    _sessionGeneration++;
    await _syncCoordinator?.stop();
    _syncCoordinator = null;
    _realtimeStartFuture = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    _syncStarted = false;
    _syncSnapshotApplied = false;
    _syncFuture = null;
    _keepAliveFuture = null;
    _activeManualRefreshOps.clear();
    _manualRefreshInFlight = false;
    _activeLegacySyncOps.clear();
    _legacySyncInFlight = false;
    _recomputeSyncing();
    await _stopKeepAliveSafely();
    await _clearScheduledNotifications();
    await Settings.setCurrentIncidentId('');
    await Settings.setApiToken('');
    await Settings.setSessionToken('');
    await Settings.setSessionExpiresAt(0);
    await Settings.setMemberId('');
    await Settings.setUnitId('');
    await Settings.setUnitCode('');
    final previousApi = api;
    api = null;
    previousApi?.dispose();
    currentIncident = null;
    activeIncidents = [];
    entries = [];
    notes = [];
    forces = [];
    firefighters = [];
    hotwords = [];
    stations = [];
    await _clearRosterCache();
    await localAsr?.resetHotwords();
    _authenticated = false;
    _resetSessionHealth();
    await refreshConfig();
    _notify();
  }

}
