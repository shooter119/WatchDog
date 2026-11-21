import '../../core/network/network.dart';
import '../../features/auth/state/session_store.dart';
import '../../features/incident/data/incident_import_repository.dart';
import '../../features/incident/data/incident_repository.dart';
import '../../features/incident/data/models/external_incident.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/incident/state/incident_store.dart';
import '../../services/op_log_service.dart';
import '../../services/settings.dart';
import 'orchestrator_contracts.dart';

/// 校验实名与认证会话就绪状态，返回当前实名供创建/认领警情使用。
Future<String> requireAuthenticatedActor({
  required SessionStore sessionStore,
  required Future<void> Function() ensureSessionReady,
  required Future<void> Function({bool force}) refreshSession,
}) async {
  final name = await Settings.realName;
  if (name.isEmpty) throw StateError('请先在设置中填写真实姓名');
  await ensureSessionReady();
  await refreshSession();
  if (sessionStore.needsAuthentication) {
    throw StateError('认证会话已过期，请重新认证');
  }
  return name;
}

/// 委托 [IncidentStore] 拉取外部官方警情并绑定会话代际防乱序。
Future<void> fetchExternalIncidentsWithGuard({
  required bool forceRefresh,
  required SessionStore sessionStore,
  required IncidentStore incidentStore,
  required IncidentOrchestratorConfig config,
  required bool Function() isNotDisposed,
}) => incidentStore.fetchExternalIncidents(
  forceRefresh: forceRefresh,
  prepare: config.ensureSessionReady,
  fetcher: (refresh) {
    final transport = config.readTransport();
    if (transport == null) return Future.value(const <ExternalIncident>[]);
    return IncidentRepository(transport).fetchExternalIncidents(refresh: refresh);
  },
  resolveCacheScope: () => sessionStore.config?.cacheScope ?? '',
  protectedDataEpoch: () => sessionStore.protectedDataEpoch,
  sessionGeneration: config.readSessionGeneration,
  isStillCurrent: () =>
      isNotDisposed() &&
      !sessionStore.needsAuthentication &&
      config.readTransport() != null,
);

/// 委托 [IncidentStore] 触发 AI 重整外部警情列表。
Future<void> reorganizeExternalIncidentsWithGuard({
  required SessionStore sessionStore,
  required IncidentStore incidentStore,
  required IncidentOrchestratorConfig config,
  required bool Function() isNotDisposed,
}) async {
  if (sessionStore.needsAuthentication) return;
  await config.ensureSessionReady();
  final transport = config.readTransport();
  if (transport == null) return;
  await incidentStore.reorganizeExternalIncidents(
    reorganizer: (ids) => IncidentRepository(
      transport,
    ).reorganizeExternalIncidents(externalIds: ids),
    resolveCacheScope: () => sessionStore.config?.cacheScope ?? '',
    protectedDataEpoch: () => sessionStore.protectedDataEpoch,
    sessionGeneration: config.readSessionGeneration,
    isStillCurrent: () => isNotDisposed() && !sessionStore.needsAuthentication,
  );
}

/// 以当前活跃传输层（或按设置临时补建的传输层）执行警情创建/认领写入，
/// 统一记录失败操作日志并在鉴权失效时触发并发去重吊销。
Future<Incident> runIncidentWriteWithFallback({
  required ApiHttpTransport? existingTransport,
  required ApiTransportFactory transportFactory,
  required String actorName,
  required String opId,
  required String failStage,
  required String failLabel,
  required Future<void> Function() onInvalidateAuthentication,
  required Future<Incident> Function(IncidentRepository repo) action,
}) async {
  ApiHttpTransport? temporary;
  final active = existingTransport ??
      (temporary = transportFactory(
        ApiConfig(
          baseUrl: await Settings.serverUrl,
          incidentId: await Settings.currentIncidentId,
          sessionToken: await Settings.sessionToken,
          deviceId: await OpLogService.instance.deviceId,
          actorName: actorName,
          unitId: await Settings.unitId,
          unitCode: await Settings.unitCode,
        ),
      ));
  try {
    return await action(IncidentRepository(active));
  } catch (error) {
    final requestId = error is ApiException ? error.requestId : null;
    OpLogService.instance.record(
      opId,
      failStage,
      '$failLabel: $error',
      level: 'error',
      data: {
        if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
      },
    );
    if (isApiAuthenticationFailure(error)) {
      await onInvalidateAuthentication();
    }
    rethrow;
  } finally {
    temporary?.dispose();
  }
}

