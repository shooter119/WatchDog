part of 'app_controller.dart';

int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}') ?? 0;
}

double? _offlineNumber(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse('${value ?? ''}');
}

String _formatPressureMpa(double pressure) {
  final rounded = pressure.roundToDouble();
  return (pressure - rounded).abs() < 0.001
      ? rounded.toInt().toString()
      : pressure.toStringAsFixed(1);
}

ApiClient _defaultApiFactory({
  required String baseUrl,
  required String incidentId,
  required String sessionToken,
  required String deviceId,
  required String actorName,
  required String unitId,
  required String unitCode,
  void Function(ApiException error)? onAuthenticationFailure,
}) => ApiClient(
  baseUrl: baseUrl,
  incidentId: incidentId,
  sessionToken: sessionToken,
  deviceId: deviceId,
  actorName: actorName,
  unitId: unitId,
  unitCode: unitCode,
  onAuthenticationFailure: onAuthenticationFailure,
);

abstract class _AppControllerBase extends ChangeNotifier {
  final LocalAsrService? localAsr;
  final OfflineOperationEnqueuer? _offlineOperationEnqueuer;
  final OfflineQueueDrainer? _offlineQueueDrainer;
  final SyncClientFactory? _syncClientFactory;
  final ApiClientFactory? _apiFactory;
  final int Function() _nowMs;
  final LocalParser localParser = LocalParser();
  ApiClient? api;
  final AlarmService alarm = AlarmService();
  final TtsService tts = TtsService();
  bool asrCloudEnabled = true;
  bool parseCloudEnabled = true;
  AppScope? _appScope;
  bool _ownsAppScope;

  _AppControllerBase({
    this.localAsr,
    OfflineOperationEnqueuer? offlineOperationEnqueuer,
    OfflineQueueDrainer? offlineQueueDrainer,
    SyncClientFactory? syncClientFactory,
    ApiClientFactory? apiFactory,
    int Function()? nowMs,
    AppScope? appScope,
  }) : _offlineOperationEnqueuer = offlineOperationEnqueuer,
       _offlineQueueDrainer = offlineQueueDrainer,
       _syncClientFactory = syncClientFactory,
       _apiFactory = apiFactory,
       _nowMs = nowMs ?? _defaultNowMs,
       _appScope = appScope,
       _ownsAppScope = false;

  final Map<String, int> _scheduled = {};
  /// 已挂接的 M2 依赖装配容器（未触发惰性构建时返回 null）。
  AppScope? get attachedAppScope => _appScope;

  /// M2 过渡期依赖装配容器：按需惰性构建并与本控制器共享组织词库，随本控制器释放。
  AppScope get appScope => _ensureAppScope();

  SyncStore get syncStore => appScope.syncStore;
  SessionStore get sessionStore => appScope.sessionStore;
  IncidentStore get incidentStore => appScope.incidentStore;
  RosterStore get rosterStore => appScope.rosterStore;
  UpdateStore get updateStore => appScope.updateStore;

  AppScope _ensureAppScope() {
    final existing = _appScope;
    if (existing != null) return existing;
    final created = AppScope(
      rosterStore: RosterStore(orgDirectory: orgDirectory, localAsr: localAsr),
      createDefaultLocalAsr: false,
      enableStartupMaintenance: false,
      nowMs: _nowMs,
      isAssistantBusy: () => _assistantBusy,
    );
    _appScope = created;
    _ownsAppScope = true;
    syncScopeBridge();
    return created;
  }

  /// 将当前控制器核心状态镜像到已挂接的 [AppScope] Store（仅供 M2~M3g 过渡桥接读取）。
  void syncScopeBridge() {
    final s = _appScope;
    if (s == null || s.isDisposed || _disposed) return;
    s.incidentStore.setCurrentIncident(
      currentIncident,
      forces: forces,
      notify: false,
    );
    s.incidentStore.setActiveIncidents(activeIncidents, notify: false);
    s.incidentStore.setExternalIncidents(externalIncidents, notify: false);
    s.incidentStore.setExternalIncidentsLoading(
      externalIncidentsLoading,
      notify: false,
    );
    s.incidentStore.setExternalReorganizing(
      externalReorganizing,
      notify: false,
    );
    s.updateStore.setPendingUpdate(pendingUpdate, notify: false);
    s.updateStore.setUpdateCheckDone(updateCheckDone, notify: false);
    s.updateStore.setUpdateCheckError(updateCheckError, notify: false);
  }

