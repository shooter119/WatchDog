import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/diagnostics/app_logger.dart';
import '../../../services/scoped_json_cache.dart';
import '../data/models/external_incident.dart';
import '../data/models/incident.dart';
import '../data/models/incident_force.dart';

/// 同步快照应用到 [IncidentStore] 后的变更摘要，供编排器联动清理关联域。
class IncidentSnapshotApplyResult {
  final bool currentIncidentCleared;
  const IncidentSnapshotApplyResult({this.currentIncidentCleared = false});
}

/// 实时同步事件应用到 [IncidentStore] 后的变更摘要，供编排器联动清理其他域。
class IncidentEventApplyResult {
  final bool handled;
  final bool currentIncidentCleared;
  const IncidentEventApplyResult({
    this.handled = false,
    this.currentIncidentCleared = false,
  });
}

/// 警情域状态容器（独立于其他 Feature Store，由编排器统一调度跨城事务）。
class IncidentStore extends ChangeNotifier {
  /// 外部警情本地缓存最大有效期（3 天），与原控制器不变量保持一致。
  static const int externalIncidentsCacheMaxAgeMs = 3 * 24 * 60 * 60 * 1000;
  static const String externalIncidentsCacheKind = 'external_incidents';
  static const String guestIncidentId = 'guest-drill-incident';

  final int Function() _nowMs;

  IncidentStore({@visibleForTesting int Function()? nowMs})
    : _nowMs = nowMs ?? _defaultNowMs;

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

  Incident? _currentIncident;
  List<Incident> _activeIncidents = [];
  List<ExternalIncident> _externalIncidents = [];
  bool _externalIncidentsLoading = false;
  Future<void>? _externalIncidentsInFlight;
  bool _externalReorganizing = false;
  List<IncidentForce> _forces = [];
  bool _disposed = false;

  Incident? get currentIncident => _currentIncident;
  List<Incident> get activeIncidents => _activeIncidents;
  List<ExternalIncident> get externalIncidents => _externalIncidents;
  bool get externalIncidentsLoading => _externalIncidentsLoading;
  bool get externalReorganizing => _externalReorganizing;
  List<IncidentForce> get forces => _forces;
  bool get disposed => _disposed;
  bool get hasCurrentIncident => _currentIncident != null;

  List<String> get externalIncidentIds => _externalIncidents
      .map((e) => e.externalId)
      .where((id) => id.isNotEmpty)
      .toList();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 初始化游客模式本地演练警情。
  Incident initGuestIncident({bool notify = true}) {
    final now = _nowMs();
    final incident = Incident(
      id: guestIncidentId,
      number: '单机演练',
      title: '单机演练测试',
      status: 'active',
      createdAt: now,
      lastActivityAt: now,
    );
    _currentIncident = incident;
    if (notify) _notify();
    return incident;
  }

  void setCurrentIncident(
    Incident? incident, {
    List<IncidentForce>? forces,
    bool notify = true,
  }) {
    _currentIncident = incident;
    if (forces != null) _forces = forces;
    if (notify) _notify();
  }

  void setActiveIncidents(List<Incident> incidents, {bool notify = true}) {
    _activeIncidents = incidents;
    if (notify) _notify();
  }

  void setForces(List<IncidentForce> nextForces, {bool notify = true}) {
    _forces = nextForces;
    if (notify) _notify();
  }

  void setExternalIncidents(
    List<ExternalIncident> incidents, {
    bool notify = true,
  }) {
    _externalIncidents = incidents;
    if (notify) _notify();
  }

  void setExternalIncidentsLoading(bool loading, {bool notify = true}) {
    _externalIncidentsLoading = loading;
    if (notify) _notify();
  }

  void setExternalReorganizing(bool reorganizing, {bool notify = true}) {
    _externalReorganizing = reorganizing;
    if (notify) _notify();
  }

