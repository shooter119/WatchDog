part of 'api_client.dart';

mixin _OpsApiFacade on _ApiClientBase {
  // ---- SyncRepository (7) ----

  Uri realtimeSyncUri() => _sync.realtimeSyncUri();

  Map<String, String> realtimeSyncHeaders() => _sync.realtimeSyncHeaders();

  Future<Map<String, dynamic>> fetchSyncBootstrap({String? forIncidentId}) =>
      _sync.fetchSyncBootstrap(forIncidentId: forIncidentId);

  Future<Map<String, dynamic>> fetchSyncCheckpoint({String? forIncidentId}) =>
      _sync.fetchSyncCheckpoint(forIncidentId: forIncidentId);

  Future<List<Map<String, dynamic>>> fetchSyncEvents({
    required String unitCursor,
    required String incidentCursor,
    String? forIncidentId,
    int limit = 500,
  }) => _sync.fetchSyncEvents(
    unitCursor: unitCursor,
    incidentCursor: incidentCursor,
    forIncidentId: forIncidentId,
    limit: limit,
  );

  Future<void> submitReviewedOperation({
    required String type,
    required Map<String, dynamic> payload,
    required String originalOpId,
    required String newOpId,
    int? expectedVersion,
  }) => _sync.submitReviewedOperation(
    type: type,
    payload: payload,
    originalOpId: originalOpId,
    newOpId: newOpId,
    expectedVersion: expectedVersion,
  );

  Future<Map<String, dynamic>> uploadOfflineOperations(
    List<Map<String, dynamic>> operations,
  ) => _sync.uploadOfflineOperations(operations);

  // ---- LogRepository (1) ----

  Future<void> sendLogs(List<Map<String, dynamic>> logs) => _log.sendLogs(logs);

  // ---- AuthRepository (17) ----

  Future<AdminCapability?> fetchAdminCapability() =>
      _auth.fetchAdminCapability();

  Future<void> confirmAdminLogin(
    AdminLoginCode code, {
    bool cancel = false,
  }) => _auth.confirmAdminLogin(code, cancel: cancel);

  Future<Map<String, dynamic>> fetchAuthIdentity() => _auth.fetchAuthIdentity();

  Future<List<Map<String, dynamic>>> fetchLoginDevices() =>
      _auth.fetchLoginDevices();

  Future<void> revokeLoginDevice(String? id) => _auth.revokeLoginDevice(id);

  Future<Map<String, dynamic>> verifyUnit({
    required String unitName,
    required String unitCode,
    required String realName,
  }) => _auth.verifyUnit(
    unitName: unitName,
    unitCode: unitCode,
    realName: realName,
  );

  Future<Map<String, dynamic>> applyUnitMembership({
    required String unitName,
    required String unitCode,
    required String realName,
    String? stationName,
    String? phone,
    String? applyReason,
  }) => _auth.applyUnitMembership(
    unitName: unitName,
    unitCode: unitCode,
    realName: realName,
    stationName: stationName,
    phone: phone,
    applyReason: applyReason,
  );

  Future<List<UnitMember>> fetchUnitMembers() => _auth.fetchUnitMembers();

  Future<bool> fetchMemberReviewCapability() =>
      _auth.fetchMemberReviewCapability();

  Future<List<Map<String, dynamic>>> fetchMemberReviewHistory({
    int offset = 0,
  }) => _auth.fetchMemberReviewHistory(offset: offset);

  Future<List<UnitMember>> fetchPendingMembers() => _auth.fetchPendingMembers();

  Future<UnitMember> approveMember(String memberId) =>
      _auth.approveMember(memberId);

  Future<UnitMember> rejectMember(String memberId, {String? reason}) =>
      _auth.rejectMember(memberId, reason: reason);

  Future<UnitMember> addUnitMember({
    required String realName,
    String role = 'member',
    String? stationName,
    String? phone,
  }) => _auth.addUnitMember(
    realName: realName,
    role: role,
    stationName: stationName,
    phone: phone,
  );

  Future<UnitMember> updateUnitMember(
    String memberId, {
    String? role,
    String? status,
    String? stationName,
    String? phone,
  }) => _auth.updateUnitMember(
    memberId,
    role: role,
    status: status,
    stationName: stationName,
    phone: phone,
  );

  Future<Map<String, dynamic>> refreshSession() => _auth.refreshSession();

  Future<void> logout() => _auth.logout();

  // ---- MonitorRepository (5) ----

  Future<List<Entry>> fetchEntries({bool activeOnly = false}) =>
      _monitor.fetchEntries(activeOnly: activeOnly);

  Future<Entry> createEntry({
    required String name,
    required double pressureMpa,
    String source = 'voice',
    String? rawText,
    bool force = false,
    double? volumeL,
    double? consumptionLpm,
    String? opId,
  }) => _monitor.createEntry(
    name: name,
    pressureMpa: pressureMpa,
    source: source,
    rawText: rawText,
    force: force,
    volumeL: volumeL,
    consumptionLpm: consumptionLpm,
    opId: opId,
  );

  Future<Entry> updateEntry({
    required String id,
    String? name,
    double? pressureMpa,
    double? consumptionLpm,
    String? opId,
    int? expectedVersion,
  }) => _monitor.updateEntry(
    id: id,
    name: name,
    pressureMpa: pressureMpa,
    consumptionLpm: consumptionLpm,
    opId: opId,
    expectedVersion: expectedVersion,
  );

  Future<void> markExited(
    String id, {
    String? opId,
    int? expectedVersion,
  }) => _monitor.markExited(id, opId: opId, expectedVersion: expectedVersion);

  Future<CalcConfig> fetchConfig() => _monitor.fetchConfig();

  // ---- SettingsRepository (4) ----

  Future<Map<String, dynamic>> fetchUserSettings() =>
      _settings.fetchUserSettings();

  Future<void> pushUserSettings(Map<String, dynamic> settings) =>
      _settings.pushUserSettings(settings);

  Future<Map<String, dynamic>> fetchProfile() => _settings.fetchProfile();

  Future<Map<String, dynamic>> saveProfile(String realName) =>
      _settings.saveProfile(realName);
}
