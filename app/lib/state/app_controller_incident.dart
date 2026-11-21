part of 'app_controller.dart';

mixin _AppControllerIncidentMixin on _AppControllerBase {
  Future<void> changeKeySiteLink(
    String incidentId, {
    required int revision,
    required String operationId,
    KeySiteVersion? site,
  }) async {
    final activeApi = api;
    final epoch = protectedDataEpoch;
    if (!canReadKeySites || activeApi == null) throw StateError('请重新认证');
    final updated = await activeApi.changeIncidentKeySite(
      incidentId,
      revision: revision,
      operationId: operationId,
      site: site,
    );
    if (!canReadKeySites || api != activeApi || epoch != protectedDataEpoch) {
      return;
    }
    if (currentIncident?.id == incidentId) currentIncident = updated;
    activeIncidents = activeIncidents
        .map((item) => item.id == incidentId ? updated : item)
        .toList();
    _notify();
  }

  /// 主动退出当前单位：清理本机认证信息和当前警情，回到启动认证浮层。
  Future<void> selectIncident(String id, {Incident? knownIncident}) async {
    await _refreshSession();
    if (needsAuthentication) throw StateError('认证会话已过期，请重新认证');
    await Settings.setCurrentIncidentId(id);
    _enteredWithoutIncident = false;
    _sessionGeneration++;
    _syncFuture = null;
    _keepAliveFuture = null;
    unawaited(_clearScheduledNotifications());
    _resetSessionHealth();
    // 列表或新建冲突响应已经带回了完整警情档案。先完成本机选择，
    // 详细人员/日志数据放到后台同步，避免网络抖动阻塞“加入警情”这个动作。
    if (knownIncident != null) {
      currentIncident = knownIncident;
      activeIncidents = [
        knownIncident,
        ...activeIncidents.where((item) => item.id != knownIncident.id),
      ];
      entries = [];
      notes = [];
      forces = [];
      _recomputeSyncing();
      _notify();
    }
    await refreshConfig();
    if (_disposed) return;
    unawaited(syncKeepAlive());
    if (knownIncident != null) {
      if (!_syncStarted) {
        if (_authenticated) {
          startSync();
        } else {
          unawaited(sync());
        }
      }
      return;
    }
    if (_authenticated) {
      if (!_syncStarted) {
        startSync();
      }
      await (_realtimeStartFuture ?? Future<void>.value());
    } else {
      await sync();
    }
  }

  Future<Incident> createIncident() async {
    final name = await Settings.realName;
    if (name.isEmpty) throw StateError('请先在设置中填写真实姓名');
    await _ensureApiReady();
    await _refreshSession();
    if (needsAuthentication) throw StateError('认证会话已过期，请重新认证');
    // 新建警情是核心链路，不能因为启动时某个可选插件失败而没有
    // ApiClient。按当前设置现场补建客户端，确保请求得到真实的网络/服务端错误。
    final a = api ??= ApiClient(
      baseUrl: await Settings.serverUrl,
      incidentId: await Settings.currentIncidentId,
      sessionToken: await Settings.sessionToken,
      deviceId: await OpLogService.instance.deviceId,
      actorName: name,
      unitId: await Settings.unitId,
      unitCode: await Settings.unitCode,
      onAuthenticationFailure: _handleAuthenticationFailure,
    );
    final opId = 'incident-create-${DateTime.now().microsecondsSinceEpoch}';
    AppLogger.log(
      'WatchDog createIncident: api=ready, actor=configured, op_id=$opId',
      tag: 'incident',
    );
    late final Incident incident;
    try {
      incident = await a.createIncident(realName: name, opId: opId);
    } catch (error) {
      final requestId = error is ApiException ? error.requestId : null;
      OpLogService.instance.record(
        opId,
        'incident_create_fail',
        '新建警情失败: $error',
        level: 'error',
        data: {
          if (requestId != null && requestId.isNotEmpty)
            'request_id': requestId,
        },
      );
      if (ApiClient.isAuthenticationFailure(error)) {
        await _invalidateAuthenticationOnce();
      }
      rethrow;
    }
    await Settings.setCurrentIncidentId(incident.id);
    _enteredWithoutIncident = false;
    currentIncident = incident;
    activeIncidents = [
      incident,
      ...activeIncidents.where((item) => item.id != incident.id),
    ];
    entries = [];
    notes = [];
    forces = [];
    _sessionGeneration++;
    _syncFuture = null;
    _keepAliveFuture = null;
    unawaited(_clearScheduledNotifications());
    _resetSessionHealth();
    _recomputeSyncing();
    _notify();
    await refreshConfig();
    if (_disposed) return incident;
    unawaited(syncKeepAlive());
    if (!_syncStarted) {
      if (_authenticated) {
        startSync();
      } else {
        await sync();
      }
    }
    return incident;
  }

  Future<Incident> renameCurrent(String title) async {
    final incident = currentIncident;
    final a = api;
    if (incident == null || a == null) throw StateError('未选择警情');
    final updated = await a.updateIncidentTitle(
      incident.id,
      title.trim().isEmpty ? null : title.trim(),
      expectedVersion: incident.version,
    );
    currentIncident = updated;
    _notify();
    return updated;
  }

  Future<void> archiveCurrent() async {
    final a = api;
    if (a == null || currentIncident == null) throw StateError('未选择警情');
    await a.archiveIncident(currentIncident!.id);
    await Settings.setCurrentIncidentId('');
    _sessionGeneration++;
    _syncFuture = null;
    _keepAliveFuture = null;
    _enteredWithoutIncident = true;
    currentIncident = null;
    entries = [];
    notes = [];
    forces = [];
    unawaited(_clearScheduledNotifications());
    _resetSessionHealth();
    _recomputeSyncing();
    _notify();
    await refreshConfig();
    if (_disposed) return;
    unawaited(syncKeepAlive());
    if (!_syncStarted) {
      if (_authenticated) {
        startSync();
      } else {
        await sync();
      }
    }
  }

  /// 退出当前警情只清除本机选择，不归档服务器档案；之后仍可从活跃列表重新加入。
  Future<void> exitCurrentIncident() async {
    if (currentIncident == null) return;
    await Settings.setCurrentIncidentId('');
    _sessionGeneration++;
    _syncFuture = null;
    _keepAliveFuture = null;
    _enteredWithoutIncident = true;
    currentIncident = null;
    entries = [];
    notes = [];
    forces = [];
    unawaited(_clearScheduledNotifications());
    _resetSessionHealth();
    _recomputeSyncing();
    _notify();
    await refreshConfig();
    if (_disposed) return;
    unawaited(syncKeepAlive());
    if (!_syncStarted) {
      if (_authenticated) {
        startSync();
      } else {
        await sync();
      }
    }
  }

  @override
  Future<void> refreshIncidentData(String id) async {
    final a = api;
    if (a == null || currentIncident?.id != id) return;
    final incident = await a.fetchIncident(id);
    final rows = await a.fetchIncidentForces();
    if (!identical(api, a) || currentIncident?.id != id || _disposed) return;
    currentIncident = incident;
    forces = rows;
    _notify();
  }

  Future<void> updateIncidentLevel(
    String level, {
    String? disasterCategory,
  }) async {
    final a = api;
    final incident = currentIncident;
    if (a == null || incident == null) throw StateError('未选择警情');
    final value = level.trim();
    if (value.isEmpty || value.length > 80) {
      throw const FormatException('灾情等级须为1至80字');
    }
    final scoped = a.forIncident(incident.id);
    try {
      final detail = await scoped.fetchIncidentDetails();
      final data = Map<String, dynamic>.from(detail['data'] as Map? ?? {});
      final version = (detail['version'] as num?)?.toInt() ?? 0;
      if (disasterCategory != null && disasterCategory.trim().isNotEmpty) {
        data['disaster_category'] = disasterCategory.trim();
      } else {
        data.remove('disaster_category');
      }
      await scoped.updateIncidentDetails(
        {
          ...data,
          'original_category': value,
          'level': value,
        },
        version,
        'incident-level-${DateTime.now().microsecondsSinceEpoch}',
      );
    } finally {
      if (!identical(scoped, a)) scoped.dispose();
    }
    if (!identical(api, a) || currentIncident?.id != incident.id) return;
    final updated = await a.fetchIncident(incident.id);
    final rows = await a.fetchIncidentForces();
    if (!identical(api, a) || currentIncident?.id != incident.id || _disposed) {
      return;
    }
    currentIncident = updated;
    forces = rows;
    _notify();
  }

  Future<void> saveForce({
    String? forceId,
    required String stationName,
    String? stationId,
    String? unitStationId,
    required int vehicleCount,
    required int personnelCount,
    bool vehicleCountKnown = true,
    bool personnelCountKnown = true,
    int? expectedVersion,
  }) async {
    final a = api;
    if (a == null || currentIncident == null) throw StateError('未选择警情');
    await a.saveIncidentForce(
      forceId: forceId,
      stationName: stationName,
      stationId: stationId,
      vehicleCount: vehicleCount,
      personnelCount: personnelCount,
      expectedVersion: expectedVersion,
    );
    forces = await a.fetchIncidentForces();
    currentIncident = await a.fetchIncident(currentIncident!.id);
    _notify();
  }

  Future<void> removeForce(String forceId) async {
    final a = api;
    if (a == null || currentIncident == null) throw StateError('未选择警情');
    await a.deleteIncidentForce(forceId);
    forces = await a.fetchIncidentForces();
    currentIncident = await a.fetchIncident(currentIncident!.id);
    _notify();
  }

  Future<List<Incident>> archivedIncidents() async {
    final a = api;
    if (a == null) return [];
    return a.fetchIncidents(status: 'archived');
  }

  Future<Incident> renameIncident(Incident incident, String title) async {
    final a = api;
    if (a == null) throw StateError('未连接服务器');
    return a.updateIncidentTitle(
      incident.id,
      title.trim().isEmpty ? null : title.trim(),
      expectedVersion: incident.version,
    );
  }

  /// 新增火场随手记（语音分流自动入日志 / 手动添加）。
  /// 实名作者随请求直接提交（本地实名立即生效，不依赖服务器 user_settings 同步）。
}