  List<Entry> entries = [];
  final OrgDirectory orgDirectory = OrgDirectory();
  List<Firefighter> get firefighters => orgDirectory.firefighters;
  set firefighters(List<Firefighter> value) => orgDirectory.firefighters = value;
  List<Hotword> get hotwords => orgDirectory.hotwords;
  set hotwords(List<Hotword> value) => orgDirectory.hotwords = value;
  List<Station> get stations => orgDirectory.stations;
  set stations(List<Station> value) => orgDirectory.stations = value;
  List<Note> notes = [];
  CalcConfig calcConfig = CalcConfig(
    cylinderVolL: 6.8,
    fullPressureMpa: 30,
    consumptionLpm: 80,
    warnMin: 10,
    alarmMin: 5,
  );

  bool syncing = false;
  bool _manualRefreshInFlight = false;
  bool _legacySyncInFlight = false;
  int _nextSyncOpToken = 0;
  final Set<int> _activeManualRefreshOps = <int>{};
  final Set<int> _activeLegacySyncOps = <int>{};
  bool _lastConnectionLost = false;
  int _assistantPending = 0;
  bool get _assistantBusy => _assistantPending > 0;
  String? syncError;
  Timer? _tickTimer;

  /// 仅供倒计时页面刷新；不向根页面树广播，避免每秒重建所有 Tab。
  final ValueNotifier<int> clockTick = ValueNotifier<int>(0);
  final Map<String, int> _announced = {};
  bool _alarmReady = false;

  // 页面会先于异步初始化完成而显示。保留初始化 Future，确保用户在启动
  // 瞬间点击“新建警情”时，操作会等待 ApiClient 就绪，而不是被误判为断线。
  Future<void>? _initFuture;
  Future<void>? _authenticateFuture;
  Future<void>? _refreshConfigFuture;
  Future<void>? _syncFuture;
  Future<void>? _syncSettingsFuture;
  Future<void>? _optionalServicesFuture;
  int _lastOptionalServicesAttemptAt = 0;
  Future<void>? _loadRosterFuture;
  Future<void>? _keepAliveFuture;
  Future<void>? _sessionRefreshFuture;
  Future<void>? _authenticationInvalidationFuture;
  Timer? _sessionRefreshTimer;
  SyncCoordinator? _syncCoordinator;
  Future<void>? _realtimeStartFuture;
  SyncConnectionState syncConnectionState = SyncConnectionState.stopped;
  bool _refreshConfigAgain = false;
  bool _disposed = false;
  int _sessionGeneration = 0;

  /// 最近一次同步成功时间戳（0 = 从未成功过）
  int _lastSyncSuccessAt = 0;
  int _firstSyncFailureAt = 0;
  int _lastSyncErrorLogAt = 0;
  bool _syncSnapshotApplied = false;

  bool get connectionLost => isConnectionLost(
    lastSyncSuccessAt: _lastSyncSuccessAt,
    firstSyncFailureAt: _firstSyncFailureAt,
    nowMs: _nowMs(),
    thresholdMs: AppController.connectionLostThreshold,
    syncConnected: syncConnectionState == SyncConnectionState.connected,
  );

  Incident? currentIncident;
  List<Incident> activeIncidents = [];
  List<ExternalIncident> externalIncidents = [];
  bool externalIncidentsLoading = false;
  Future<void>? _externalIncidentsInFlight;
  bool externalReorganizing = false;
  List<IncidentForce> forces = [];
  bool _authenticated = false;
  AdminCapability? adminCapability;
  Timer? _adminCapabilityTimer;
  int _adminCapabilityRequest = 0;
  int offlineReviewCount = 0;
  bool _protectedDataRevoked = false;
  int _protectedDataEpoch = 0;
  bool get canReadKeySites =>
      !_protectedDataRevoked && _authenticated && !_isGuest && api != null;
  int get protectedDataEpoch => _protectedDataEpoch;
  bool get protectedDataRevoked => _protectedDataRevoked;
  KeySiteRecents get keySiteRecents => KeySiteRecents.instance;
  void _revokeProtectedData() {
    offlineReviewCount = 0;
    adminCapability = null;
    externalIncidents = [];
    externalIncidentsLoading = false;
    _externalIncidentsInFlight = null;
    _clearMemberReview();
    _adminCapabilityTimer?.cancel();
    _protectedDataRevoked = true;
    _protectedDataEpoch++;
    unawaited(keySiteRecents.clearAll());
    _notify();
  }

  bool _syncStarted = false;
  bool _isGuest = false;
  bool _enteredWithoutIncident = false;
  bool get isGuest => _isGuest;
  String memberReviewUnitName = '';
  bool canReviewMembers = false;
  bool memberReviewLoading = false;
  String? memberReviewError;
  List<UnitMember> pendingMembers = [];
  List<Map<String, dynamic>> memberReviewHistory = [];
  Future<void>? _memberReviewFuture;
  bool _memberReviewAgain = false;
  int _memberReviewGeneration = 0;
  bool _appInForeground = true;
  bool _pipActive = false;
  String _noteMediaMemberId = '';