  /// 选定/新建/认领警情后原子落位本地选中态，置顶活跃列表并按需清空旧参战力量。
  void selectLocalIncident(
    Incident incident, {
    bool clearForces = true,
    bool notify = true,
  }) {
    _currentIncident = incident;
    _activeIncidents = [
      incident,
      ..._activeIncidents.where((item) => item.id != incident.id),
    ];
    if (clearForces) _forces = [];
    if (notify) _notify();
  }

  /// 清空当前警情及其参战力量（归档、退出警情、失效警情回退等场景）。
  void clearCurrentIncident({bool notify = true}) {
    _currentIncident = null;
    _forces = [];
    if (notify) _notify();
  }

  /// 仅当当前警情 ID 命中 [incidentId] 时原子清空（用于过期 bootstrap 回调）。
  bool clearCurrentIncidentIfMatches(String incidentId, {bool notify = true}) {
    if (_currentIncident?.id != incidentId) return false;
    _currentIncident = null;
    _forces = [];
    if (notify) _notify();
    return true;
  }

  /// 应用单个更新后的警情实体（重命名、重点单位关联变更等）。
  void applyUpdatedIncident(
    Incident updated, {
    bool updateActiveList = true,
    bool notify = true,
  }) {
    if (_currentIncident?.id == updated.id) _currentIncident = updated;
    if (updateActiveList) {
      _activeIncidents = _activeIncidents
          .map((item) => item.id == updated.id ? updated : item)
          .toList();
    }
    if (notify) _notify();
  }

  /// 原子刷新当前警情与参战力量（灾情等级变更、参战力量增删改、详情刷新）。
  void applyIncidentAndForces({
    required Incident incident,
    required List<IncidentForce> forces,
    bool updateActiveList = false,
    bool notify = true,
  }) {
    _currentIncident = incident;
    _forces = forces;
    if (updateActiveList) {
      _activeIncidents = _activeIncidents
          .map((item) => item.id == incident.id ? incident : item)
          .toList();
    }
    if (notify) _notify();
  }

  /// 受保护数据吊销时立即清理外部警情及在途任务句柄。
  void revokeProtectedData({bool notify = true}) {
    _externalIncidents = [];
    _externalIncidentsLoading = false;
    _externalIncidentsInFlight = null;
    _externalReorganizing = false;
    if (notify) _notify();
  }

  /// 退出单位或认证失效时的全量原子重置。
  void resetAll({bool notify = true}) {
    _currentIncident = null;
    _activeIncidents = [];
    _forces = [];
    revokeProtectedData(notify: false);
    if (notify) _notify();
  }

