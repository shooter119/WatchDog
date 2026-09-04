import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/alarm_service.dart';
import '../services/chat_history.dart';
import '../services/diagnostic_log_service.dart';
import '../services/foreground_keep_alive.dart';
import '../services/local_asr_service.dart';
import '../services/local_parser.dart';
import '../services/op_log_service.dart';
import '../services/offline_queue.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/tts_service.dart';
import '../services/update_service.dart';
import '../services/sync_coordinator.dart';
import '../services/sync_reducer.dart';

typedef OfflineOperationEnqueuer =
    Future<void> Function({
      required String incidentId,
      required String type,
      required int occurredAt,
      required String clientOpId,
      required Map<String, dynamic> payload,
    });
typedef OfflineQueueDrainer = Future<void> Function();

class AppController extends ChangeNotifier {
  final LocalAsrService? localAsr;
  final OfflineOperationEnqueuer? _offlineOperationEnqueuer;
  final OfflineQueueDrainer? _offlineQueueDrainer;
  final LocalParser localParser = LocalParser();
  ApiClient? api;
  final AlarmService alarm = AlarmService();
  final TtsService tts = TtsService();

  /// 语音识别联网开关：开 = 云端优先失败自动切本地；关 = 强制本地。
  /// 默认开启（云端优先，精度高）；手动关闭时提示下载本地模型
  bool asrCloudEnabled = true;

  /// 语义解析联网开关：开 = 云端优先失败自动切本地；关 = 强制本地
  bool parseCloudEnabled = true;

  AppController({
    this.localAsr,
    OfflineOperationEnqueuer? offlineOperationEnqueuer,
    OfflineQueueDrainer? offlineQueueDrainer,
  }) : _offlineOperationEnqueuer = offlineOperationEnqueuer,
       _offlineQueueDrainer = offlineQueueDrainer;

  List<Entry> entries = [];
  List<Firefighter> firefighters = [];
  List<Hotword> hotwords = [];
  List<Note> notes = [];
  CalcConfig calcConfig = CalcConfig(
    cylinderVolL: 6.8,
    fullPressureMpa: 30,
    consumptionLpm: 80,
    warnMin: 10,
    alarmMin: 5,
  );

  bool syncing = false;
  bool _assistantBusy = false;
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

  /// 平滑断线判定：实时 WebSocket 已建立时保持在线；连接进入错误/重连后，
  /// 连续超过 [connectionLostThreshold] 毫秒没有同步成功才视为断线，避免网络
  /// 瞬时抖动导致连接状态频繁变红。从未成功过时乐观视为已连接。
  static const int connectionLostThreshold = 30000;

  bool get connectionLost => isConnectionLost(
    lastSyncSuccessAt: _lastSyncSuccessAt,
    firstSyncFailureAt: _firstSyncFailureAt,
    nowMs: DateTime.now().millisecondsSinceEpoch,
    thresholdMs: connectionLostThreshold,
    syncConnected: syncConnectionState == SyncConnectionState.connected,
  );

  Incident? currentIncident;
  List<Incident> activeIncidents = [];
  List<IncidentForce> forces = [];
  bool _authenticated = false;
  bool _syncStarted = false;

  static const Duration sessionRefreshCheckInterval = Duration(minutes: 15);
  static const Duration sessionRefreshLeadTime = Duration(hours: 1);

  /// 首次安装先完成单位验证码 + 实名认证，再进入警情选择。
  bool get needsAuthentication => !_authenticated;
  bool get needsIncidentSelection => currentIncident == null;

  /// 辅助问答使用独立请求通道，不阻塞业务实时连接。
  bool get assistantBusy => _assistantBusy;

  /// 启动时从 GitHub Releases 检查到的新版本（非空 = 有新版本可更新）
  UpdateInfo? pendingUpdate;

  /// 是否已完成一次版本检查（区分「未检查」与「已是最新」）
  bool updateCheckDone = false;

  /// 最近一次检查失败的错误信息（非空 = 检查失败，设置页提示可重试）
  String? updateCheckError;

  /// 启动静默检查更新：失败不打扰用户，只更新状态供设置页展示
  Future<void> checkUpdateSilently() async {
    final opId = 'release-check-${DateTime.now().millisecondsSinceEpoch}';
    void trace(String stage, String message, String level) {
      OpLogService.instance.record(
        opId,
        stage,
        message,
        level: level,
        data: {'source': 'GitHub Releases'},
      );
    }

    try {
      final (info, error) = await UpdateService(
        logger: (stage, message, level) => trace(stage, message, level),
      ).checkForUpdate();
      pendingUpdate = info;
      updateCheckError = error;
    } catch (e) {
      // 网络/解析失败静默，用户可在设置页手动检查
      updateCheckError = '$e';
      trace('release_check_fail', '$e', 'error');
    }
    updateCheckDone = true;
    _notify();
  }

