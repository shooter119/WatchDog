import 'dart:async';

import '../../core/network/network.dart';
import '../../core/sync/sync_store.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/auth/state/session_store.dart';
import '../../features/incident/data/incident_repository.dart';
import '../../features/incident/state/incident_store.dart';
import '../../features/roster/data/roster_repository.dart';
import '../../features/roster/state/roster_store.dart';
import '../../features/settings/data/settings_repository.dart';
import '../../services/diagnostic_log_service.dart';
import '../../services/media_capture_service.dart';
import '../../services/settings.dart';
import 'orchestrator_contracts.dart';

/// 启动期异步兜底维护任务（诊断日志、过期媒体清理、孤立媒体补登）。
void triggerStartupMaintenance() {
  unawaited(DiagnosticLogService.instance.init());
  unawaited(MediaCaptureService.purgeExpired().catchError((Object _) => 0));
  unawaited(
    MediaCaptureService.recoverOrphanedFiles().catchError((Object _) => 0),
  );
}

/// 校验本地是否完整存有已认证会话凭据。
Future<bool> hasStoredSessionCredentials() async =>
    (await Settings.realName).isNotEmpty &&
    (await Settings.unitId).isNotEmpty &&
    (await Settings.unitName).isNotEmpty &&
    (await Settings.sessionToken).isNotEmpty;

/// 单位认证与受保护探测返回的结构化凭据载荷。
class VerifiedUnitSession {
  final String unitId;
  final String unitName;
  final String sessionToken;
  final int sessionExpiresAt;
  final String memberId;
  final String userRole;
  final Map<String, dynamic>? roster;
  final bool hasStations;
  final Object? stations;

  const VerifiedUnitSession({
    required this.unitId,
    required this.unitName,
    required this.sessionToken,
    required this.sessionExpiresAt,
    required this.memberId,
    required this.userRole,
    required this.roster,
    required this.hasStations,
    required this.stations,
  });
}

int parseIntValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

/// 读取当前本机配置并构建新的 [ApiConfig]。
Future<ApiConfig> loadSessionApiConfig({
  required Future<String> Function() deviceIdProvider,
  required void Function(ApiException error) onAuthenticationFailure,
}) async {
  return ApiConfig(
    baseUrl: await Settings.serverUrl,
    incidentId: await Settings.currentIncidentId,
    sessionToken: await Settings.sessionToken,
    deviceId: await deviceIdProvider(),
    actorName: await Settings.realName,
    unitId: await Settings.unitId,
    unitCode: await Settings.unitCode,
    onAuthenticationFailure: onAuthenticationFailure,
  );
}

/// 完成单位验证码校验，并在落盘前以新令牌执行第一条受保护探测请求。
Future<VerifiedUnitSession?> verifyAndProbeUnitSession({
  required String unitName,
  required String realName,
  required String unitCode,
  required ApiTransportFactory transportFactory,
  required Future<String> Function() deviceIdProvider,
  required bool Function() isStillCurrent,
}) async {
  final serverUrl = await Settings.serverUrl;
  final deviceId = await deviceIdProvider();
  final bootstrap = transportFactory(
    ApiConfig(
      baseUrl: serverUrl,
      incidentId: '',
      deviceId: deviceId,
      actorName: realName,
    ),
  );
  late final Map<String, dynamic> result;
  try {
    result = await AuthRepository(
      bootstrap,
    ).verifyUnit(unitName: unitName, unitCode: unitCode, realName: realName);
  } finally {
    bootstrap.dispose();
  }
  if (!isStillCurrent()) return null;

  final unitInfo = result['unit'] is Map
      ? Map<String, dynamic>.from(result['unit'] as Map)
      : <String, dynamic>{};
  final unitId = unitInfo['id']?.toString().trim() ?? '';
  if (unitId.isEmpty) throw StateError('单位认证响应无效，请稍后重试');
  final sessionToken = result['session_token']?.toString().trim() ?? '';
  final sessionExpiresAt = parseIntValue(result['expires_at']);
  if (sessionToken.isEmpty || sessionExpiresAt <= 0) {
    throw StateError('单位认证响应缺少有效会话，请稍后重试');
  }

  final probe = transportFactory(
    ApiConfig(
      baseUrl: serverUrl,
      incidentId: '',
      deviceId: deviceId,
      actorName: realName,
      unitId: unitId,
      unitCode: unitCode,
      sessionToken: sessionToken,
    ),
  );
  try {
    await IncidentRepository(probe).fetchIncidents(status: 'active');
  } finally {
    probe.dispose();
  }
  if (!isStillCurrent()) return null;

  final userMap = result['user'] is Map
      ? Map<String, dynamic>.from(result['user'] as Map)
      : const <String, dynamic>{};
  return VerifiedUnitSession(
    unitId: unitId,
    unitName: unitInfo['name']?.toString() ?? unitName,
    sessionToken: sessionToken,
    sessionExpiresAt: sessionExpiresAt,
    memberId: userMap['id']?.toString() ?? '',
    userRole: userMap['role']?.toString() ?? 'member',
    roster: result['roster'] is Map
        ? Map<String, dynamic>.from(result['roster'] as Map)
        : null,
    hasStations: result.containsKey('stations'),
    stations: result['stations'],
  );
}

