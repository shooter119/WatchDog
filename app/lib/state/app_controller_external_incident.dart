part of 'app_controller.dart';

const int _externalIncidentsCacheMaxAgeMs = 3 * 24 * 60 * 60 * 1000;

mixin _AppControllerExternalIncidentMixin on _AppControllerBase {
  @override
  Future<void> _restoreCachedExternalIncidents({ApiClient? targetApi}) async {
    if (_disposed || needsAuthentication || externalIncidents.isNotEmpty) {
      return;
    }
    final a = targetApi ?? api;
    if (a == null || a.cacheScope.isEmpty) return;
    final epoch = _protectedDataEpoch;
    final generation = _sessionGeneration;
    try {
      final cached = await ScopedJsonCache.read(
        a.cacheScope,
        'external_incidents',
      );
      if (_disposed ||
          needsAuthentication ||
          !identical(api, a) ||
          epoch != _protectedDataEpoch ||
          generation != _sessionGeneration ||
          externalIncidents.isNotEmpty) {
        return;
      }
      if (cached is! Map) return;
      final savedAt = (cached['saved_at'] as num?)?.toInt() ?? 0;
      if (savedAt > 0 && _nowMs() - savedAt > _externalIncidentsCacheMaxAgeMs) {
        return;
      }
      final rawList = cached['list'];
      if (rawList is! List || rawList.isEmpty) return;
      final restored = rawList
          .whereType<Map>()
          .map((item) => ExternalIncident.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.externalId.isNotEmpty)
          .toList();
      if (restored.isEmpty) return;
      externalIncidents = restored;
      _notify();
    } catch (_) {
      // 本地缓存损坏时静默忽略，交由后续网络刷新覆盖
    }
  }

  @override
  Future<void> fetchExternalIncidents({bool forceRefresh = false}) async {
    if (_disposed || needsAuthentication) return;
    if (!forceRefresh && _externalIncidentsInFlight != null) {
      return _externalIncidentsInFlight!;
    }
    late final Future<void> task;
    task = () async {
      await _ensureApiReady();
      final a = api;
      if (_disposed || needsAuthentication || a == null) return;
      final epoch = _protectedDataEpoch;
      final generation = _sessionGeneration;
      if (externalIncidents.isEmpty) {
        await _restoreCachedExternalIncidents(targetApi: a);
      }
      if (_disposed ||
          needsAuthentication ||
          !identical(api, a) ||
          epoch != _protectedDataEpoch ||
          generation != _sessionGeneration) {
        return;
      }
      externalIncidentsLoading = true;
      _notify();
      try {
        final list = await a.fetchExternalIncidents(refresh: forceRefresh);
        if (_disposed ||
            needsAuthentication ||
            !identical(api, a) ||
            epoch != _protectedDataEpoch ||
            generation != _sessionGeneration) {
          return;
        }
        externalIncidents = list;
        if (a.cacheScope.isNotEmpty) {
          unawaited(
            ScopedJsonCache.write(a.cacheScope, 'external_incidents', {
              'saved_at': _nowMs(),
              'list': list.map((e) => e.toJson()).toList(),
            }),
          );
        }
      } catch (error) {
        AppLogger.error('WatchDog fetchExternalIncidents failed', tag: 'incident', error: error);
      } finally {
        if (identical(_externalIncidentsInFlight, task)) {
          _externalIncidentsInFlight = null;
        }
        if (!_disposed &&
            epoch == _protectedDataEpoch &&
            generation == _sessionGeneration) {
          externalIncidentsLoading = false;
          _notify();
        }
      }
    }();
    _externalIncidentsInFlight = task;
    return task;
  }

  Future<void> reorganizeExternalIncidents() async {
    if (needsAuthentication || externalReorganizing) return;
    await _ensureApiReady();
    final a = api;
    if (a == null) return;
    externalReorganizing = true;
    _notify();
    try {
      final ids = externalIncidents
          .map((e) => e.externalId)
          .where((id) => id.isNotEmpty)
          .toList();
      final list = await a.reorganizeExternalIncidents(externalIds: ids);
      externalIncidents = list;
    } catch (error) {
      AppLogger.error('WatchDog reorganizeExternalIncidents failed', tag: 'incident', error: error);
      rethrow;
    } finally {
      externalReorganizing = false;
      _notify();
    }
  }

  Future<Incident> claimExternalIncident(ExternalIncident externalIncident) async {
    final name = await Settings.realName;
    if (name.isEmpty) throw StateError('请先在设置中填写真实姓名');
    await _ensureApiReady();
    await _refreshSession();
    if (needsAuthentication) throw StateError('认证会话已过期，请重新认证');
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
    final opId = 'incident-claim-${DateTime.now().microsecondsSinceEpoch}';
    AppLogger.log('WatchDog claimExternalIncident: op_id=$opId external_id=${externalIncident.externalId}', tag: 'incident');
    late final Incident incident;
    try {
      incident = await a.claimExternalIncident(
        externalIncident,
        realName: name,
        opId: opId,
      );
    } catch (error) {
      final requestId = error is ApiException ? error.requestId : null;
      OpLogService.instance.record(
        opId,
        'incident_claim_fail',
        '认领警情失败: $error',
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
    if (externalIncidents.isNotEmpty) {
      final targetExtId = externalIncident.externalId.trim();
      final targetExtNum = externalIncident.incidentNumber.trim();
      var updatedExternal = false;
      final nextExternal = externalIncidents.map((item) {
        final sameExtId =
            targetExtId.isNotEmpty && item.externalId.trim() == targetExtId;
        final sameExtNum =
            targetExtNum.isNotEmpty &&
            item.incidentNumber.trim() == targetExtNum;
        if (!sameExtId && !sameExtNum) return item;
        updatedExternal = true;
        return item.copyWithClaimed(
          claimed: true,
          claimedIncidentId: incident.id,
          claimedIncidentNumber: incident.number,
          claimedIncidentTitle: incident.displayName,
        );
      }).toList();
      if (updatedExternal) {
        externalIncidents = nextExternal;
        if (a.cacheScope.isNotEmpty) {
          unawaited(
            ScopedJsonCache.write(a.cacheScope, 'external_incidents', {
              'saved_at': _nowMs(),
              'list': nextExternal.map((e) => e.toJson()).toList(),
            }),
          );
        }
      }
    }
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

}