  /// 应用实时同步全量快照中的警情与参战力量片段。
  IncidentSnapshotApplyResult applySyncSnapshot(
    Map<String, dynamic> snapshot, {
    bool notify = true,
  }) {
    var currentIncidentCleared = false;
    final active = snapshot['active_incidents'] as List? ?? const [];
    _activeIncidents = active
        .whereType<Map>()
        .map((item) => Incident.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final incidentSnapshot = snapshot['incident_snapshot'];
    if (incidentSnapshot is Map) {
      final data = Map<String, dynamic>.from(incidentSnapshot);
      final incident = data['incident'];
      _currentIncident = incident is Map
          ? Incident.fromJson(Map<String, dynamic>.from(incident))
          : _currentIncident;
      _forces = (data['forces'] as List? ?? const [])
          .whereType<Map>()
          .map((f) => IncidentForce.fromJson(Map<String, dynamic>.from(f)))
          .toList();
    } else if ((snapshot['cursors'] as Map?)?['incident'] == '0') {
      _currentIncident = null;
      _forces = [];
      currentIncidentCleared = true;
    }
    if (notify) _notify();
    return IncidentSnapshotApplyResult(
      currentIncidentCleared: currentIncidentCleared,
    );
  }

  /// 应用与警情/参战力量相关的增量同步事件。
  IncidentEventApplyResult applySyncEvent({
    required String eventType,
    required Map<String, dynamic> payload,
    String? aggregateId,
    bool notify = true,
  }) {
    var handled = false;
    var currentIncidentCleared = false;
    switch (eventType) {
      case 'incident.created':
      case 'incident.updated':
      case 'incident.archived':
        if (payload.isEmpty) break;
        final incident = Incident.fromJson(payload);
        _activeIncidents = [
          if (incident.isActive) incident,
          ..._activeIncidents.where((item) => item.id != incident.id),
        ];
        if (_currentIncident?.id == incident.id) {
          _currentIncident = incident.isActive ? incident : null;
          if (!incident.isActive) {
            _forces = [];
            currentIncidentCleared = true;
          }
        }
        handled = true;
      case 'import.applied':
        if (payload['incident'] is Map) {
          final incident = Incident.fromJson(
            Map<String, dynamic>.from(payload['incident'] as Map),
          );
          if (_currentIncident?.id == incident.id) {
            _currentIncident = incident;
            _forces = (payload['forces'] as List? ?? const [])
                .whereType<Map>()
                .map((f) => IncidentForce.fromJson(Map<String, dynamic>.from(f)))
                .toList();
          }
          handled = true;
        }
      case 'force.upserted':
        if (payload.isEmpty) break;
        final force = IncidentForce.fromJson(payload);
        _forces = [force, ..._forces.where((item) => item.id != force.id)];
        handled = true;
      case 'force.deleted':
        final id = aggregateId ?? payload['id']?.toString();
        if (id != null) {
          _forces = _forces.where((item) => item.id != id).toList();
          handled = true;
        }
    }
    if (handled && notify) _notify();
    return IncidentEventApplyResult(
      handled: handled,
      currentIncidentCleared: currentIncidentCleared,
    );
  }

  /// 从 `ScopedJsonCache` 冷启动秒级预恢复外部警情列表。
  /// 严格校验 `protectedDataEpoch`、`sessionGeneration` 与 3 天过期窗口。
  Future<bool> restoreCachedExternalIncidents({
    required String cacheScope,
    required int Function() protectedDataEpoch,
    required int Function() sessionGeneration,
    bool Function()? isStillCurrent,
    bool notify = true,
  }) async {
    if (_disposed ||
        cacheScope.isEmpty ||
        _externalIncidents.isNotEmpty ||
        !(isStillCurrent?.call() ?? true)) {
      return false;
    }
    final epoch = protectedDataEpoch();
    final generation = sessionGeneration();
    try {
      final cached = await ScopedJsonCache.read(
        cacheScope,
        externalIncidentsCacheKind,
      );
      if (_disposed ||
          _externalIncidents.isNotEmpty ||
          epoch != protectedDataEpoch() ||
          generation != sessionGeneration() ||
          !(isStillCurrent?.call() ?? true)) {
        return false;
      }
      if (cached is! Map) return false;
      final savedAt = (cached['saved_at'] as num?)?.toInt() ?? 0;
      if (savedAt > 0 && _nowMs() - savedAt > externalIncidentsCacheMaxAgeMs) {
        return false;
      }
      final rawList = cached['list'];
      if (rawList is! List || rawList.isEmpty) return false;
      final restored = rawList
          .whereType<Map>()
          .map((m) => ExternalIncident.fromJson(Map<String, dynamic>.from(m)))
          .where((item) => item.externalId.isNotEmpty)
          .toList();
      if (restored.isEmpty) return false;
      _externalIncidents = restored;
      if (notify) _notify();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 将外部警情列表按当前时间写入作用域隔离缓存。
  Future<void> saveCachedExternalIncidents({
    required String cacheScope,
    List<ExternalIncident>? incidents,
  }) async {
    if (cacheScope.isEmpty) return;
    final list = incidents ?? _externalIncidents;
    await ScopedJsonCache.write(cacheScope, externalIncidentsCacheKind, {
      'saved_at': _nowMs(),
      'list': list.map((e) => e.toJson()).toList(),
    });
  }

  /// 拉取外部官方警情：合并非强制在途请求、冷启动缓存预恢复与代际防乱序写回。
  Future<void> fetchExternalIncidents({
    bool forceRefresh = false,
    required Future<List<ExternalIncident>> Function(bool refresh) fetcher,
    required String Function() resolveCacheScope,
    required int Function() protectedDataEpoch,
    required int Function() sessionGeneration,
    Future<void> Function()? prepare,
    bool Function()? isStillCurrent,
  }) async {
    if (_disposed || !(isStillCurrent?.call() ?? true)) return;
    if (!forceRefresh && _externalIncidentsInFlight != null) {
      return _externalIncidentsInFlight!;
    }
    late final Future<void> task;
    task = () async {
      try {
        if (prepare != null) await prepare();
        if (_disposed || !(isStillCurrent?.call() ?? true)) return;
        final epoch = protectedDataEpoch();
        final generation = sessionGeneration();
        bool sameEpoch() =>
            !_disposed &&
            epoch == protectedDataEpoch() &&
            generation == sessionGeneration();
        bool valid() => sameEpoch() && (isStillCurrent?.call() ?? true);

        final cacheScope = resolveCacheScope();
        if (_externalIncidents.isEmpty && cacheScope.isNotEmpty) {
          await restoreCachedExternalIncidents(
            cacheScope: cacheScope,
            protectedDataEpoch: protectedDataEpoch,
            sessionGeneration: sessionGeneration,
            isStillCurrent: isStillCurrent,
          );
        }
        if (!valid()) return;
        _externalIncidentsLoading = true;
        _notify();
        try {
          final list = await fetcher(forceRefresh);
          if (!valid()) return;
          _externalIncidents = list;
          if (cacheScope.isNotEmpty) {
            unawaited(
              saveCachedExternalIncidents(
                cacheScope: cacheScope,
                incidents: list,
              ),
            );
          }
        } catch (error) {
          AppLogger.error('WatchDog fetchExternalIncidents failed', tag: 'incident', error: error);
        } finally {
          if (sameEpoch()) {
            _externalIncidentsLoading = false;
            _notify();
          }
        }
      } finally {
        if (identical(_externalIncidentsInFlight, task)) {
          _externalIncidentsInFlight = null;
        }
      }
    }();
    _externalIncidentsInFlight = task;
    return task;
  }

  /// AI 重整当前外部警情列表，保留防重入与状态回滚保护。
  Future<void> reorganizeExternalIncidents({
    required Future<List<ExternalIncident>> Function(List<String> externalIds)
    reorganizer,
    String Function()? resolveCacheScope,
    int Function()? protectedDataEpoch,
    int Function()? sessionGeneration,
    bool Function()? isStillCurrent,
  }) async {
    if (_disposed ||
        _externalReorganizing ||
        !(isStillCurrent?.call() ?? true)) {
      return;
    }
    final epoch = protectedDataEpoch?.call();
    final generation = sessionGeneration?.call();
    _externalReorganizing = true;
    _notify();
    try {
      final list = await reorganizer(externalIncidentIds);
      if (_disposed ||
          (epoch != null && epoch != protectedDataEpoch!()) ||
          (generation != null && generation != sessionGeneration!()) ||
          !(isStillCurrent?.call() ?? true)) {
        return;
      }
      _externalIncidents = list;
      final cacheScope = resolveCacheScope?.call() ?? '';
      if (cacheScope.isNotEmpty) {
        unawaited(
          saveCachedExternalIncidents(cacheScope: cacheScope, incidents: list),
        );
      }
    } catch (error) {
      AppLogger.error('WatchDog reorganizeExternalIncidents failed', tag: 'incident', error: error);
      rethrow;
    } finally {
      final wasReorganizing = _externalReorganizing;
      _externalReorganizing = false;
      if (wasReorganizing) _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _externalIncidentsInFlight = null;
    super.dispose();
  }
}