/// 将已验证会话持久化至 [Settings] 与 [RosterStore] 本地缓存。
Future<void> persistVerifiedUnitSession({
  required VerifiedUnitSession verified,
  required String realName,
  required String unitCode,
  required RosterStore rosterStore,
  required int nowMs,
}) async {
  await Settings.setMemberId(verified.memberId);
  await Settings.setUserRole(verified.userRole);
  await Settings.setIsGuestMode(false);
  await Settings.clearPendingApplication();
  await Settings.setSessionToken(verified.sessionToken);
  await Settings.setSessionExpiresAt(verified.sessionExpiresAt);
  await Settings.setRealName(realName);
  await Settings.setUnitId(verified.unitId);
  await Settings.setUnitCode(unitCode);
  await Settings.setUnitName(verified.unitName);
  rosterStore.applySnapshot(
    roster: verified.roster,
    stations: verified.hasStations ? verified.stations : null,
    persistCache: false,
    syncHotwords: false,
    notify: false,
  );
  await rosterStore.cacheRoster(verified.unitId);
  await Settings.markModified(nowMs);
}

/// 清理本地会话凭据；主动退单时一并清空实名、单位名与游客标记。
Future<void> clearPersistedSessionSettings({
  required bool clearIdentityProfile,
  required int nowMs,
}) async {
  if (clearIdentityProfile) {
    await Settings.setIsGuestMode(false);
    await Settings.setUserRole('member');
  }
  await Settings.setCurrentIncidentId('');
  await Settings.setApiToken('');
  await Settings.setSessionToken('');
  await Settings.setSessionExpiresAt(0);
  await Settings.setMemberId('');
  await Settings.setUnitId('');
  await Settings.setUnitCode('');
  if (clearIdentityProfile) {
    await Settings.setRealName('');
    await Settings.setUnitName('');
    await Settings.markModified(nowMs);
  }
}

/// 云端个人设置双向同步（服务器较新则拉取覆盖并回调刷新，本地较新则推送）。
Future<void> syncRemoteUserSettings({
  required ApiHttpTransport transport,
  required bool Function() isStillCurrent,
  required Future<void> Function() onAppliedRemote,
}) async {
  try {
    final repo = SettingsRepository(transport);
    final remote = await repo.fetchUserSettings();
    if (!isStillCurrent()) return;
    final remoteAt = (remote['updatedAt'] as num?)?.toInt() ?? 0;
    final localAt = await Settings.modifiedAt;
    if (!isStillCurrent()) return;
    if (remoteAt > localAt) {
      final remoteSettings = remote['settings'];
      if (remoteSettings is! Map) return;
      await Settings.applyFromServer(
        Map<String, dynamic>.from(remoteSettings),
        updatedAt: remoteAt,
      );
      await onAppliedRemote();
    } else if (remoteAt < localAt) {
      await repo.pushUserSettings(await Settings.toSyncMap());
    }
  } catch (_) {}
}

/// 带代际与会话校验的远端会话续期执行体。
Future<void> executeSessionRefresh({
  required bool force,
  required int nowMs,
  required Duration leadTime,
  required ApiHttpTransport? activeTransport,
  required ApiConfig? activeConfig,
  required bool Function() isStillAuthenticatedSession,
  required Future<void> Function() onInvalidateAuthentication,
}) async {
  final expiresAt = await Settings.sessionExpiresAt;
  if (expiresAt > 0 && expiresAt <= nowMs) {
    await onInvalidateAuthentication();
    throw StateError('认证会话已过期，请重新认证');
  }
  if (!force && expiresAt > nowMs + leadTime.inMilliseconds) {
    return;
  }
  if (activeTransport == null ||
      activeConfig == null ||
      activeConfig.sessionToken.isEmpty) {
    await onInvalidateAuthentication();
    throw StateError('认证会话已失效，请重新认证');
  }
  try {
    final result = await AuthRepository(activeTransport).refreshSession();
    if (!isStillAuthenticatedSession()) return;
    final refreshedExpiresAt = parseIntValue(result['expires_at']);
    if (refreshedExpiresAt <= nowMs) {
      throw ApiException(
        '认证续期响应无效，请重新认证',
        statusCode: 401,
        code: 'SESSION_INVALID',
      );
    }
    await Settings.setSessionExpiresAt(refreshedExpiresAt);
  } catch (error) {
    if (isApiAuthenticationFailure(error)) {
      await onInvalidateAuthentication();
    }
    rethrow;
  }
}

/// 刷新当前会话下的管理员能力。
Future<void> refreshUnitAdminCapability({
  required SessionStore sessionStore,
  required ApiHttpTransport transport,
  required bool Function() isSessionActive,
}) => sessionStore.refreshAdminCapability(
  () => AuthRepository(transport).fetchAdminCapability(),
  isSessionActive: isSessionActive,
);

