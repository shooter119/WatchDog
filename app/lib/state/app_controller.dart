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
  Timer? _pollTimer;
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
  bool _refreshConfigAgain = false;
  bool _disposed = false;
  int _sessionGeneration = 0;

  /// 最近一次同步成功时间戳（0 = 从未成功过）
  int _lastSyncSuccessAt = 0;
  int _firstSyncFailureAt = 0;

  /// 平滑断线判定：最近 [connectionLostThreshold] 毫秒内无一次同步成功才视为断线，
  /// 避免网络瞬时抖动导致连接状态频繁变红。从未成功过时乐观视为已连接。
  static const int connectionLostThreshold = 30000;

  bool get connectionLost {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSyncSuccessAt <= 0) {
      // 首次启动的冷启动、网关实例唤醒或瞬时网络抖动不应立刻显示红色。
      // 连续失败超过阈值后再判定中断。
      return _firstSyncFailureAt > 0 &&
          now - _firstSyncFailureAt > connectionLostThreshold;
    }
    return now - _lastSyncSuccessAt > connectionLostThreshold;
  }

  Incident? currentIncident;
  List<Incident> activeIncidents = [];
  List<IncidentForce> forces = [];
  bool _authenticated = false;
  bool _syncStarted = false;

  /// 首次安装先完成单位验证码 + 实名认证，再进入警情选择。
  bool get needsAuthentication => !_authenticated;
  bool get needsIncidentSelection => currentIncident == null;

  /// 辅助问答占用独立网络通道时，暂停后台同步，避免请求堆积和 DNS/socket
  /// 争用。问答结束后下一轮 5 秒轮询会自动恢复。
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
    _authenticated =
        (await Settings.realName).isNotEmpty &&
        (await Settings.unitId).isNotEmpty &&
        (await Settings.unitName).isNotEmpty &&
        (await Settings.unitCode).isNotEmpty &&
        (await Settings.apiToken).isNotEmpty;
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

  /// 完成启动浮层中的单位认证，认证成功后浮层自动切换为警情选择阶段。
  Future<void> authenticate({
    required String unitName,
    required String realName,
    required String unitCode,
    required String apiToken,
  }) {
    final existing = _authenticateFuture;
    if (existing != null) return existing;
    final future = _authenticateInternal(
      unitName: unitName,
      realName: realName,
      unitCode: unitCode,
      apiToken: apiToken,
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
    required String apiToken,
  }) async {
    final unit = unitName.trim();
    final name = realName.trim();
    final code = unitCode.trim();
    final token = apiToken.trim();
    if (unit.isEmpty) throw StateError('请输入单位名称');
    if (name.isEmpty) throw StateError('请输入真实姓名');
    if (code.isEmpty) throw StateError('请输入单位验证码');
    if (token.isEmpty) throw StateError('请输入管理员提供的访问令牌');
    await _ensureApiReady();
    if (_disposed) throw StateError('应用控制器已释放');
    final bootstrap = ApiClient(
      baseUrl: await Settings.serverUrl,
      incidentId: '',
      apiToken: token,
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

    // 在切换门禁和持久化前，使用本次令牌完成第一条受保护请求。
    final protectedProbe = ApiClient(
      baseUrl: await Settings.serverUrl,
      incidentId: '',
      apiToken: token,
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

    await Settings.setApiToken(token);
    await Settings.setSessionToken(sessionToken);
    await Settings.setRealName(name);
    await Settings.setUnitId(unitId);
    await Settings.setUnitCode(code);
    await Settings.setUnitName(unitInfo['name']?.toString() ?? unit);
    await Settings.markModified(DateTime.now().millisecondsSinceEpoch);
    _authenticated = true;
    await refreshConfig();
    _startAuthenticatedServices();
    await sync();
    _notify();
  }

  /// 主动退出当前单位：清理本机认证信息和当前警情，回到启动认证浮层。
  Future<void> leaveUnit() async {
    final activeApi = api;
    await OpLogService.instance.flushLocal();
    _sessionGeneration++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
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
  /// 闸门避免故障插件导致每 5 秒重复初始化和刷日志。
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
    final token = await Settings.apiToken;
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
      token: token,
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
    final serverUrl = await Settings.serverUrl;
    final incidentId = await Settings.currentIncidentId;
    final token = await Settings.apiToken;
    final sessionToken = await Settings.sessionToken;
    final unitId = await Settings.unitId;
    final unitCode = await Settings.unitCode;
    final nextApi = ApiClient(
      baseUrl: serverUrl,
      incidentId: incidentId,
      apiToken: token,
      sessionToken: sessionToken,
      deviceId: await OpLogService.instance.deviceId,
      actorName: await Settings.realName,
      unitId: unitId,
      unitCode: unitCode,
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
      'token=${token.isNotEmpty ? 'configured' : 'empty'}, '
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
    _notify();
  }

  void startSync() {
    if (_disposed || needsAuthentication) return;
    if (_syncStarted) {
      // 看板“重试”入口复用现有定时器，只补发一次合并后的同步请求，
      // 避免重复创建 5 秒/1 秒计时器而又让手动重试失效。
      unawaited(sync());
      return;
    }
    _syncStarted = true;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => sync());
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkThresholds();
      clockTick.value++;
    });
    sync();
  }

  Future<void> sync() {
    if (_disposed || _assistantBusy || api == null) {
      return Future<void>.value();
    }
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
              e.code == 'API_TOKEN_INVALID' ||
              e.code == 'SESSION_REQUIRED' ||
              e.code == 'SESSION_INVALID' ||
              e.code == 'SESSION_EXPIRED')) {
        await _invalidateAuthentication();
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
    _pollTimer?.cancel();
    _pollTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _syncStarted = false;
    _syncFuture = null;
    _keepAliveFuture = null;
    syncing = false;
    await _stopKeepAliveSafely();
    await _clearScheduledNotifications();
    await Settings.setCurrentIncidentId('');
    await Settings.setApiToken('');
    await Settings.setSessionToken('');
    await Settings.setRealName('');
    await Settings.setUnitId('');
    await Settings.setUnitCode('');
    await Settings.setUnitName('');
    final previousApi = api;
    api = null;
    previousApi?.dispose();
    currentIncident = null;
    activeIncidents = [];
    entries = [];
    notes = [];
    forces = [];
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
    // 新建警情是核心链路，不能因为启动时某个可选插件失败而没有
    // ApiClient。按当前设置现场补建客户端，确保请求得到真实的网络/服务端错误。
    final a = api ??= ApiClient(
      baseUrl: await Settings.serverUrl,
      incidentId: await Settings.currentIncidentId,
      apiToken: await Settings.apiToken,
      sessionToken: await Settings.sessionToken,
      deviceId: await OpLogService.instance.deviceId,
      actorName: name,
      unitId: await Settings.unitId,
      unitCode: await Settings.unitCode,
    );
    debugPrint('WatchDog createIncident: api=ready, actor=configured');
    final incident = await a.createIncident(
      realName: name,
      opId: 'incident-create-${DateTime.now().microsecondsSinceEpoch}',
    );
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

  /// 名单/热词本地缓存键（断网/服务器不可达时回退，保证本地识别热词与名单查看离线可用）
  static const _kCachedFirefighters = 'cached_firefighters';
  static const _kCachedHotwords = 'cached_hotwords';
  static const _kRosterInitialized = 'builtin_roster_initialized_v1';

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
    await _ensureLocalRoster();
    if (_disposed || api == null) return;
    final a = api!;
    try {
      final f = await a.fetchFirefighters();
      final h = await a.fetchHotwords();
      if (_disposed || !identical(api, a)) return;
      // 服务器尚未完成种子初始化时，不要把装机自带名单和热词清空。
      if (f.isEmpty && h.isEmpty) {
        await _restoreCachedRoster();
        return;
      }
      firefighters = f;
      hotwords = h;
      _notify();
      await _cacheRoster();
    } catch (_) {
      await _restoreCachedRoster();
    }
  }

  Future<void> _cacheRoster() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kCachedFirefighters,
        jsonEncode(firefighters.map((f) => f.name).toList()),
      );
      await sp.setString(
        _kCachedHotwords,
        jsonEncode(hotwords.map((h) => h.word).toList()),
      );
      await sp.setBool(_kRosterInitialized, true);
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  Future<void> _restoreCachedRoster() async {
    try {
      final sp = await SharedPreferences.getInstance();
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
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool(_kRosterInitialized) != true) {
      // 兼容旧版本已经写入的本地缓存，不能被首次初始化的默认值覆盖。
      if (sp.containsKey(_kCachedFirefighters) ||
          sp.containsKey(_kCachedHotwords)) {
        await sp.setBool(_kRosterInitialized, true);
        await _restoreCachedRoster();
        return;
      }
      _loadBuiltinDefaults();
      await _cacheRoster();
      return;
    }
    await _restoreCachedRoster();
  }

  /// 内置默认名单与热词（与后端 seed 数据一致，首次安装/离线兜底）
  void _loadBuiltinDefaults() {
    firefighters = _defaultFirefighterNames
        .map((n) => Firefighter(id: '', name: n))
        .toList();
    hotwords = _defaultHotwordTerms
        .map((w) => Hotword(id: '', word: w))
        .toList();
    _notify();
  }

  static const _defaultFirefighterNames = [
    // 大队部
    '李翔', '盛承华', '楼松超', '徐向相', '柯峰', '祝彪',
    // 龙翔路消防救援站
    '陆河圣', '洪辰', '沈松鹏', '金志明', '陈俊鹏', '叶华杰', '杨熙豪', '施豪杰', '袁超', '马李臣',
    '邢中本', '何家琦', '余贤耀', '徐莘焕', '杨小杰', '祝徐迁', '方文斌', '徐昊扬', '郑丽文', '郑怡',
    '郑涛', '占鑫涛', '叶健智', '胡海龙', '伊余健', '曹建罡', '马鑫', '徐康', '张烜烨', '李微',
    '储嘉俊', '毛伟', '陈俊安', '赵建平', '吴拥军', '路康清', '毕灵珂', '刘羽杰', '陈鑫', '廖淑明', '毛泽旭',
    // 永安路消防救援站
    '林成成', '程晓波', '郭逸', '蓝程雄', '成帅', '姚肖江', '毕文龙', '周志峰', '吕文建', '刘林辉',
    '齐征臣', '严仕华', '袁友顺', '劳凯董', '方罗进', '马俊', '刘振坤', '贺智成', '丁以强', '易子云',
    '李瑞', '宋宇', '宁成鑫', '甲巴有拉', '吉布小夫', '方梦龙',
    // 兴园消防救援站
    '游方远', '巫垚东', '万自良', '戴晓明', '李志鹏', '徐小龙', '吴鹏晖', '叶程刚', '陈嘉豪', '姚顺',
    '贺官', '孙国彬', '吴志云', '陈子俊', '何金伟', '周子俊', '何哲锴', '徐刚', '姜俊翰', '文闻',
    '张文浩', '宋博韬',
  ];

  static const _defaultHotwordTerms = [
    '龙游大队',
    '龙游',
    '龙翔路站',
    '永安路站',
    '兴园站',
    '头车',
    '两车',
    '三车',
    '四车',
    '内攻',
    '搜救',
  ];

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
    _pollTimer?.cancel();
    _tickTimer?.cancel();
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
/// 从未同步成功（lastSyncSuccessAt == 0）→ 乐观视为已连接；
/// 距上次成功超过 [thresholdMs] 毫秒 → 断线。
bool isConnectionLost({
  required int lastSyncSuccessAt,
  required int nowMs,
  int thresholdMs = 30000,
}) {
  if (lastSyncSuccessAt <= 0) return false;
  return nowMs - lastSyncSuccessAt > thresholdMs;
}

/// 后台值守只属于当前已认证且已选择的警情；开关偏好本身不因退出警情而改变。
bool shouldRunForegroundKeepAlive({
  required bool enabled,
  required bool authenticated,
  required String incidentId,
}) => enabled && authenticated && incidentId.trim().isNotEmpty;
