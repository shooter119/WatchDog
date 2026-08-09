import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/alarm_service.dart';
import '../services/chat_history.dart';
import '../services/foreground_keep_alive.dart';
import '../services/local_asr_service.dart';
import '../services/local_parser.dart';
import '../services/op_log_service.dart';
import '../services/offline_queue.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/tts_service.dart';
import '../services/update_service.dart';

class AppController extends ChangeNotifier {
  final LocalAsrService? localAsr;
  final LocalParser localParser = LocalParser();
  ApiClient? api;
  final AlarmService alarm = AlarmService();
  final TtsService tts = TtsService();

  /// 语音识别联网开关：开 = 云端优先失败自动切本地；关 = 强制本地。
  /// 默认开启（云端优先，精度高）；手动关闭时提示下载本地模型
  bool asrCloudEnabled = true;

  /// 语义解析联网开关：开 = 云端优先失败自动切本地；关 = 强制本地
  bool parseCloudEnabled = true;

  AppController({this.localAsr});

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
  String? syncError;
  Timer? _pollTimer;
  Timer? _tickTimer;
  final Map<String, int> _announced = {};
  bool _alarmReady = false;

  // 页面会先于异步初始化完成而显示。保留初始化 Future，确保用户在启动
  // 瞬间点击“新建警情”时，操作会等待 ApiClient 就绪，而不是被误判为断线。
  Future<void>? _initFuture;

  /// 最近一次同步成功时间戳（0 = 从未成功过）
  int _lastSyncSuccessAt = 0;

  /// 平滑断线判定：最近 [connectionLostThreshold] 毫秒内无一次同步成功才视为断线，
  /// 避免网络瞬时抖动导致连接状态频繁变红。从未成功过时乐观视为已连接。
  static const int connectionLostThreshold = 30000;