  @visibleForTesting
  Duration get tickInterval => (_appInForeground || _pipActive)
      ? AppController.foregroundTickInterval
      : AppController.backgroundTickInterval;

  void _clearMemberReview() {
    memberReviewUnitName = '';
    _memberReviewGeneration++;
    _memberReviewFuture = null;
    _memberReviewAgain = false;
    canReviewMembers = false;
    memberReviewLoading = false;
    memberReviewError = null;
    pendingMembers = [];
    memberReviewHistory = [];
    pendingMemberCount = 0;
  }

  int pendingMemberCount = 0;

  /// 首次安装先完成单位验证码 + 实名认证，或选择游客模式，再进入警情选择。
  /// 已认证用户也可明确选择暂不加入警情，先使用 App 的通用功能。
  bool get needsAuthentication => !_authenticated && !_isGuest;
  bool get needsIncidentSelection =>
      !_isGuest && currentIncident == null && !_enteredWithoutIncident;

  /// 处警记录必须绑定警情；通用功能不受此限制。
  bool get requiresIncident => !_isGuest && currentIncident == null;

  /// 辅助问答使用独立请求通道，不阻塞业务实时连接。
  bool get assistantBusy => _assistantBusy;

  /// 启动时从 ALI OTA 检查到的新版本（非空 = 有新版本可更新）
  UpdateInfo? pendingUpdate;

  /// 是否已完成一次版本检查（区分「未检查」与「已是最新」）
  bool updateCheckDone = false;

  /// 最近一次检查失败的错误信息（非空 = 检查失败，设置页提示可重试）
  String? updateCheckError;

  bool _isCurrentSession(ApiClient a, int generation) =>
      !_disposed && generation == _sessionGeneration && identical(api, a);

  void _resetSessionHealth() {
    _lastSyncSuccessAt = 0;
    _firstSyncFailureAt = 0;
    _lastSyncErrorLogAt = 0;
    _syncSnapshotApplied = false;
    _lastConnectionLost = false;
    syncError = null;
    _announced.clear();
    _scheduled.clear();
    alarm.resetSession();
  }

  void _notify() {
    if (_disposed) return;
    if (_ownsAppScope) syncScopeBridge();
    notifyListeners();
  }

  /// 下拉刷新：等待一次实际同步完成（与轮询互斥），供刷新控件与失败反馈使用
  bool _isNetworkError(Object error) =>
      error is TimeoutException ||
      (error is ApiException && (error.statusCode ?? 0) >= 500) ||
      error.toString().contains('SocketException') ||
      error.toString().contains('ClientException') ||
      error.toString().contains('Connection closed');

  /// 编辑日志条目：text/category 传 null 表示不改

  // --- Cross-part contract declarations ---
  void _restartTickTimer();
  void _startAuthenticatedServices();
  void _initGuestIncident();
  Future<void> _refreshSession({bool force = false});
  void _handleAuthenticationFailure(ApiException error);
  Future<void> _invalidateAuthenticationOnce();
  Future<void> refreshAdminCapability();
  Future<void> refreshPendingMembersCount();
  Future<void> _ensureOptionalServices({bool force = false});
  Future<void> _ensureApiReady();
  Future<void> syncKeepAlive();
  Future<void> syncSettings();
  Future<void> refreshConfig();
  Future<void> _stopKeepAliveSafely();
  void _recomputeSyncing();
  void _reportMainSnapshotToKeepAlive();
  void _trackRealtimeStart(Future<void> future);
  void startSync();
  Future<void> sync();
  Future<void> _startRealtimeSync();
  void _applySyncSnapshot(Map<String, dynamic> snapshot);
  void _applySyncEvent(SyncEvent event);
  Future<void> refreshNow();
  Future<void> _clearScheduledNotifications();
  Future<void> _rescheduleNotifications();
  void _checkThresholds();
  Future<void> _restoreCachedExternalIncidents();
  Future<void> fetchExternalIncidents({bool forceRefresh = false});
  Future<void> refreshIncidentData(String id);
  Future<void> loadRoster();
  Future<void> _cacheRoster(String unitId);
  Future<void> _ensureLocalRoster();
  Future<void> _clearRosterCache();
  Future<Note> addNote(String text, {String? category, String? opId});
  Future<void> drainNoteMediaUploads({Set<String>? allowedIncidentIds});
}
