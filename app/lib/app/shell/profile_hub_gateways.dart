import 'package:flutter/foundation.dart';

import '../../api/api_client.dart';
import '../../features/auth/data/models/admin_login.dart';
import '../../features/auth/ui/admin_scanner_page.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/incident/data/models/incident_event.dart';
import '../../features/incident/data/models/incident_force.dart';
import '../../features/roster/data/models/firefighter.dart';
import '../../features/roster/data/models/hotword.dart';
import '../../features/roster/data/models/station.dart';
import '../../features/roster/data/roster_repository.dart';
import '../../features/roster/ui/archived_incident_models.dart';
import '../../features/roster/ui/login_devices_page.dart';
import '../../features/roster/ui/member_review_page.dart';
import '../../features/roster/ui/offline_review_page.dart';
import '../../features/roster/ui/roster_page.dart';
import '../../features/video/data/video_repository.dart';
import '../../state/app_controller.dart';
import 'field_tools_gateways.dart';

/// M3f/M3g 「我的」Tab 与队站管理域网关构建器（零旧 `pages/`、`theme/`、`widgets/` 依赖）。
class ProfileHubGateways {
  ProfileHubGateways(this.controller)
    : _fieldTools = FieldToolsGateways(controller);

  final AppController controller;
  final FieldToolsGateways _fieldTools;
  final Map<String, Incident> _archivedById = <String, Incident>{};

  Incident? lookupArchivedIncident(String id) => _archivedById[id];

  RosterPageGateway buildRosterGateway() => _ControllerRosterGateway(controller);

  MemberReviewGateway buildMemberReviewGateway() =>
      _ControllerMemberReviewGateway(controller);

  ArchivedIncidentsGateway buildArchivedIncidentsGateway() =>
      _ControllerArchivedIncidentsGateway(controller, _archivedById);

  LoginDevicesGateway buildLoginDevicesGateway() =>
      _ControllerLoginDevicesGateway(controller, controller.api);

  OfflineReviewGateway buildOfflineReviewGateway() =>
      _ControllerOfflineReviewGateway(controller, controller.api);

  AdminScannerGateway buildAdminScannerGateway() {
    return AdminScannerGateway(
      accessListenable: controller,
      canReadKeySites: () => controller.canReadKeySites,
      readAdminCapability: () => controller.adminCapability,
      readProtectedDataEpoch: () => controller.protectedDataEpoch,
      readClientIdentity: () => controller.api,
      refreshAdminCapability: controller.refreshAdminCapability,
      confirmAdminLogin: (AdminLoginCode code, {bool cancel = false}) async {
        final api = controller.api;
        if (api == null) {
          throw ApiException(
            'App 认证已失效，请重新认证',
            statusCode: 401,
            code: 'SESSION_INVALID',
          );
        }
        await api.confirmAdminLogin(code, cancel: cancel);
      },
    );
  }

  RosterRepository? buildRosterRepository() {
    final api = controller.api;
    return api == null ? null : _ApiRosterRepository(api);
  }

  VideoRepository? buildVideoRepository() => _fieldTools.buildVideoRepository();
}

class _ControllerRosterGateway implements RosterPageGateway {
  const _ControllerRosterGateway(this._controller);

  final AppController _controller;

  ApiClient _requireApi() {
    final api = _controller.api;
    if (api == null) throw StateError('未连接服务端');
    return api;
  }

  @override
  Listenable? get changes => _controller;

  @override
  List<Firefighter> get firefighters => _controller.firefighters;

  @override
  List<Hotword> get hotwords => _controller.hotwords;

  @override
  bool get canReviewMembers => _controller.canReviewMembers;

  @override
  int get pendingMemberCount => _controller.pendingMemberCount;

  @override
  Future<void> loadRoster() => _controller.loadRoster();

  @override
  Future<void> refreshPendingMembersCount() =>
      _controller.refreshPendingMembersCount();

  @override
  Future<bool> addFirefighter(String name) =>
      _requireApi().addFirefighter(name);

  @override
  Future<void> removeFirefighter(String id) =>
      _requireApi().removeFirefighter(id);

  @override
  Future<void> addHotword(String word) => _requireApi().addHotword(word);

  @override
  Future<void> removeHotword(String id) => _requireApi().removeHotword(id);
}

class _ControllerMemberReviewGateway implements MemberReviewGateway {
  const _ControllerMemberReviewGateway(this._controller);

  final AppController _controller;

  @override
  Listenable? get changes => _controller;

  @override
  int get protectedDataEpoch => _controller.protectedDataEpoch;

  @override
  bool get protectedDataRevoked => _controller.protectedDataRevoked;

  @override
  bool get needsAuthentication => _controller.needsAuthentication;

  @override
  bool get canReviewMembers => _controller.canReviewMembers;