/// 带会话与当前警情校验的警情实体 + 参战力量刷新。
Future<void> refreshIncidentAndForces({
  required String incidentId,
  required ApiHttpTransport? transport,
  required IncidentStore incidentStore,
  required bool Function() isStillCurrent,
}) async {
  if (transport == null || incidentStore.currentIncident?.id != incidentId) {
    return;
  }
  final repo = IncidentRepository(transport);
  final incident = await repo.fetchIncident(incidentId);
  final forces = await repo.fetchIncidentForces(forIncidentId: incidentId);
  if (!isStillCurrent() || incidentStore.currentIncident?.id != incidentId) {
    return;
  }
  incidentStore.applyIncidentAndForces(incident: incident, forces: forces);
}

/// 更新灾情等级与类别并刷新当前警情与参战力量。
Future<void> updateIncidentLevelAndReload({
  required String level,
  String? disasterCategory,
  required ApiHttpTransport? transport,
  required ApiConfig? activeConfig,
  required ApiTransportFactory transportFactory,
  required IncidentStore incidentStore,
  required int nowMs,
  required bool Function() isStillCurrent,
}) async {
  final incident = incidentStore.currentIncident;
  if (transport == null || incident == null || activeConfig == null) {
    throw StateError('未选择警情');
  }
  final value = level.trim();
  if (value.isEmpty || value.length > 80) {
    throw const FormatException('灾情等级须为1至80字');
  }
  final scoped = transportFactory(activeConfig.forIncident(incident.id));
  try {
    final importRepo = IncidentImportRepository(scoped);
    final detail = await importRepo.fetchIncidentDetails();
    final data = Map<String, dynamic>.from(detail['data'] as Map? ?? {});
    final version = (detail['version'] as num?)?.toInt() ?? 0;
    if (disasterCategory != null && disasterCategory.trim().isNotEmpty) {
      data['disaster_category'] = disasterCategory.trim();
    } else {
      data.remove('disaster_category');
    }
    await importRepo.updateIncidentDetails(
      {...data, 'original_category': value, 'level': value},
      version,
      'incident-level-$nowMs',
    );
  } finally {
    scoped.dispose();
  }
  if (!isStillCurrent()) return;
  await refreshIncidentAndForces(
    incidentId: incident.id,
    transport: transport,
    incidentStore: incidentStore,
    isStillCurrent: isStillCurrent,
  );
}

/// 新增或更新当前警情参战力量并刷新本地态。
Future<void> saveIncidentForceAndReload({
  required ApiHttpTransport? transport,
  required IncidentStore incidentStore,
  required bool Function() isStillCurrent,
  String? forceId,
  required String stationName,
  String? stationId,
  required int vehicleCount,
  required int personnelCount,
  int? expectedVersion,
}) async {
  final incident = incidentStore.currentIncident;
  if (transport == null || incident == null) throw StateError('未选择警情');
  final repo = IncidentRepository(transport);
  await repo.saveIncidentForce(
    forceId: forceId,
    stationName: stationName,
    stationId: stationId,
    vehicleCount: vehicleCount,
    personnelCount: personnelCount,
    expectedVersion: expectedVersion,
  );
  if (!isStillCurrent()) return;
  await refreshIncidentAndForces(
    incidentId: incident.id,
    transport: transport,
    incidentStore: incidentStore,
    isStillCurrent: isStillCurrent,
  );
}

/// 删除当前警情参战力量并刷新本地态。
Future<void> removeIncidentForceAndReload({
  required String forceId,
  required ApiHttpTransport? transport,
  required IncidentStore incidentStore,
  required bool Function() isStillCurrent,
}) async {
  final incident = incidentStore.currentIncident;
  if (transport == null || incident == null) throw StateError('未选择警情');
  await IncidentRepository(transport).deleteIncidentForce(forceId);
  if (!isStillCurrent()) return;
  await refreshIncidentAndForces(
    incidentId: incident.id,
    transport: transport,
    incidentStore: incidentStore,
    isStillCurrent: isStillCurrent,
  );
}
