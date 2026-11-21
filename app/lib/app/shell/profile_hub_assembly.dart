import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/auth/ui/admin_scanner_page.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/monitor/ui/monitor_stats_screen.dart';
import '../../features/roster/ui/archived_incident_models.dart';
import '../../features/roster/ui/archived_incidents_page.dart';
import '../../features/roster/ui/login_devices_page.dart';
import '../../features/roster/ui/member_review_page.dart';
import '../../features/roster/ui/offline_review_page.dart';
import '../../features/roster/ui/roster_page.dart';
import '../../features/roster/ui/unit_stations_page.dart';
import '../../features/settings/state/settings_store.dart';
import '../../features/settings/ui/about_page.dart';
import '../../features/settings/ui/component_gallery_page.dart';
import '../../features/settings/ui/op_log_page.dart';
import '../../features/settings/ui/profile_hub_page.dart';
import '../../features/settings/ui/watermark_settings_page.dart';
import '../../features/video/ui/video_resource_admin_page.dart';
import '../../services/op_log_service.dart';
import '../../state/app_controller.dart';
import 'profile_hub_gateways.dart';
import 'shell_monitor_adapter.dart';

/// 新外壳 Tab 3（我的）及全部设置/队站管理/后台扫码二级页装配器（M3f + M3g）。
///
/// 保持零旧 `pages/`、`theme/`、`widgets/` 依赖；主题切换回调由外壳注入，
/// 避免反向依赖过渡期 `app_palette.dart`。
class ProfileHubAssembly {
  ProfileHubAssembly({
    required this.controller,
    required this.monitorAdapter,
    required this.buildIncidentDetailsRoute,
    required this.onSelectThemeId,
    SettingsStore? settingsStoreOverride,
  }) : _gateways = ProfileHubGateways(controller),
       _ownsStore = settingsStoreOverride == null {
    _settingsStore = settingsStoreOverride ?? _createSettingsStore();
    _lastProtectedDataEpoch = controller.protectedDataEpoch;
    controller.addListener(_onControllerChanged);
  }

  final AppController controller;
  final ShellMonitorAdapter monitorAdapter;
  final Route<void>? Function([Incident? target]) buildIncidentDetailsRoute;
  final ValueChanged<String> onSelectThemeId;
  final ProfileHubGateways _gateways;
  final bool _ownsStore;

  late final SettingsStore _settingsStore;
  late int _lastProtectedDataEpoch;
  bool _disposed = false;

  SettingsStore get settingsStore => _settingsStore;

  SettingsStore _createSettingsStore() {
    final localAsr = controller.localAsr;
    return SettingsStore(
      gateway: SettingsGateway(
        onRefreshConfig: controller.refreshConfig,
        onStartSync: controller.startSync,
        onSyncSettings: () => unawaited(controller.syncSettings()),
        onSyncKeepAlive: controller.syncKeepAlive,
        onTtsEnabledChanged: (bool enabled) => controller.tts.enabled = enabled,
        onRefreshNow: controller.refreshNow,
        onRefreshPendingMembersCount: controller.refreshPendingMembersCount,
        onLeaveUnit: controller.leaveUnit,
        onRefreshAndCheckAdminScan: () async {
          await controller.refreshAdminCapability();
          return controller.canReadKeySites &&
              controller.adminCapability != null;
        },
        onRecordUpdateCheck: controller.recordUpdateCheck,
        onSelectThemeId: onSelectThemeId,
        localAsr: localAsr == null
            ? null
            : SettingsLocalAsrGateway.fromService(localAsr),
      ),
      identity: _buildIdentitySnapshot(),
      connection: _buildConnectionSnapshot(),
      update: _buildUpdateSnapshot(),
      alarmCaps: _buildAlarmCaps(),
    );
  }

  SettingsIdentitySnapshot _buildIdentitySnapshot({
    SettingsIdentitySnapshot? previous,
  }) {
    final revoked =
        controller.protectedDataRevoked || controller.needsAuthentication;
    return SettingsIdentitySnapshot(
      isGuest: controller.isGuest,
      authenticated: revoked
          ? false
          : (previous?.authenticated ??
                (!controller.isGuest && !controller.needsAuthentication)),
      protectedDataRevoked: controller.protectedDataRevoked,
      needsAuthentication: controller.needsAuthentication,
      protectedDataEpoch: controller.protectedDataEpoch,
      realName: revoked ? '' : (previous?.realName ?? ''),
      unitName: revoked ? '' : (previous?.unitName ?? ''),
      userRole: revoked ? 'member' : (previous?.userRole ?? 'member'),
      canScanAdmin:
          controller.canReadKeySites && controller.adminCapability != null,
      canReviewMembers: controller.canReviewMembers,
      memberReviewError: controller.memberReviewError,
      pendingMemberCount: controller.pendingMemberCount,
      offlineReviewCount: controller.offlineReviewCount,
      hasApi: controller.api != null,
    );
  }

  SettingsConnectionSnapshot _buildConnectionSnapshot() {
    return SettingsConnectionSnapshot(
      isGuest: controller.isGuest,
      connectionLost: controller.connectionLost,
      syncing: controller.syncing,
      syncError: controller.syncError,
      pendingOfflineCount: controller.offlineReviewCount,
    );
  }

  SettingsUpdateSnapshot _buildUpdateSnapshot() {
    return SettingsUpdateSnapshot(
      pendingUpdate: controller.pendingUpdate,
      checkDone: controller.updateCheckDone,
      checkError: controller.updateCheckError,
    );
  }