/// 刷新当前会话下的待审批成员列表。
Future<void> refreshUnitPendingMembers({
  required SessionStore sessionStore,
  required ApiHttpTransport transport,
  required bool Function() isSessionActive,
}) {
  final repo = AuthRepository(transport);
  return sessionStore.refreshPendingMembers(
    fetchCapability: repo.fetchMemberReviewCapability,
    fetchPending: repo.fetchPendingMembers,
    fetchHistory: repo.fetchMemberReviewHistory,
    isSessionActive: isSessionActive,
  );
}

/// 刷新当前会话下的单位名单、热词与消防站缓存。
Future<void> loadUnitRoster({
  required RosterStore rosterStore,
  required ApiHttpTransport transport,
  required ApiConfig config,
  required bool Function() isStillCurrent,
  bool syncHotwords = false,
}) {
  final repo = RosterRepository(transport);
  return rosterStore.loadRoster(
    fallbackUnitId: config.unitId,
    fetchFirefighters: repo.fetchFirefighters,
    fetchHotwords: repo.fetchHotwords,
    fetchStations: repo.fetchStations,
    cacheScope: config.cacheScope,
    isStillCurrent: isStillCurrent,
    syncHotwords: syncHotwords,
  );
}

/// 尽力注销远端会话；网络不可用时静默放行，确保本地清理不中断。
Future<void> logoutBestEffort(ApiHttpTransport? transport) async {
  if (transport == null) return;
  try {
    await AuthRepository(transport).logout();
  } catch (_) {}
}

/// 冷启动首轮同步前延迟诊断日志上传，避免与 bootstrap 抢占通道。
bool shouldDeferColdStartLogFlush({
  required bool syncStarted,
  required bool authenticated,
  required ApiConfig config,
}) =>
    !syncStarted &&
    (authenticated ||
        (config.sessionToken.isNotEmpty && config.unitId.isNotEmpty));

/// 校验输入并完成单位验证、受保护探测与本地凭据落盘；若中途会话代际失效返回 false。
Future<bool> authenticateAndPersistUnit({
  required String unitName,
  required String realName,
  required String unitCode,
  required Future<void> Function() ensureReady,
  required ApiTransportFactory transportFactory,
  required Future<String> Function() deviceIdProvider,
  required RosterStore rosterStore,
  required int Function() nowMs,
  required bool Function() isStillCurrent,
}) async {
  final unit = unitName.trim();
  final name = realName.trim();
  final code = unitCode.trim();
  if (unit.isEmpty) throw StateError('请输入单位名称');
  if (name.isEmpty) throw StateError('请输入真实姓名');
  if (code.isEmpty) throw StateError('请输入单位验证码');
  await ensureReady();
  if (!isStillCurrent()) return false;
  final verified = await verifyAndProbeUnitSession(
    unitName: unit,
    realName: name,
    unitCode: code,
    transportFactory: transportFactory,
    deviceIdProvider: deviceIdProvider,
    isStillCurrent: isStillCurrent,
  );
  if (verified == null || !isStillCurrent()) return false;
  await persistVerifiedUnitSession(
    verified: verified,
    realName: name,
    unitCode: code,
    rosterStore: rosterStore,
    nowMs: nowMs(),
  );
  return isStillCurrent();
}

/// 退单或认证吊销后统一重置各域 Store 并刷新配置。
Future<void> resetStoresAfterTeardown({
  required SessionStore sessionStore,
  required SyncStore syncStore,
  required IncidentStore incidentStore,
  required RosterStore rosterStore,
  required IncidentDomainHooks domainHooks,
  required Future<void> Function() refreshConfig,
}) async {
  incidentStore.resetAll(notify: false);
  domainHooks.onClearIncidentDomainData?.call();
  await rosterStore.resetForSessionClear(notify: false);
  sessionStore.resetUnauthenticated(
    revokeData: false,
    clearConfig: true,
    notify: false,
  );
  await refreshConfig();
  incidentStore.resetAll(notify: true);
  rosterStore.clear(notify: true);
  syncStore.notifyStateChanged();
  sessionStore.notifyStateChanged();
}

/// 会话配置参数容器（将可注入依赖聚合，保持编排器构造清晰紧凑）。
class SessionOrchestratorConfig {
  final ApiTransportFactory transportFactory;
  final int Function() nowMs;
  final Future<String> Function()? deviceIdProvider;
  final Duration sessionRefreshInterval;
  final Duration adminCapabilityInterval;
  final bool enableStartupMaintenance;
  final IncidentDomainHooks domainHooks;
  final SessionSyncBridge syncBridge;
  final void Function({required bool inForeground, required bool syncConnected})?
  reportLifecycle;

  const SessionOrchestratorConfig({
    this.transportFactory = defaultApiTransportFactory,
    this.nowMs = defaultNowMs,
    this.deviceIdProvider,
    this.sessionRefreshInterval = const Duration(minutes: 15),
    this.adminCapabilityInterval = const Duration(seconds: 30),
    this.enableStartupMaintenance = true,
    this.domainHooks = IncidentDomainHooks.empty,
    this.syncBridge = SessionSyncBridge.empty,
    this.reportLifecycle,
  });

  static int defaultNowMs() => DateTime.now().millisecondsSinceEpoch;
}