  bool get connectionLost {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSyncSuccessAt <= 0) {
      // 从未同步成功 → 有 syncError 说明已尝试且失败，应显示中断
      return syncError != null;
    }
    return now - _lastSyncSuccessAt > connectionLostThreshold;
  }

  Incident? currentIncident;
  List<Incident> activeIncidents = [];
  List<IncidentForce> forces = [];
  bool get needsIncidentSelection => currentIncident == null;

  /// 启动时自动检查到的新版本（非空 = 有新版本可更新，设置页据此显示提示）
  UpdateInfo? pendingUpdate;

  /// 是否已完成一次版本检查（区分「未检查」与「已是最新」）
  bool updateCheckDone = false;

  /// 最近一次检查失败的错误信息（非空 = 检查失败，设置页提示可重试）
  String? updateCheckError;

  /// 启动静默检查更新：失败不打扰用户，只更新状态供设置页展示
  Future<void> checkUpdateSilently() async {
    try {
      final (info, error) = await UpdateService().checkForUpdate();
      pendingUpdate = info;
      updateCheckError = error;
    } catch (e) {
      // 网络/解析失败静默，用户可在设置页手动检查
      updateCheckError = '$e';
    }
    updateCheckDone = true;
    notifyListeners();
  }

  /// 记录一次版本检查结果（设置页手动检查后调用，刷新共享提示状态）
  void recordUpdateCheck(UpdateInfo? info, String? error) {
    pendingUpdate = info;
    updateCheckError = error;
    updateCheckDone = true;
    notifyListeners();
  }

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initInternal();
    _initFuture = future;
    return future;
  }

  Future<void> _initInternal() async {
    // 先建立 API 客户端并启动核心同步。TTS、通知和后台值守属于可选
    // 能力，不能阻断新建/加入警情等核心服务器操作。
    await refreshConfig();
    startSync();
    loadRoster();
    // 启动后同步个人设置（服务器较新拉取、本地较新推送）
    syncSettings();
    // 启动后补传上次未上传完的操作日志（fire-and-forget）
    OpLogService.instance.flush(api: api);
    // 报警、TTS 和后台值守在后台初始化，任何系统权限/插件问题都不影响
    // 活跃警情列表与新建警情。
    unawaited(_initOptionalServices());
  }

  Future<void> _initOptionalServices() async {
    try {
      await tts.init();
    } catch (e) {
      debugPrint('TtsService init failed: $e');
    }
    try {
      await alarm.init();
      _alarmReady = true;
      await _rescheduleNotifications();
    } catch (e) {
      debugPrint('AlarmService init failed: $e');
    }
    try {
      await syncKeepAlive();
    } catch (e) {
      debugPrint('ForegroundKeepAlive start failed: $e');
    }
  }

  /// 等待启动初始化完成。某些页面在初始化 Future 完成前就可以交互，
  /// 需要使用 API 的操作必须先经过这里。
  Future<void> _ensureApiReady() async {
    if (api != null) return;
    final initFuture = _initFuture;
    if (initFuture != null) await initFuture;
    if (api == null) await refreshConfig();
  }

  /// 保活服务与本地设置同步：开启时启动并更新配置，关闭时停止
  Future<void> syncKeepAlive() async {
    final enabled = await Settings.keepAliveEnabled;
    if (!enabled) {
      await ForegroundKeepAlive.stop();
      return;
    }
    await ForegroundKeepAlive.start(
      serverUrl: await Settings.serverUrl,
      incidentId: await Settings.currentIncidentId,
      token: await Settings.apiToken,
      warnMin: calcConfig.warnMin,
      alarmMin: calcConfig.alarmMin,
    );
  }

  /// 用户设置云同步：服务器较新则拉取覆盖本地并生效，本地较新则推送，一致跳过
  Future<void> syncSettings() async {
    final a = api;
    if (a == null) return;
    try {
      final remote = await a.fetchUserSettings();
      final remoteAt = remote['updatedAt'] as int;
      final localAt = await Settings.modifiedAt;
      if (remoteAt > localAt) {
        await Settings.applyFromServer(
          remote['settings'] as Map<String, dynamic>,
          updatedAt: remoteAt,
        );
        await refreshConfig();
      } else if (remoteAt < localAt) {
        await a.pushUserSettings(await Settings.toSyncMap());
      }
    } catch (_) {
      // 网络失败静默，下次启动或保存设置时再试
    }
  }

  Future<void> refreshConfig() async {
    final serverUrl = await Settings.serverUrl;
    final incidentId = await Settings.currentIncidentId;
    final token = await Settings.apiToken;
    api = ApiClient(
      baseUrl: serverUrl,
      incidentId: incidentId,
      apiToken: token,
      deviceId: await OpLogService.instance.deviceId,
      actorName: await Settings.realName,
    );
    debugPrint(
      'WatchDog config ready: url=$serverUrl, '
      'incident=${incidentId.isEmpty ? 'none' : 'selected'}, '
      'token=${token.isNotEmpty ? 'configured' : 'empty'}, '
      'actor=${(await Settings.realName).isEmpty ? 'empty' : 'configured'}',
    );
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
    notifyListeners();
  }

  void startSync() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => sync());
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkThresholds();
      notifyListeners();
    });
    sync();
  }

  Future<void> sync() async {
    if (syncing || api == null) return;
    syncing = true;
    try {
      await OfflineQueue.instance.drain((id) => api!.forIncident(id));
      activeIncidents = await api!.fetchIncidents(status: 'active');
      final savedId = await Settings.currentIncidentId;
      if (savedId.isEmpty) {
        currentIncident = null;
        entries = [];
        notes = [];
        forces = [];
      } else {
        final incident = await api!.fetchIncident(savedId);
        if (!incident.isActive) {
          currentIncident = null;
          await Settings.setCurrentIncidentId('');
          entries = [];
          notes = [];
          forces = [];
        } else {
          currentIncident = incident;
          entries = await api!.fetchEntries();
          try {
            notes = await api!.fetchNotes();
          } catch (_) {}
          try {
            forces = await api!.fetchIncidentForces();
          } catch (_) {}
        }
      }
      syncError = null;
      _lastSyncSuccessAt = DateTime.now().millisecondsSinceEpoch;
      await _rescheduleNotifications();
    } catch (e) {
      syncError = e.toString();
      debugPrint('WatchDog sync failed: $e');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// 下拉刷新：等待一次实际同步完成（与轮询互斥），供刷新控件与失败反馈使用
  Future<void> refreshNow() => sync();

  /// 新条目到达时调度本地通知；exitAt 变化（改名/压力复核）时重新调度
  final Map<String, int> _scheduled = {};

  Future<void> _rescheduleNotifications() async {
    if (!_alarmReady) return;
    final active = entries.where((e) => e.isActive).toList();
    final activeIds = active.map((e) => e.id).toSet();
    final allIds = entries.map((e) => e.id).toSet();

    for (final e in active) {
      if (_scheduled[e.id] != e.exitAt) {
        _scheduled[e.id] = e.exitAt;
        await alarm.cancelForEntry(e.id);
        await alarm.scheduleForEntry(
          e,
          warnMin: calcConfig.warnMin,
          alarmMin: calcConfig.alarmMin,
        );
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
      alarm.startAlarmLoop();
    } else {
      alarm.stopAlarm();
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
      final duration =
          (calcConfig.cylinderVolL *
                  pressureMpa *
                  10 /
                  calcConfig.consumptionLpm)
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
      );
    }
    // 提交成功立即插入本地列表并通知（看板即时显示倒计时），
    // 不依赖 sync 网络结果——网络不稳时同步失败也不影响本地展示
    entries = [e, ...entries.where((x) => x.id != e.id)];
    notifyListeners();
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
      e = await api!.updateEntry(id: id, pressureMpa: pressureMpa, opId: op);
    } catch (error) {
      if (!_isNetworkError(error) || currentIncident == null) rethrow;
      await OfflineQueue.instance.enqueue(
        incidentId: currentIncident!.id,
        type: 'pressure',
        occurredAt: DateTime.now().millisecondsSinceEpoch,
        clientOpId: op.isEmpty
            ? 'offline-pressure-${DateTime.now().microsecondsSinceEpoch}'
            : op,
        payload: {'entry_id': id, 'pressure_mpa': pressureMpa},
      );
      e = current;
    }
    await sync();
    return e;
  }

  Future<void> markExited(String id, {String? opId}) async {
    try {
      await api!.markExited(id, opId: opId);
    } catch (error) {
      if (!_isNetworkError(error) || currentIncident == null) rethrow;
      await OfflineQueue.instance.enqueue(
        incidentId: currentIncident!.id,
        type: 'exit',
        occurredAt: DateTime.now().millisecondsSinceEpoch,
        clientOpId:
            opId ?? 'offline-exit-${DateTime.now().microsecondsSinceEpoch}',
        payload: {'entry_id': id},
      );
    }
    await sync();
  }

  Future<void> selectIncident(String id) async {
    await Settings.setCurrentIncidentId(id);
    await refreshConfig();
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
      deviceId: await OpLogService.instance.deviceId,
      actorName: name,
    );
    debugPrint('WatchDog createIncident: api=ready, actor=configured');
    final incident = await a.createIncident(
      realName: name,
      opId: 'incident-create-${DateTime.now().microsecondsSinceEpoch}',
    );
    await Settings.setCurrentIncidentId(incident.id);
    await refreshConfig();
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
    notifyListeners();
    return updated;
  }

  Future<void> archiveCurrent() async {
    final a = api;
    if (a == null || currentIncident == null) throw StateError('未选择警情');
    await a.archiveIncident(currentIncident!.id);
    await Settings.setCurrentIncidentId('');
    currentIncident = null;
    entries = [];
    notes = [];
    forces = [];
    await refreshConfig();
    await sync();
  }

  /// 退出当前警情只清除本机选择，不归档服务器档案；之后仍可从活跃列表重新加入。
  Future<void> exitCurrentIncident() async {
    if (currentIncident == null) return;
    await Settings.setCurrentIncidentId('');
    currentIncident = null;
    entries = [];
    notes = [];
    forces = [];
    await refreshConfig();
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
    notifyListeners();
  }

  Future<void> removeForce(String forceId) async {
    final a = api;
    if (a == null || currentIncident == null) throw StateError('未选择警情');
    await a.deleteIncidentForce(forceId);
    forces = await a.fetchIncidentForces();
    currentIncident = await a.fetchIncident(currentIncident!.id);
    notifyListeners();
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
    notifyListeners();
    return note;
  }

  /// 进出场确认同步写入火场日志，只保留姓名和动作，不记录压力等业务字段。
  Future<Note> addActionLog({
    required Iterable<String> names,
    required String action,
    required String category,
    String? opId,
  }) {
    final cleanNames = names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (cleanNames.isEmpty) throw StateError('缺少火场日志人员');
    final text = cleanNames.map((name) => '$name$action').join('、');
    return addNote(text, category: category, opId: opId);
  }

  bool _isNetworkError(Object error) =>
      error is TimeoutException ||
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
    notifyListeners();
    return updated;
  }

  /// 智能体问答：读取本机历史（旧→新），不依赖警情或云端。
  Future<List<ChatMessage>> fetchChatHistory() => ChatHistory.load();

  /// 智能体问答：提问并返回 AI 回复。普通请求由服务端负责联网检索。
  Future<ChatMessage> askAssistant(
    String message, {
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final a = api;
    if (a == null) throw StateError('AI 服务未连接');
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
  }

  /// 兼容旧客户端的流式提问；当前辅助页默认使用 [askAssistant]，以支持联网检索。
  Future<String> askAssistantStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final a = api;
    if (a == null) throw StateError('AI 服务未连接');
    final reply = await a.sendChatMessageStream(
      message,
      onChunk: onChunk,
      opId: opId,
      history: history,
    );
    unawaited(
      ChatHistory.appendExchange(
        question: message,
        reply: reply,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ).catchError((_) {}),
    );
    return reply;
  }

  /// 清空本机辅助问答记录
  Future<void> clearChatHistory() async {
    await ChatHistory.clear();
  }

  Future<void> deleteNote(String id) async {
    await api!.deleteNote(id);
    notes = notes.where((n) => n.id != id).toList();
    notifyListeners();
  }

  /// 名单/热词本地缓存键（断网/服务器不可达时回退，保证本地识别热词与名单查看离线可用）
  static const _kCachedFirefighters = 'cached_firefighters';
  static const _kCachedHotwords = 'cached_hotwords';
  static const _kRosterInitialized = 'builtin_roster_initialized_v1';

  /// 拉取名单与热词：成功写入本地缓存；失败（断网/服务器不可达）回退缓存。
  /// 名单热词是本地识别的热词来源，火场无信号时也必须生效。
  Future<void> loadRoster() async {
    await _ensureLocalRoster();
    if (api == null) return;
    try {
      final f = await api!.fetchFirefighters();
      final h = await api!.fetchHotwords();
      // 服务器尚未完成种子初始化时，不要把装机自带名单和热词清空。
      if (f.isEmpty && h.isEmpty) {
        await _restoreCachedRoster();
        return;
      }
      firefighters = f;
      hotwords = h;
      notifyListeners();
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
      notifyListeners();
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
    notifyListeners();
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
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    tts.stop();
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