  @override
  bool get isLoading => _controller.memberReviewLoading;

  @override
  String? get error => _controller.memberReviewError;

  @override
  String get unitName => _controller.memberReviewUnitName;

  @override
  List<PendingMemberView> get pendingMembers => _controller.pendingMembers
      .map(
        (UnitMember m) => PendingMemberView(
          id: m.id,
          realName: m.realName,
          stationName: m.stationName,
          applyReason: m.applyReason,
          createdAt: m.createdAt,
          inRoster: m.inRoster,
        ),
      )
      .toList();

  @override
  List<MemberReviewHistoryItem> get reviewHistory => _controller
      .memberReviewHistory
      .map(MemberReviewHistoryItem.fromMap)
      .toList();

  @override
  Future<void> refresh() => _controller.refreshPendingMembersCount();

  @override
  Future<void> approveMember(String memberId) async {
    final api = _controller.api;
    final epoch = _controller.protectedDataEpoch;
    if (api == null) throw StateError('未连接服务端');
    await api.approveMember(memberId);
    if (epoch == _controller.protectedDataEpoch && api == _controller.api) {
      await _controller.loadRoster();
    }
  }

  @override
  Future<void> rejectMember(String memberId) async {
    final api = _controller.api;
    if (api == null) throw StateError('未连接服务端');
    await api.rejectMember(memberId);
  }

  @override
  Future<List<MemberReviewHistoryItem>> fetchHistoryPage({
    required int offset,
  }) async {
    final api = _controller.api;
    if (api == null) throw StateError('未连接服务端');
    final rows = await api.fetchMemberReviewHistory(offset: offset);
    return rows.map(MemberReviewHistoryItem.fromMap).toList();
  }

  @override
  void appendHistoryPage(List<MemberReviewHistoryItem> rows) {
    _controller.memberReviewHistory = <Map<String, dynamic>>[
      ..._controller.memberReviewHistory,
      ...rows.map(
        (MemberReviewHistoryItem item) => <String, dynamic>{
          'id': item.id,
          'real_name': item.realName,
          'review_status': item.reviewStatus,
          'reviewer_name': item.reviewerName,
          'reviewed_at': item.reviewedAt,
        },
      ),
    ];
  }
}

class _ControllerArchivedIncidentsGateway implements ArchivedIncidentsGateway {
  const _ControllerArchivedIncidentsGateway(this._controller, this._cache);

  final AppController _controller;
  final Map<String, Incident> _cache;

  ArchivedIncidentView _toView(Incident inc) => ArchivedIncidentView(
    id: inc.id,
    number: inc.number,
    title: inc.title,
    suggestedTitle: inc.suggestedTitle,
    createdAt: inc.createdAt,
    lastActivityAt: inc.lastActivityAt,
    archivedAt: inc.archivedAt,
    archivedBy: inc.archivedBy,
    autoArchived: inc.autoArchived,
    unresolvedActiveCount: inc.unresolvedActiveCount,
    version: inc.version,
    forceStationCount: inc.forceStationCount,
    vehicleCount: inc.vehicleCount,
    personnelCount: inc.personnelCount,
    unknownVehicleStationCount: inc.unknownVehicleStationCount,
    unknownPersonnelStationCount: inc.unknownPersonnelStationCount,
  );

  @override
  Future<List<ArchivedIncidentView>> fetchArchivedIncidents() async {
    final incidents = await _controller.archivedIncidents();
    _cache
      ..clear()
      ..addEntries(
        incidents.map((Incident i) => MapEntry<String, Incident>(i.id, i)),
      );
    return incidents.map(_toView).toList();
  }

  @override
  Future<ArchivedIncidentView> renameIncident(
    ArchivedIncidentView incident,
    String title,
  ) async {
    final target =
        _cache[incident.id] ??
        Incident(
          id: incident.id,
          number: incident.number,
          title: incident.title,
          status: 'archived',
          createdAt: incident.createdAt,
          lastActivityAt: incident.lastActivityAt,
          version: incident.version,
        );
    final updated = await _controller.renameIncident(target, title);
    _cache[updated.id] = updated;
    return _toView(updated);
  }

  @override
  Future<List<ArchivedIncidentEventView>> fetchTimeline(
    String incidentId,
  ) async {
    final api = _controller.api;
    if (api == null) return const <ArchivedIncidentEventView>[];
    final events = await api.fetchTimeline(incidentId);
    return events
        .map(
          (IncidentEvent e) => ArchivedIncidentEventView(
            type: e.type,
            text: e.text,
            occurredAt: e.occurredAt,
            actorName: e.actorName,
            source: e.source,
            revisionOf: e.revisionOf,
          ),
        )
        .toList();
  }