  /// 记录一次版本检查结果（设置页手动检查后调用，刷新共享提示状态）
  void recordUpdateCheck(UpdateInfo? info, String? error) {
    pendingUpdate = info;
    updateCheckError = error;
    updateCheckDone = true;
    _notify();
  }

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initInternal();
    _initFuture = future;
    future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        // 初始化失败允许用户稍后重试，不能把一次插件/配置异常永久缓存。
        if (identical(_initFuture, future)) _initFuture = null;
      },
    );
    return future;
  }

  Future<void> _initInternal() async {
    // 诊断日志独立于核心同步链路，初始化失败也不能阻塞 App 启动。
    unawaited(DiagnosticLogService.instance.init());
    // 先建立 API 客户端。首次安装必须先完成单位认证，认证前不拉取业务数据。
    await refreshConfig();
    if (_disposed) return;
    final sessionToken = await Settings.sessionToken;
    _authenticated =
        (await Settings.realName).isNotEmpty &&
        (await Settings.unitId).isNotEmpty &&
        (await Settings.unitName).isNotEmpty &&
        sessionToken.isNotEmpty;
    if (_authenticated) {
      final expiresAt = await Settings.sessionExpiresAt;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (expiresAt > 0 && expiresAt <= now) {
        await _invalidateAuthenticationOnce();
      } else if (expiresAt <= 0) {
        // 兼容升级前没有保存 expires_at 的会话：启动时立即向服务端校验并补齐。
        try {
          await _refreshSession(force: true);
        } on ApiException catch (error) {
          if (!ApiClient.isAuthenticationFailure(error)) rethrow;
        }
      }
    }
    // 认证前只恢复本地名单，不向服务端发送未认证请求；认证成功后由
    // _startAuthenticatedServices 统一发起一次远端刷新。
    await _ensureLocalRoster();
    if (_authenticated) {
      _startAuthenticatedServices();
    } else {
      _notify();
    }
  }

  void _startAuthenticatedServices() {
    if (_disposed || !_authenticated || _syncStarted) return;
    _startSessionRefreshTimer();
    startSync();
    // 认证前的名单请求会被服务端拒绝；认证完成后重新拉取，拿到单位当前名单。
    unawaited(loadRoster());
    // 启动后同步个人设置（服务器较新拉取、本地较新推送）
    syncSettings();
    // 启动后补传上次未上传完的操作日志（fire-and-forget）
    OpLogService.instance.flush(api: api);
    // 报警、TTS 和后台值守在后台初始化，任何系统权限/插件问题都不影响
    // 活跃警情列表与新建警情。
    unawaited(_ensureOptionalServices());
  }

  void _startSessionRefreshTimer() {
    _sessionRefreshTimer?.cancel();
    if (_disposed || !_authenticated) return;
    _sessionRefreshTimer = Timer.periodic(sessionRefreshCheckInterval, (_) {
      unawaited(
        _refreshSession().catchError((Object error, StackTrace stackTrace) {
          if (!ApiClient.isAuthenticationFailure(error)) {
            debugPrint('WatchDog session refresh failed: $error');
          }
        }),
      );
    });
  }

  /// App 从后台回到前台时立即核对会话，避免后台挂起期间错过定时续期。
  Future<void> handleAppResumed() async {
    try {
      await _refreshSession();
    } catch (error) {
      if (!ApiClient.isAuthenticationFailure(error) &&
          error is! StateError) {
        debugPrint('WatchDog resume session check failed: $error');
      }
    }
  }

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
    if (!force &&
        expiresAt > now + sessionRefreshLeadTime.inMilliseconds) {
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

  void _handleAuthenticationFailure(ApiException error) {
    if (_disposed || !ApiClient.isAuthenticationFailure(error)) return;
    unawaited(_invalidateAuthenticationOnce());
  }

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

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// 完成启动浮层中的单位认证，认证成功后浮层自动切换为警情选择阶段。
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
    await Settings.setSessionToken(sessionToken);
    await Settings.setSessionExpiresAt(sessionExpiresAt);
    await Settings.setRealName(name);
    await Settings.setUnitId(unitId);
    await Settings.setUnitCode(code);
    await Settings.setUnitName(unitInfo['name']?.toString() ?? unit);
    await Settings.markModified(DateTime.now().millisecondsSinceEpoch);
    _authenticated = true;
    await refreshConfig();
    _startAuthenticatedServices();
    await _realtimeStartFuture;
    _notify();
  }

  /// 主动退出当前单位：清理本机认证信息和当前警情，回到启动认证浮层。
  Future<void> leaveUnit() async {
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
    _syncFuture = null;
    _keepAliveFuture = null;
    syncing = false;
    try {
      await activeApi?.logout();
    } catch (_) {
      // 注销的安全底线是本地凭据清理；网络不可用时服务端会话自然过期。
    }
    await _stopKeepAliveSafely();
    await _clearScheduledNotifications();

    await Settings.setCurrentIncidentId('');
    await Settings.setApiToken('');
    await Settings.setSessionToken('');
    await Settings.setSessionExpiresAt(0);
    await Settings.setRealName('');
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
    await _clearRosterCache();
    await localAsr?.resetHotwords();
    _authenticated = false;
    _resetSessionHealth();
    await refreshConfig();
    _notify();
  }

  Future<void> _initOptionalServices(int generation) async {
    try {
      await tts.init();
    } catch (e) {
      debugPrint('TtsService init failed: $e');
    }
    try {
      await alarm.init();
      if (_disposed || generation != _sessionGeneration || !_authenticated) {
        return;
      }
      _alarmReady = true;
      await _rescheduleNotifications();
    } catch (e) {
      debugPrint('AlarmService init failed: $e');
    }
    if (_disposed || generation != _sessionGeneration || !_authenticated) {
      return;
    }
    try {
      await syncKeepAlive();
    } catch (e) {
      debugPrint('ForegroundKeepAlive start failed: $e');
    }
  }

  /// 可选插件初始化失败时允许在用户刷新或下一轮同步时重试，但用短暂
  /// 闸门避免故障插件导致重复初始化和刷日志。
  Future<void> _ensureOptionalServices({bool force = false}) {
    if (_disposed || !_authenticated) return Future<void>.value();
    if (_alarmReady) return Future<void>.value();
    final existing = _optionalServicesFuture;
    if (existing != null) return existing;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastOptionalServicesAttemptAt < 30000) {
      return Future<void>.value();
    }
    _lastOptionalServicesAttemptAt = now;
    final future = _initOptionalServices(_sessionGeneration);
    _optionalServicesFuture = future;
    future.then<void>(
      (_) {
        if (identical(_optionalServicesFuture, future)) {
          _optionalServicesFuture = null;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_optionalServicesFuture, future)) {
          _optionalServicesFuture = null;
        }
      },
    );
    return future;
  }

  /// 等待启动初始化完成。某些页面在初始化 Future 完成前就可以交互，
  /// 需要使用 API 的操作必须先经过这里。
  Future<void> _ensureApiReady() async {
    if (api != null) return;
    final initFuture = _initFuture;
    if (initFuture != null) await initFuture;
    if (api == null && !_disposed) await refreshConfig();
  }

  /// 保活服务与本地设置同步：开启时启动并更新配置，关闭时停止
  Future<void> syncKeepAlive() {
    if (_disposed) return Future<void>.value();
    final existing = _keepAliveFuture;
    if (existing != null) return existing;
    final future = _syncKeepAliveInternal(_sessionGeneration);
    _keepAliveFuture = future;
    future.then<void>(
      (_) {
        if (identical(_keepAliveFuture, future)) _keepAliveFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_keepAliveFuture, future)) _keepAliveFuture = null;
      },
    );
    return future;
  }

  Future<void> _syncKeepAliveInternal(int generation) async {
    final enabled = await Settings.keepAliveEnabled;
    if (_disposed || generation != _sessionGeneration) return;
    if (!enabled) {
      await _stopKeepAliveSafely();
      return;
    }
    if (!_authenticated) {
      await _stopKeepAliveSafely();
      return;
    }
    final serverUrl = await Settings.serverUrl;
    final incidentId = await Settings.currentIncidentId;
    final sessionToken = await Settings.sessionToken;
    final unitId = await Settings.unitId;
    final unitCode = await Settings.unitCode;
    if (_disposed || generation != _sessionGeneration || !_authenticated) {
      return;
    }
    if (!shouldRunForegroundKeepAlive(
      enabled: enabled,
      authenticated: _authenticated,
      incidentId: incidentId,
    )) {
      await _stopKeepAliveSafely();
      return;
    }
    await ForegroundKeepAlive.start(
      serverUrl: serverUrl,
      incidentId: incidentId,
      token: '',
      sessionToken: sessionToken,
      unitId: unitId,
      unitCode: unitCode,
      warnMin: calcConfig.warnMin,
      alarmMin: calcConfig.alarmMin,
    );
  }

  /// 用户设置云同步：服务器较新则拉取覆盖本地并生效，本地较新则推送，一致跳过
  Future<void> syncSettings() {
    if (_disposed || !_authenticated || api == null) {
      return Future<void>.value();
    }
    final existing = _syncSettingsFuture;
    if (existing != null) return existing;
    final future = _syncSettingsInternal(api!);
    _syncSettingsFuture = future;
    future.then<void>(
      (_) {
        if (identical(_syncSettingsFuture, future)) _syncSettingsFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_syncSettingsFuture, future)) _syncSettingsFuture = null;
      },
    );
    return future;
  }

  Future<void> _syncSettingsInternal(ApiClient a) async {
    try {
      final remote = await a.fetchUserSettings();
      final remoteAt = (remote['updatedAt'] as num?)?.toInt() ?? 0;
      final localAt = await Settings.modifiedAt;
      if (remoteAt > localAt) {
        final remoteSettings = remote['settings'];
        if (remoteSettings is! Map) return;
        await Settings.applyFromServer(
          Map<String, dynamic>.from(remoteSettings),
          updatedAt: remoteAt,
        );
        await refreshConfig();
      } else if (remoteAt < localAt) {
        await a.pushUserSettings(await Settings.toSyncMap());
      }
    } catch (_) {
      // 网络失败静默，下次启动或保存设置时再试
      // 该请求与警情同步共用连接池；不要因为可选设置同步失败而关闭
      // 核心请求池，下一轮同步会自然重试。
    }
  }

  Future<void> refreshConfig() {
    if (_disposed) return Future<void>.value();
    final existing = _refreshConfigFuture;
    if (existing != null) {
      _refreshConfigAgain = true;
      return existing;
    }
    final future = _refreshConfigLoop();
    _refreshConfigFuture = future;
    future.then<void>(
      (_) {
        if (identical(_refreshConfigFuture, future)) {
          _refreshConfigFuture = null;
          _refreshConfigAgain = false;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_refreshConfigFuture, future)) {
          _refreshConfigFuture = null;
          _refreshConfigAgain = false;
        }
      },
    );
    return future;
  }

  Future<void> _refreshConfigLoop() async {
    do {
      _refreshConfigAgain = false;
      await _refreshConfigOnce();
    } while (!_disposed && _refreshConfigAgain);
  }

  Future<void> _refreshConfigOnce() async {
    if (_disposed) return;
    final previousApi = api;
    final restartRealtime = _syncStarted && _syncCoordinator != null;
    if (restartRealtime) {
      await _syncCoordinator?.stop();
      _syncCoordinator = null;
    }
    final serverUrl = await Settings.serverUrl;
    final incidentId = await Settings.currentIncidentId;
    final sessionToken = await Settings.sessionToken;
    final unitId = await Settings.unitId;
    final unitCode = await Settings.unitCode;
    final nextApi = ApiClient(
      baseUrl: serverUrl,
      incidentId: incidentId,
      sessionToken: sessionToken,
      deviceId: await OpLogService.instance.deviceId,
      actorName: await Settings.realName,
      unitId: unitId,
      unitCode: unitCode,
      onAuthenticationFailure: _handleAuthenticationFailure,
    );
    if (_disposed) {
      nextApi.dispose();
      return;
    }
    api = nextApi;
    previousApi?.dispose();
    debugPrint(
      'WatchDog config ready: url=$serverUrl, '
      'incident=${incidentId.isEmpty ? 'none' : 'selected'}, '
      'actor=${(await Settings.realName).isEmpty ? 'empty' : 'configured'}',
    );
    // 有当前警情时顺手补传上次启动/异常遗留的诊断日志；没有警情时
    // /api/logs 会拒绝请求，日志仍保存在本机，待加入警情后重试。
    if (incidentId.isNotEmpty) {
      unawaited(DiagnosticLogService.instance.flush(api: nextApi));
    }
    tts.enabled = await Settings.ttsEnabled;
    alarm.soundEnabled = await Settings.alarmSoundEnabled;
    await ScreenOn.setKeepScreenOn(await Settings.keepScreenOn);
    asrCloudEnabled = await Settings.asrCloudEnabled;
    parseCloudEnabled = await Settings.parseCloudEnabled;
    // 本地设置为准：用户改的消耗率/容量/阈值立即生效，不被服务端配置覆盖
    calcConfig = CalcConfig(
      cylinderVolL: await Settings.cylinderVolL,
      fullPressureMpa: await Settings.fullPressureMpa,
      consumptionLpm: await Settings.consumptionLpm,
      warnMin: await Settings.warnMin,
      alarmMin: await Settings.alarmMin,
    );
    if (restartRealtime && _authenticated) {
      _realtimeStartFuture = _startRealtimeSync();
      unawaited(_realtimeStartFuture!);
    }
    _notify();
  }

  void startSync() {
    if (_disposed || needsAuthentication) return;
    if (_syncStarted) {
      unawaited(_syncCoordinator?.checkpointNow() ?? Future<void>.value());
      return;
    }
    _syncStarted = true;
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkThresholds();
      clockTick.value++;
    });
    _realtimeStartFuture = _startRealtimeSync();
    unawaited(_realtimeStartFuture!);
  }

  Future<void> sync() {
    if (_disposed || _assistantBusy || api == null) {
      return Future<void>.value();
    }
    final realtime = _syncCoordinator;
    if (realtime != null && realtime.running) return realtime.checkpointNow();
    final existing = _syncFuture;
    if (existing != null) return existing;
    final a = api!;
    final generation = _sessionGeneration;
    final future = _syncInternal(a, generation);
    _syncFuture = future;
    future.then<void>(
      (_) {
        if (identical(_syncFuture, future)) _syncFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_syncFuture, future)) _syncFuture = null;
      },
    );
    return future;
  }

  Future<void> _startRealtimeSync() async {
    final a = api;
    if (_disposed || !_authenticated || a == null) return;
    final incidentId = await Settings.currentIncidentId;
    if (_disposed || !_authenticated || !identical(api, a)) return;
    await _syncCoordinator?.stop();
    final coordinator = SyncCoordinator(
      api: a,
      onSnapshot: _applySyncSnapshot,
      onEvent: _applySyncEvent,
      onState: _handleSyncState,
    );
    _syncCoordinator = coordinator;
    await coordinator.start(incidentId: incidentId.isEmpty ? null : incidentId);
  }

  void _handleSyncState(SyncConnectionState state, Object? error) {
    syncConnectionState = state;
    if (state == SyncConnectionState.connected) {
      _lastSyncSuccessAt = DateTime.now().millisecondsSinceEpoch;
      _firstSyncFailureAt = 0;
      syncError = null;
    } else if (error != null) {
      _firstSyncFailureAt = _firstSyncFailureAt == 0
          ? DateTime.now().millisecondsSinceEpoch
          : _firstSyncFailureAt;
      syncError = error is TimeoutException ? '连接服务器超时，请检查网络后重试' : '$error';
    }
    syncing = state == SyncConnectionState.bootstrapping ||
        state == SyncConnectionState.connecting;
    _notify();
  }

  void _applySyncSnapshot(Map<String, dynamic> snapshot) {
    if (_disposed) return;
    final roster = snapshot['roster'] is Map
        ? Map<String, dynamic>.from(snapshot['roster'] as Map)
        : <String, dynamic>{};
    firefighters = SyncReducer.rosterNames(roster);
    hotwords = SyncReducer.rosterHotwords(roster);
    final active = snapshot['active_incidents'] as List? ?? const [];
    activeIncidents = active
        .whereType<Map>()
        .map((item) => Incident.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final incidentSnapshot = snapshot['incident_snapshot'];
    if (incidentSnapshot is Map) {
      final data = Map<String, dynamic>.from(incidentSnapshot);
      final incident = data['incident'];
      currentIncident = incident is Map
          ? Incident.fromJson(Map<String, dynamic>.from(incident))
          : currentIncident;
      entries = (data['entries'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Entry.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      notes = (data['notes'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Note.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      forces = (data['forces'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => IncidentForce.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } else if ((snapshot['cursors'] as Map?)?['incident'] == '0') {
      currentIncident = null;
      entries = [];
      notes = [];
      forces = [];
    }
    final unitId = (snapshot['unit'] as Map?)?['id']?.toString();
    if (unitId != null && unitId.isNotEmpty) unawaited(_cacheRoster(unitId));
    unawaited(localAsr?.updateHotwords([..._rosterNames, ..._hotwordTerms]));
    _lastSyncSuccessAt = DateTime.now().millisecondsSinceEpoch;
    _firstSyncFailureAt = 0;
    syncError = null;
    unawaited(_rescheduleNotifications());
    _notify();
  }

  void _applySyncEvent(SyncEvent event) {
    if (_disposed) return;
    final payload = event.payload;
    switch (event.eventType) {
      case 'incident.created':
      case 'incident.updated':
      case 'incident.archived':
        final raw = payload.isNotEmpty ? payload : null;
        if (raw == null) break;
        final incident = Incident.fromJson(raw);
        activeIncidents = [
          if (incident.isActive) incident,
          ...activeIncidents.where((item) => item.id != incident.id),
        ];
        if (currentIncident?.id == incident.id) {
          currentIncident = incident.isActive ? incident : null;
          if (!incident.isActive) {
            entries = [];
            notes = [];
            forces = [];
          }
        }
        break;
      case 'entry.created':
      case 'entry.pressure_updated':
      case 'entry.exited':
        if (payload.isEmpty) break;
        final entry = Entry.fromJson(payload);
        entries = [entry, ...entries.where((item) => item.id != entry.id)];
        break;
      case 'note.created':
      case 'note.updated':
        if (payload.isEmpty) break;
        final note = Note.fromJson(payload);
        notes = [note, ...notes.where((item) => item.id != note.id)];
        break;
      case 'note.deleted':
        final id = event.aggregateId ?? payload['id']?.toString();
        if (id != null) notes = notes.where((item) => item.id != id).toList();
        break;
      case 'force.upserted':
        if (payload.isEmpty) break;
        final force = IncidentForce.fromJson(payload);
        forces = [force, ...forces.where((item) => item.id != force.id)];
        break;
      case 'force.deleted':
        final id = event.aggregateId ?? payload['id']?.toString();
        if (id != null) forces = forces.where((item) => item.id != id).toList();
        break;
      case 'roster.firefighter_added':
        final firefighter = Firefighter.fromJson(payload);
        firefighters = [firefighter, ...firefighters.where((item) => item.id != firefighter.id)];
        unawaited(_cacheRoster(api?.unitId ?? ''));
        unawaited(localAsr?.updateHotwords([..._rosterNames, ..._hotwordTerms]));
        break;
      case 'roster.firefighter_removed':
        firefighters = firefighters.where((item) => item.id != (event.aggregateId ?? payload['id']?.toString())).toList();
        unawaited(localAsr?.updateHotwords([..._rosterNames, ..._hotwordTerms]));
        break;
      case 'roster.hotword_added':
        final hotword = Hotword.fromJson(payload);
        hotwords = [hotword, ...hotwords.where((item) => item.id != hotword.id)];
        unawaited(localAsr?.updateHotwords([..._rosterNames, ..._hotwordTerms]));
        break;
      case 'roster.hotword_removed':
        hotwords = hotwords.where((item) => item.id != (event.aggregateId ?? payload['id']?.toString())).toList();
        unawaited(localAsr?.updateHotwords([..._rosterNames, ..._hotwordTerms]));
        break;
    }
    _lastSyncSuccessAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(_rescheduleNotifications());
    _notify();
  }

  Future<void> _syncInternal(ApiClient a, int generation) async {
    syncing = true;
    // 让页面在慢请求期间立即进入“同步中”，而不是等请求结束后才收到
    // 一次性状态通知；这也避免短请求沿用上一轮“已连接”文案造成误导。
    _notify();
    try {
      final fetchedActiveIncidents = await a.fetchIncidents(status: 'active');
      if (!_isCurrentSession(a, generation)) return;
      activeIncidents = fetchedActiveIncidents;
      final savedId = await Settings.currentIncidentId;
      final allowedIncidentIds = {
        ...activeIncidents.map((incident) => incident.id),
        if (savedId.isNotEmpty) savedId,
      };
      final drain = _offlineQueueDrainer;
      if (drain != null) {
        await drain();
      } else {
        await OfflineQueue.instance.drain(
          (id) => a.forIncident(id),
          allowedIncidentIds: allowedIncidentIds,
        );
      }
      if (!_isCurrentSession(a, generation)) return;
      if (savedId.isEmpty) {
        currentIncident = null;
        entries = [];
        notes = [];
        forces = [];
      } else {
        final incident = await a.fetchIncident(savedId);
        if (!_isCurrentSession(a, generation)) return;
        if (!incident.isActive) {
          currentIncident = null;
          await Settings.setCurrentIncidentId('');
          entries = [];
          notes = [];
          forces = [];
        } else {
          currentIncident = incident;
          entries = await a.fetchEntries();
          if (!_isCurrentSession(a, generation)) return;
          try {
            notes = await a.fetchNotes();
          } catch (_) {}
          try {
            forces = await a.fetchIncidentForces();
          } catch (_) {}
          // 补传失败时服务端快照仍可能落后于本地。把活动队列按发生顺序
          // 重新投影到刚拉取的快照，避免下一轮同步把离线操作的即时反馈抹掉。
          try {
            await _applyOfflineProjection(savedId);
          } catch (error) {
            debugPrint('WatchDog offline projection failed: $error');
          }
        }
      }
      syncError = null;
      _lastSyncSuccessAt = DateTime.now().millisecondsSinceEpoch;
      _firstSyncFailureAt = 0;
      final activeEntries = entries.where((entry) => entry.isActive).toList()
        ..sort((a, b) => a.exitAt.compareTo(b.exitAt));
      ForegroundKeepAlive.reportMainSnapshot(
        activeCount: activeEntries.length,
        earliestExitAt: activeEntries.isEmpty ? 0 : activeEntries.first.exitAt,
      );
      await _rescheduleNotifications();
      unawaited(_ensureOptionalServices());
    } catch (e) {
      if (!_isCurrentSession(a, generation)) return;
      if (e is ApiException && e.code == 'INCIDENT_NOT_FOUND') {
        // 当前单位已无法访问本机保存的警情（例如切换单位、警情被撤销
        // 或服务端权限收紧）。不能继续展示上一单位的缓存快照，避免把
        // 旧警情、人员和压力数据误呈现给当前用户。
        await Settings.setCurrentIncidentId('');
        if (!_isCurrentSession(a, generation)) return;
        currentIncident = null;
        entries = [];
        notes = [];
        forces = [];
        syncError = null;
        _firstSyncFailureAt = 0;
        await _stopKeepAliveSafely();
        await _clearScheduledNotifications();
        return;
      }
      if (e is ApiException &&
          (e.code == 'UNIT_INVALID' ||
              e.code == 'UNIT_AUTH_REQUIRED' ||
              e.code == 'SESSION_REQUIRED' ||
              e.code == 'SESSION_INVALID' ||
              e.code == 'SESSION_EXPIRED')) {
        await _invalidateAuthenticationOnce();
        return;
      }
      // 请求级超时和 HttpClient 的连接/空闲超时负责回收失败连接；不能为了
      // 一次同步失败关闭共享客户端，否则会中断同时进行的日志或其他请求。
      _firstSyncFailureAt = _firstSyncFailureAt == 0
          ? DateTime.now().millisecondsSinceEpoch
          : _firstSyncFailureAt;
      syncError = e is TimeoutException ? '连接服务器超时，请检查网络后重试' : e.toString();
      debugPrint('WatchDog sync failed: $e');
    } finally {
      if (generation == _sessionGeneration && !_disposed) {
        syncing = false;
        _notify();
      }
    }
  }

  Future<void> _applyOfflineProjection(String incidentId) async {
    // 测试/嵌入方可注入自己的队列排空器；此时不能偷偷打开全局 sqflite
    // 数据库，否则替身隔离会失效，也会把平台数据库初始化带入核心同步。
    if (incidentId.isEmpty || _offlineQueueDrainer != null) return;
    final rows = await OfflineQueue.instance.pendingOperations(incidentId);
    if (rows.isEmpty) return;
    final author = await Settings.realName;
    final projection = applyOfflineOperationProjection(
      rows: rows,
      entries: entries,
      notes: notes,
      calcConfig: calcConfig,
      author: author,
    );
    entries = projection.$1;
    notes = projection.$2;
  }

  /// 将仍在本地待补传的业务操作重新叠加到服务端快照。
  /// 返回新列表，不修改传入集合，便于同步逻辑和回归测试复用。
  static (List<Entry>, List<Note>) applyOfflineOperationProjection({
    required Iterable<Map<String, Object?>> rows,
    required List<Entry> entries,
    required List<Note> notes,
    required CalcConfig calcConfig,
    required String author,
  }) {
    var projectedEntries = List<Entry>.of(entries);
    var projectedNotes = List<Note>.of(notes);
    for (final row in rows) {
      try {
        final rawPayload = row['payload'];
        if (rawPayload is! String) continue;
        final decoded = jsonDecode(rawPayload);
        if (decoded is! Map) continue;
        final payload = Map<String, dynamic>.from(decoded);
        final type = row['type']?.toString();
        final occurredAt = (row['occurred_at'] as num?)?.toInt() ?? 0;
        if (occurredAt <= 0) continue;
        switch (type) {
          case 'entry':
            final id = payload['entry_id']?.toString();
            final name = payload['name']?.toString();
            final pressure = _offlineNumber(payload['pressure_mpa']);
            if (id == null || id.isEmpty || name == null || name.isEmpty) {
              continue;
            }
            if (pressure == null || pressure <= 0) continue;
            final volume =
                _offlineNumber(payload['volume_l']) ?? calcConfig.cylinderVolL;
            final consumption =
                _offlineNumber(payload['consumption_lpm']) ??
                calcConfig.consumptionLpm;
            final duration = calcConfig
                .durationMinFor(
                  pressure,
                  cylinderVolL: volume,
                  consumptionLpm: consumption,
                )
                .round();
            final entry = Entry(
              id: id,
              name: name,
              pressureMpa: pressure,
              durationMin: duration,
              entryAt: occurredAt,
              exitAt: occurredAt + duration * 60000,
              source: 'offline',
              rawText: payload['raw_text']?.toString(),
              cylinderVolL: volume,
              consumptionLpm: consumption,
            );
            projectedEntries = [
              entry,
              ...projectedEntries.where((item) => item.id != id),
            ];
          case 'pressure':
            final id = payload['entry_id']?.toString();
            final pressure = _offlineNumber(payload['pressure_mpa']);
            if (id == null || id.isEmpty || pressure == null || pressure <= 0) {
              continue;
            }
            final index = projectedEntries.indexWhere((item) => item.id == id);
            if (index < 0) continue;
            final current = projectedEntries[index];
            final volume =
                _offlineNumber(payload['volume_l']) ??
                current.cylinderVolL ??
                calcConfig.cylinderVolL;
            final consumption =
                _offlineNumber(payload['consumption_lpm']) ??
                current.consumptionLpm ??
                calcConfig.consumptionLpm;
            final duration = calcConfig
                .durationMinFor(
                  pressure,
                  cylinderVolL: volume,
                  consumptionLpm: consumption,
                )
                .round();
            projectedEntries = [
              for (final item in projectedEntries)
                item.id == id
                    ? item.copyWith(
                        pressureMpa: pressure,
                        durationMin: duration,
                        exitAt: occurredAt + duration * 60000,
                        cylinderVolL: volume,
                        consumptionLpm: consumption,
                      )
                    : item,
            ];
          case 'exit':
            final id = payload['entry_id']?.toString();
            if (id == null || id.isEmpty) continue;
            projectedEntries = [
              for (final item in projectedEntries)
                item.id == id ? item.copyWith(exitedAt: occurredAt) : item,
            ];
          case 'note':
            final id = payload['note_id']?.toString();
            final text = payload['text']?.toString();
            if (id == null || id.isEmpty || text == null || text.isEmpty) {
              continue;
            }
            projectedNotes = [
              Note(
                id: id,
                text: text,
                category: payload['category']?.toString() ?? NoteCategory.other,
                author: author,
                createdAt: occurredAt,
                updatedAt: occurredAt,
              ),
              ...projectedNotes.where((item) => item.id != id),
            ];
        }
      } catch (_) {
        // 单条损坏的本地记录不能阻塞其他合法操作的恢复。
      }
    }
    return (projectedEntries, projectedNotes);
  }

  static double? _offlineNumber(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  Future<void> _invalidateAuthentication() async {
    _sessionGeneration++;
    await _syncCoordinator?.stop();
    _syncCoordinator = null;
    _realtimeStartFuture = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    _syncStarted = false;
    _syncFuture = null;
    _keepAliveFuture = null;
    syncing = false;
    await _stopKeepAliveSafely();
    await _clearScheduledNotifications();
    await Settings.setCurrentIncidentId('');
    await Settings.setApiToken('');
    await Settings.setSessionToken('');
    await Settings.setSessionExpiresAt(0);
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
    await _clearRosterCache();
    await localAsr?.resetHotwords();
    _authenticated = false;
    _resetSessionHealth();
    await refreshConfig();
    _notify();
  }

  bool _isCurrentSession(ApiClient a, int generation) =>
      !_disposed && generation == _sessionGeneration && identical(api, a);

  void _resetSessionHealth() {
    _lastSyncSuccessAt = 0;
    _firstSyncFailureAt = 0;
    syncError = null;
    _announced.clear();
    _scheduled.clear();
    alarm.resetSession();
  }

  Future<void> _clearScheduledNotifications() async {
    final ids = List<String>.of(_scheduled.keys);
    _scheduled.clear();
    if (!_alarmReady) return;
    for (final id in ids) {
      try {
        await alarm.cancelForEntry(id);
      } catch (_) {
        // 插件未就绪或已被系统回收时，清理本地状态仍应完成。
      }
    }
    try {
      await alarm.stopAlarm();
    } catch (_) {}
  }

  Future<void> _stopKeepAliveSafely() async {
    try {
      await ForegroundKeepAlive.stop();
    } catch (error) {
      debugPrint('ForegroundKeepAlive stop failed: $error');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 下拉刷新：等待一次实际同步完成（与轮询互斥），供刷新控件与失败反馈使用
  Future<void> refreshNow() {
    unawaited(_ensureOptionalServices(force: true));
    return sync();
  }

  /// 新条目到达时调度本地通知；exitAt 变化（改名/压力复核）时重新调度
  final Map<String, int> _scheduled = {};

  Future<void> _rescheduleNotifications() async {
    if (!_alarmReady) return;
    final active = entries.where((e) => e.isActive).toList();
    final activeIds = active.map((e) => e.id).toSet();
    final allIds = entries.map((e) => e.id).toSet();

    for (final e in active) {
      if (_scheduled[e.id] != e.exitAt) {
        try {
          await alarm.cancelForEntry(e.id);
          await alarm.scheduleForEntry(
            e,
            warnMin: calcConfig.warnMin,
            alarmMin: calcConfig.alarmMin,
          );
          _scheduled[e.id] = e.exitAt;
        } catch (_) {
          _scheduled.remove(e.id);
          rethrow;
        }
      }
    }
    // 已出火场或已消失的条目：取消通知
    for (final id in List.of(_scheduled.keys)) {
      if (!activeIds.contains(id) || !allIds.contains(id)) {
        _scheduled.remove(id);
        await alarm.cancelForEntry(id);
      }
    }
  }

  /// 每秒检查：剩余10分钟提醒、5分钟报警、超时报警（前台 TTS+声音）
  void _checkThresholds() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var inDanger = false;
    for (final e in entries.where((e) => e.isActive)) {
      final remaining = e.exitAt - now;
      if (remaining <= 0) {
        inDanger = true;
        _announce(e, 'timeout', '${e.name}超时！${e.name}超时！立即确认！');
      } else if (remaining <= calcConfig.alarmMin * 60000) {
        inDanger = true;
        _announce(
          e,
          'alarm',
          '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，立即撤离！',
        );
      } else if (remaining <= calcConfig.warnMin * 60000) {
        _announce(
          e,
          'warn',
          '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，准备撤离。',
        );
      }
    }
    // 红色（alarm/timeout）状态持续循环警报，全部脱险后停止
    if (inDanger) {
      unawaited(_startAlarmLoopSafely());
    } else {
      unawaited(_stopAlarmSafely());
    }
  }

  Future<void> _startAlarmLoopSafely() async {
    try {
      await alarm.startAlarmLoop();
    } catch (error) {
      debugPrint('AlarmService start loop failed: $error');
    }
  }

  Future<void> _stopAlarmSafely() async {
    try {
      await alarm.stopAlarm();
    } catch (error) {
      debugPrint('AlarmService stop failed: $error');
    }
  }

  void _announce(Entry e, String kind, String text) {
    final key = '${e.id}:$kind';
    if (_announced[key] != null) return;
    _announced[key] = DateTime.now().millisecondsSinceEpoch;
    tts.speak(text);
    alarm.fire(key, ttsText: text);
  }

  Future<Entry?> createEntryFromVoice({
    required String name,
    required double pressureMpa,
    String? rawText,
    bool force = false,
    double? volumeL,
    String? opId,
  }) async {
    final incident = currentIncident;
    if (incident == null) throw StateError('请先选择或新建警情');
    Entry e;
    try {
      e = await api!.createEntry(
        name: name,
        pressureMpa: pressureMpa,
        source: 'voice',
        rawText: rawText,
        force: force,
        volumeL: volumeL,
        consumptionLpm: calcConfig.consumptionLpm,
        opId: opId,
      );
    } catch (error) {
      if (!_isNetworkError(error)) rethrow;
      final id = 'offline-entry-${DateTime.now().microsecondsSinceEpoch}';
      final at = DateTime.now().millisecondsSinceEpoch;
      final volume = volumeL ?? calcConfig.cylinderVolL;
      final duration = (volume * pressureMpa * 10 / calcConfig.consumptionLpm)
          .round();
      await OfflineQueue.instance.enqueue(
        incidentId: incident.id,
        type: 'entry',
        occurredAt: at,
        clientOpId: opId ?? id,
        payload: {
          'entry_id': id,
          'name': name,
          'pressure_mpa': pressureMpa,
          'volume_l': volume,
          'consumption_lpm': calcConfig.consumptionLpm,
          'raw_text': rawText,
        },
      );
      e = Entry(
        id: id,
        name: name,
        pressureMpa: pressureMpa,
        durationMin: duration,
        entryAt: at,
        exitAt: at + duration * 60000,
        source: 'offline',
        rawText: rawText,
        cylinderVolL: volume,
        consumptionLpm: calcConfig.consumptionLpm,
      );
    }
    // 提交成功立即插入本地列表并通知（看板即时显示倒计时），
    // 不依赖 sync 网络结果——网络不稳时同步失败也不影响本地展示
    entries = [e, ...entries.where((x) => x.id != e.id)];
    _notify();
    await sync();
    return e;
  }

  /// 合并：同名已在场的记录按本次复核压力重新倒计时（保留原记录，不重复计数）
  Future<Entry> mergeEntryPressure({
    required String id,
    required double pressureMpa,
    String? opId,
  }) async {
    final e = await updatePressure(
      id: id,
      pressureMpa: pressureMpa,
      opId: opId,
    );
    await sync();
    return e;
  }

  /// 更新压力：对在场人员提交一次压力读数（动态耗气率的采样点，服务端差分重算倒计时）
  Future<Entry> updatePressure({
    required String id,
    required double pressureMpa,
    String? opId,
  }) async {
    final op = opId ?? '';
    OpLogService.instance.record(
      op,
      'pressure_report',
      '更新压力 ${pressureMpa}MPa',
      data: {'entryId': id},
    );
    final current = entries.firstWhere((entry) => entry.id == id);
    Entry e;
    try {
      e = await api!.updateEntry(
        id: id,
        pressureMpa: pressureMpa,
        consumptionLpm: calcConfig.consumptionLpm,
        opId: op,
      );
    } catch (error) {
      if (!_isNetworkError(error) || currentIncident == null) rethrow;
      final occurredAt = DateTime.now().millisecondsSinceEpoch;
      final volume = current.cylinderVolL ?? calcConfig.cylinderVolL;
      final consumption = current.consumptionLpm ?? calcConfig.consumptionLpm;
      final clientOpId = op.isEmpty
          ? 'offline-pressure-${DateTime.now().microsecondsSinceEpoch}'
          : op;
      final payload = {
        'entry_id': id,
        'pressure_mpa': pressureMpa,
        'volume_l': volume,
        'consumption_lpm': consumption,
      };
      final enqueue = _offlineOperationEnqueuer;
      if (enqueue != null) {
        await enqueue(
          incidentId: currentIncident!.id,
          type: 'pressure',
          occurredAt: occurredAt,
          clientOpId: clientOpId,
          payload: payload,
        );
      } else {
        await OfflineQueue.instance.enqueue(
          incidentId: currentIncident!.id,
          type: 'pressure',
          occurredAt: occurredAt,
          clientOpId: clientOpId,
          payload: payload,
        );
      }
      final duration = calcConfig
          .durationMinFor(
            pressureMpa,
            cylinderVolL: volume,
            consumptionLpm: consumption,
          )
          .round();
      e = current.copyWith(
        pressureMpa: pressureMpa,
        durationMin: duration,
        exitAt: occurredAt + duration * 60000,
        cylinderVolL: volume,
        consumptionLpm: consumption,
      );
    }
    entries = [for (final entry in entries) entry.id == id ? e : entry];
    _notify();
    await sync();
    return e;
  }

  Future<void> markExited(String id, {String? opId}) async {
    try {
      await api!.markExited(id, opId: opId);
    } catch (error) {
      if (!_isNetworkError(error) || currentIncident == null) rethrow;
      final exitedAt = DateTime.now().millisecondsSinceEpoch;
      await OfflineQueue.instance.enqueue(
        incidentId: currentIncident!.id,
        type: 'exit',
        occurredAt: exitedAt,
        clientOpId:
            opId ?? 'offline-exit-${DateTime.now().microsecondsSinceEpoch}',
        payload: {'entry_id': id},
      );
      entries = [
        for (final entry in entries)
          entry.id == id ? entry.copyWith(exitedAt: exitedAt) : entry,
      ];
      _notify();
    }
    await sync();
  }

  Future<void> selectIncident(String id, {Incident? knownIncident}) async {
    await _refreshSession();
    if (needsAuthentication) throw StateError('认证会话已过期，请重新认证');
    await Settings.setCurrentIncidentId(id);
    _sessionGeneration++;
    _syncFuture = null;
    _keepAliveFuture = null;
    await refreshConfig();
    unawaited(syncKeepAlive());
    // 列表或新建冲突响应已经带回了完整警情档案。先完成本机选择，
    // 详细人员/日志数据放到后台同步，避免网络抖动阻塞“加入警情”这个动作。
    if (knownIncident != null) {
      currentIncident = knownIncident;
      entries = [];
      notes = [];
      forces = [];
      _notify();
      unawaited(sync());
      return;
    }
    await sync();
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
    debugPrint('WatchDog createIncident: api=ready, actor=configured, op_id=$opId');
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
    _sessionGeneration++;
    _syncFuture = null;
    _keepAliveFuture = null;
    await refreshConfig();
    unawaited(syncKeepAlive());
    await sync();
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
    currentIncident = null;
    entries = [];
    notes = [];
    forces = [];
    await refreshConfig();
    unawaited(syncKeepAlive());
    await sync();
  }

  /// 退出当前警情只清除本机选择，不归档服务器档案；之后仍可从活跃列表重新加入。
  Future<void> exitCurrentIncident() async {
    if (currentIncident == null) return;
    await Settings.setCurrentIncidentId('');
    _sessionGeneration++;
    _syncFuture = null;
    _keepAliveFuture = null;
    currentIncident = null;
    entries = [];
    notes = [];
    forces = [];
    await refreshConfig();
    unawaited(syncKeepAlive());
    await sync();
  }

  Future<void> saveForce({
    String? forceId,
    required String stationName,
    String? stationId,
    required int vehicleCount,
    required int personnelCount,
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
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    final cat = category ?? NoteCategory.fromText(text);
    final author = await Settings.realName;
    Note note;
    try {
      note = await api!.createNote(
        text: text,
        category: cat,
        opId: opId,
        author: author,
      );
    } catch (error) {
      if (!_isNetworkError(error) || currentIncident == null) rethrow;
      final at = DateTime.now().millisecondsSinceEpoch;
      final noteId = 'offline-note-${DateTime.now().microsecondsSinceEpoch}';
      await OfflineQueue.instance.enqueue(
        incidentId: currentIncident!.id,
        type: 'note',
        occurredAt: at,
        clientOpId: opId ?? noteId,
        payload: {'note_id': noteId, 'text': text, 'category': cat},
      );
      note = Note(
        id: noteId,
        text: text,
        category: cat,
        author: author,
        createdAt: at,
        updatedAt: at,
      );
    }
    notes = [note, ...notes];
    _notify();
    return note;
  }

  /// 进出场确认同步写入火场日志，使用现场记录中的规范化作业表述。
  Future<Note> addActionLog({
    required Iterable<String> names,
    required String action,
    required String category,
    Map<String, double>? pressuresMpa,
    String? opId,
  }) {
    final cleanNames = names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (cleanNames.isEmpty) throw StateError('缺少火场日志人员');
    final text = switch (action) {
      '进场' =>
        cleanNames
            .map((name) {
              final pressure = pressuresMpa?[name];
              final pressureText = pressure == null
                  ? ''
                  : '，空气呼吸器压力${_formatPressureMpa(pressure)}兆帕';
              return '$name进入救援现场$pressureText';
            })
            .join('、'),
      '出场' => cleanNames.map((name) => '$name撤离救援现场').join('、'),
      _ => cleanNames.map((name) => '$name$action').join('、'),
    };
    return addNote(text, category: category, opId: opId);
  }

  static String _formatPressureMpa(double pressure) {
    return pressure == pressure.roundToDouble()
        ? pressure.toInt().toString()
        : pressure.toString();
  }

  bool _isNetworkError(Object error) =>
      error is TimeoutException ||
      (error is ApiException && (error.statusCode ?? 0) >= 500) ||
      error.toString().contains('SocketException') ||
      error.toString().contains('ClientException') ||
      error.toString().contains('Connection closed');

  /// 编辑日志条目：text/category 传 null 表示不改
  Future<Note> updateNote(String id, {String? text, String? category}) async {
    final updated = await api!.updateNote(
      id: id,
      text: text,
      category: category,
    );
    notes = notes.map((n) => n.id == id ? updated : n).toList();
    _notify();
    return updated;
  }

  /// 智能体问答：读取本机历史（旧→新），不依赖警情或云端。
  Future<List<ChatMessage>> fetchChatHistory() => ChatHistory.load();

  /// 智能体问答：提问并返回完整 AI 回复。
  Future<ChatMessage> askAssistant(
    String message, {
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final a = api;
    if (a == null) throw StateError('AI 服务未连接');
    _assistantBusy = true;
    try {
      final reply = await a.sendChatMessage(
        message,
        opId: opId,
        history: history,
      );
      await ChatHistory.appendExchange(
        question: message,
        reply: reply.content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      return reply;
    } finally {
      _assistantBusy = false;
    }
  }

  /// 流式提问：辅助页使用此路径，让首个 token 到达后立即显示。
  Future<String> askAssistantStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final a = api;
    if (a == null) throw StateError('AI 服务未连接');
    _assistantBusy = true;
    try {
      final reply = await a.sendChatMessageStream(
        message,
        onChunk: onChunk,
        opId: opId,
        history: history,
      );
      if (reply.trim().isEmpty) {
        throw StateError('辅助回复为空，请重试');
      }
      // 持久化不阻塞首屏回复；ChatHistory 内部队列保证追加/清空按入队顺序执行。
      unawaited(
        ChatHistory.appendExchange(
          question: message,
          reply: reply,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ).catchError((_) {}),
      );
      return reply;
    } finally {
      _assistantBusy = false;
    }
  }

  /// 释放辅助问答的底层 socket；Future 超时本身不等于取消网络请求。
  void cancelAssistantRequest() => api?.cancelChatRequest();

  /// 清空本机辅助问答记录
  Future<void> clearChatHistory() async {
    await ChatHistory.clear();
  }

  Future<void> deleteNote(String id) async {
    await api!.deleteNote(id);
    notes = notes.where((n) => n.id != id).toList();
    _notify();
  }

  /// 当前认证单位的名单/热词本地缓存。缓存必须绑定 unitId，不能跨单位复用。
  static const _kCachedFirefighters = 'cached_firefighters';
  static const _kCachedHotwords = 'cached_hotwords';
  static const _kCachedRosterUnitId = 'cached_roster_unit_id';

  /// 拉取名单与热词：成功写入本地缓存；失败（断网/服务器不可达）回退缓存。
  /// 名单热词是本地识别的热词来源，火场无信号时也必须生效。
  Future<void> loadRoster() {
    if (_disposed) return Future<void>.value();
    final existing = _loadRosterFuture;
    if (existing != null) return existing;
    final future = _loadRosterInternal();
    _loadRosterFuture = future;
    future.then<void>(
      (_) {
        if (identical(_loadRosterFuture, future)) _loadRosterFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_loadRosterFuture, future)) _loadRosterFuture = null;
      },
    );
    return future;
  }

  Future<void> _loadRosterInternal() async {
    if (_disposed || api == null) return;
    final configuredUnitId = await Settings.unitId;
    final unitId = configuredUnitId.isNotEmpty ? configuredUnitId : api!.unitId;
    if (unitId.isEmpty) return;
    await _restoreCachedRoster(unitId);
    if (_disposed || api == null) return;
    final a = api!;
    final generation = _sessionGeneration;
    try {
      final f = await a.fetchFirefighters();
      final h = await a.fetchHotwords();
      if (_disposed || generation != _sessionGeneration || !identical(api, a)) {
        return;
      }
      // 空数组是当前单位的合法词库状态，不能恢复其他单位或旧版本缓存。
      firefighters = f;
      hotwords = h;
      _notify();
      await _cacheRoster(unitId);
    } catch (_) {
      if (_disposed || generation != _sessionGeneration || !identical(api, a)) {
        return;
      }
      await _restoreCachedRoster(unitId);
    }
  }

  Future<void> _cacheRoster(String unitId) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kCachedRosterUnitId, unitId);
      await sp.setString(
        _kCachedFirefighters,
        jsonEncode(firefighters.map((f) => f.name).toList()),
      );
      await sp.setString(
        _kCachedHotwords,
        jsonEncode(hotwords.map((h) => h.word).toList()),
      );
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  Future<void> _restoreCachedRoster(String unitId) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getString(_kCachedRosterUnitId) != unitId) {
        firefighters = [];
        hotwords = [];
        _notify();
        return;
      }
      final fNames =
          (jsonDecode(sp.getString(_kCachedFirefighters) ?? '[]') as List)
              .map((e) => e.toString())
              .toList();
      final hWords =
          (jsonDecode(sp.getString(_kCachedHotwords) ?? '[]') as List)
              .map((e) => e.toString())
              .toList();
      firefighters = fNames.map((n) => Firefighter(id: '', name: n)).toList();
      hotwords = hWords.map((w) => Hotword(id: '', word: w)).toList();
      _notify();
    } catch (_) {
      // 缓存损坏时也回退内置默认
      _loadBuiltinDefaults();
    }
  }

  Future<void> _ensureLocalRoster() async {
    if (!_authenticated) {
      firefighters = [];
      hotwords = [];
      await _clearRosterCache();
      return;
    }
    final unitId = await Settings.unitId;
    if (unitId.isEmpty) return;
    await _restoreCachedRoster(unitId);
  }

  /// 未认证状态不加载任何单位姓名或单位词，避免把真实数据打进安装包。
  void _loadBuiltinDefaults() {
    firefighters = [];
    hotwords = [];
    _notify();
  }

  Future<void> _clearRosterCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kCachedRosterUnitId);
      await sp.remove(_kCachedFirefighters);
      await sp.remove(_kCachedHotwords);
      // 删除旧版本未绑定单位的缓存，避免认证切换时误用。
      await sp.remove('builtin_roster_initialized_v1');
    } catch (_) {}
  }

  List<String> get _rosterNames => firefighters.map((f) => f.name).toList();

  List<String> get _hotwordTerms => hotwords.map((h) => h.word).toList();

  /// 转写：云端优先（开关开时），失败/关闭开关时强制本地 sherpa-onnx
  Future<String> transcribeAudio(Uint8List bytes, {String? opId}) async {
    if (asrCloudEnabled && api != null) {
      try {
        final text = await api!.transcribe(bytes, opId: opId);
        if (text.trim().isNotEmpty) return text;
      } catch (e) {
        if (localAsr == null) rethrow;
        OpLogService.instance.record(
          opId ?? '',
          'transcribe_fallback',
          '云端转写失败，切换本地识别: $e',
          level: 'warn',
        );
      }
    }
    return _localTranscribe(bytes, opId: opId);
  }

  /// 实时云端会话失败后的本地识别入口，避免回退时再次请求云端。
  Future<String> transcribeAudioLocal(Uint8List bytes, {String? opId}) async {
    return _localTranscribe(bytes, opId: opId);
  }

  Future<String> _localTranscribe(Uint8List bytes, {String? opId}) async {
    final asr = localAsr;
    if (asr == null) throw StateError('未配置本地语音识别');
    final hotwords = [..._rosterNames, ..._hotwordTerms];
    // 热词注入埋点：可验证名单/术语是否真正进入本地识别（排查同音错字问题）
    OpLogService.instance.record(
      opId ?? '',
      'local_asr_hotwords',
      '本地识别热词 ${hotwords.length} 个',
      data: {'count': hotwords.length, 'sample': hotwords.take(8).toList()},
    );
    final text = await asr.transcribe(bytes, hotwords: hotwords);
    if (text.trim().isEmpty) {
      throw StateError('本地识别未听清，请再说一遍');
    }
    return text;
  }

  /// 语义解析：云端优先（开关开时），失败/关闭开关时强制本地规则解析
  Future<ParseResult> parseText(String text, {String? opId}) async {
    if (parseCloudEnabled && api != null) {
      try {
        return await api!.parse(text, opId: opId);
      } catch (e) {
        OpLogService.instance.record(
          opId ?? '',
          'parse_fallback',
          '云端解析失败，切换本地解析: $e',
          level: 'warn',
        );
      }
    }
    return localParser.parse(text, firefighters: _rosterNames);
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration++;
    unawaited(OpLogService.instance.flushLocal());
    unawaited(_syncCoordinator?.stop() ?? Future<void>.value());
    _tickTimer?.cancel();
    _sessionRefreshTimer?.cancel();
    _syncFuture = null;
    _keepAliveFuture = null;
    api?.dispose();
    unawaited(_stopKeepAliveSafely());
    unawaited(_clearScheduledNotifications());
    unawaited(localAsr?.dispose());
    tts.stop();
    clockTick.dispose();
    super.dispose();
  }
}

/// 平滑断线判定纯函数（可单测）：
/// 实时同步连接已建立时保持在线；从未同步成功（lastSyncSuccessAt == 0）
/// → 乐观视为已连接；距上次成功超过 [thresholdMs] 毫秒 → 断线。
bool isConnectionLost({
  required int lastSyncSuccessAt,
  required int nowMs,
  int thresholdMs = 30000,
  bool syncConnected = false,
  int firstSyncFailureAt = 0,
}) {
  if (syncConnected) return false;
  if (lastSyncSuccessAt <= 0) {
    // 首次启动的冷启动、网关实例唤醒或瞬时网络抖动不应立刻显示红色。
    return firstSyncFailureAt > 0 && nowMs - firstSyncFailureAt > thresholdMs;
  }
  return nowMs - lastSyncSuccessAt > thresholdMs;
}

/// 后台值守只属于当前已认证且已选择的警情；开关偏好本身不因退出警情而改变。
bool shouldRunForegroundKeepAlive({
  required bool enabled,
  required bool authenticated,
  required String incidentId,
}) => enabled && authenticated && incidentId.trim().isNotEmpty;