  SettingsAlarmCapabilities _buildAlarmCaps({
    SettingsAlarmCapabilities? previous,
  }) {
    return SettingsAlarmCapabilities(
      exactAlarmAvailable: controller.alarm.exactAlarmAvailable,
      policyAccessGranted: previous?.policyAccessGranted ?? true,
      fullScreenIntentEnabled: controller.alarm.fullScreenIntentEnabled,
    );
  }

  void _onControllerChanged() {
    if (_disposed || !_ownsStore) return;
    final previousIdentity = _settingsStore.identity;
    final epoch = controller.protectedDataEpoch;
    final epochChanged = epoch != _lastProtectedDataEpoch;
    _lastProtectedDataEpoch = epoch;
    final nextIdentity = _buildIdentitySnapshot(previous: previousIdentity);
    _settingsStore.syncExternalState(
      identity: nextIdentity,
      connection: _buildConnectionSnapshot(),
      update: _buildUpdateSnapshot(),
      alarmCaps: _buildAlarmCaps(previous: _settingsStore.alarmCaps),
    );
    if (!controller.protectedDataRevoked &&
        !controller.needsAuthentication &&
        !controller.isGuest &&
        (epochChanged || nextIdentity.realName.isEmpty)) {
      unawaited(_settingsStore.loadIdentity(expectedEpoch: epoch));
    }
  }

  /// 构建新外壳 Tab 3（我的）页面。
  Widget buildProfileHubPage(BuildContext context) {
    return ProfileHubPage(
      store: _settingsStore,
      routes: ProfileHubRoutes(
        onOpenWatermarkSettings: openWatermarkSettings,
        onOpenVideoAdmin: openVideoResourceAdmin,
        onOpenMemberReview: openMemberReview,
        onOpenRoster: openRoster,
        onOpenUnitStations: openUnitStations,
        onOpenArchivedIncidents: openArchivedIncidents,
        onOpenStats: openStats,
        onOpenOpLog: openOpLog,
        onOpenLoginDevices: openLoginDevices,
        onOpenOfflineReview: openOfflineReview,
        onOpenAdminScanner: openAdminScanner,
        onOpenAbout: openAbout,
        onOpenComponentGallery: openComponentGallery,
        onFlushOpLogs: _flushOpLogs,
      ),
    );
  }

  static Future<void> openWatermarkSettings(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const WatermarkSettingsPage()),
    );
  }

  static Future<void> openAbout(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AboutPage()),
    );
  }

  static Future<void> openComponentGallery(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ComponentGalleryPage()),
    );
  }

  Future<void> _flushOpLogs() =>
      OpLogService.instance.flush(api: controller.api);

  Future<void> openOpLog(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => OpLogPage(onFlush: _flushOpLogs)),
    );
  }

  Future<void> openVideoResourceAdmin(BuildContext context) {
    final repo = _gateways.buildVideoRepository();
    if (repo == null) return Future<void>.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoResourceAdminPage(
          repository: repo,
          canManage: _settingsStore.identity.canManageVideoResources,
          isOffline: controller.connectionLost,
        ),
      ),
    );
  }

  Future<void> openMemberReview(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemberReviewPage(
          gateway: _gateways.buildMemberReviewGateway(),
          isOffline: controller.connectionLost,
        ),
      ),
    );
  }

  Future<void> openRoster(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RosterPage(
          gateway: _gateways.buildRosterGateway(),
          onOpenMemberReview: openMemberReview,
          isOffline: controller.connectionLost,
        ),
      ),
    );
  }

  Future<void> openUnitStations(BuildContext context) {
    final repo = _gateways.buildRosterRepository();
    if (repo == null) return Future<void>.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => UnitStationsPage(
          repository: repo,
          isOffline: controller.connectionLost,
        ),
      ),
    );
  }

  Future<void> openArchivedIncidents(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ArchivedIncidentsPage(
          gateway: _gateways.buildArchivedIncidentsGateway(),
          onOpenDetails: _openArchivedIncidentDetails,
          isOffline: controller.connectionLost,
        ),
      ),
    );
  }

  Future<void> _openArchivedIncidentDetails(
    BuildContext context,
    ArchivedIncidentView view,
  ) async {
    final target =
        _gateways.lookupArchivedIncident(view.id) ??
        Incident(
          id: view.id,
          number: view.number,
          title: view.title,
          status: 'archived',
          createdAt: view.createdAt,
          lastActivityAt: view.lastActivityAt,
          archivedAt: view.archivedAt,
          archivedBy: view.archivedBy,
          autoArchived: view.autoArchived,
          unresolvedActiveCount: view.unresolvedActiveCount,
          version: view.version,
        );
    final route = buildIncidentDetailsRoute(target);
    if (route != null) await Navigator.of(context).push<void>(route);
  }

  Future<void> openStats(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MonitorStatsScreen(
          monitorStore: monitorAdapter.monitorStore,
          syncStore: monitorAdapter.syncStore,
          onRefresh: controller.refreshNow,
          isGuest: controller.isGuest,
        ),
      ),
    );
  }

  Future<void> openLoginDevices(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LoginDevicesPage(
          gateway: _gateways.buildLoginDevicesGateway(),
          isOffline: controller.connectionLost,
        ),
      ),
    );
  }

  Future<void> openOfflineReview(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OfflineReviewPage(
          gateway: _gateways.buildOfflineReviewGateway(),
          isOffline: controller.connectionLost,
        ),
      ),
    );
  }

  Future<void> openAdminScanner(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            AdminScannerPage(gateway: _gateways.buildAdminScannerGateway()),
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_onControllerChanged);
    if (_ownsStore) _settingsStore.dispose();
  }
}