  @override
  Future<List<ArchivedIncidentForceView>> fetchForces(String incidentId) async {
    final api = _controller.api;
    if (api == null) return const <ArchivedIncidentForceView>[];
    final forces = await api.fetchIncidentForces(forIncidentId: incidentId);
    return forces
        .map(
          (IncidentForce f) => ArchivedIncidentForceView(
            stationName: f.stationName,
            vehicleLabel: f.vehicleLabel,
            personnelLabel: f.personnelLabel,
          ),
        )
        .toList();
  }
}

class _ControllerLoginDevicesGateway implements LoginDevicesGateway {
  const _ControllerLoginDevicesGateway(this._controller, this._capturedApi);

  final AppController _controller;
  final ApiClient? _capturedApi;

  @override
  Listenable? get changes => _controller;

  @override
  bool get isAuthorized =>
      !_controller.needsAuthentication &&
      _capturedApi != null &&
      _controller.api == _capturedApi;

  @override
  Future<List<LoginDeviceView>> fetchDevices() async {
    final api = _capturedApi;
    if (api == null) throw StateError('未连接服务端');
    final list = await api.fetchLoginDevices();
    return list.map(LoginDeviceView.fromMap).toList();
  }

  @override
  Future<void> revokeDevice(String? deviceId) async {
    final api = _capturedApi;
    if (api == null) throw StateError('未连接服务端');
    await api.revokeLoginDevice(deviceId);
  }
}

class _ControllerOfflineReviewGateway implements OfflineReviewGateway {
  const _ControllerOfflineReviewGateway(this._controller, this._capturedApi);

  final AppController _controller;
  final ApiClient? _capturedApi;

  @override
  Listenable? get changes => _controller;

  @override
  bool get isAuthorized =>
      !_controller.needsAuthentication &&
      _capturedApi != null &&
      _controller.api == _capturedApi;

  Future<T> _runScoped<T>(
    String incidentId,
    Future<T> Function(ApiClient client) action,
  ) async {
    final base = _capturedApi;
    if (base == null) throw StateError('未连接服务端');
    final scoped = base.forIncident(incidentId);
    try {
      return await action(scoped);
    } finally {
      scoped.dispose();
    }
  }

  @override
  Future<bool> isIncidentActive(String incidentId) => _runScoped(
    incidentId,
    (ApiClient c) async => (await c.fetchIncident(incidentId)).isActive,
  );

  @override
  Future<OfflineReviewEntrySnapshot?> fetchEntrySnapshot({
    required String incidentId,
    required String entryId,
  }) => _runScoped(incidentId, (ApiClient c) async {
    final entries = await c.fetchEntries();
    final matched = entries.where((e) => e.id == entryId).firstOrNull;
    if (matched == null) return null;
    return OfflineReviewEntrySnapshot(
      id: matched.id,
      name: matched.name,
      isActive: matched.isActive,
      version: matched.version,
      pressureMpa: matched.pressureMpa,
      consumptionLpm: matched.consumptionLpm,
    );
  });

  @override
  Future<void> submitReviewedOperation({
    required String incidentId,
    required String type,
    required Map<String, dynamic> payload,
    required String originalOpId,
    required String newOpId,
    int? expectedVersion,
  }) => _runScoped(
    incidentId,
    (ApiClient c) => c.submitReviewedOperation(
      type: type,
      payload: payload,
      originalOpId: originalOpId,
      newOpId: newOpId,
      expectedVersion: expectedVersion,
    ),
  );

  @override
  Future<void> syncAfterReview() => _controller.sync();
}

class _ApiRosterRepository implements RosterRepository {
  const _ApiRosterRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<Firefighter>> fetchFirefighters() => _api.fetchFirefighters();

  @override
  Future<bool> addFirefighter(String name) => _api.addFirefighter(name);

  @override
  Future<void> removeFirefighter(String id) => _api.removeFirefighter(id);

  @override
  Future<List<Hotword>> fetchHotwords() => _api.fetchHotwords();

  @override
  Future<void> addHotword(String word) => _api.addHotword(word);

  @override
  Future<void> removeHotword(String id) => _api.removeHotword(id);

  @override
  Future<List<Map<String, dynamic>>> fetchUnitStations({
    bool includeInactive = false,
  }) => _api.fetchUnitStations(includeInactive: includeInactive);

  @override
  Future<Map<String, dynamic>> unitStationAccess() => _api.unitStationAccess();

  @override
  Future<Map<String, dynamic>> addUnitStation(String name) =>
      _api.addUnitStation(name);

  @override
  Future<Map<String, dynamic>> updateUnitStation(
    String id,
    Map<String, dynamic> data,
  ) => _api.updateUnitStation(id, data);

  @override
  Future<List<Station>> fetchStations() => _api.fetchStations();

  @override
  Future<Station> createStation(String name) => _api.createStation(name);
}
