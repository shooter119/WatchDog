import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/alarm_service.dart';
import '../services/foreground_keep_alive.dart';
import '../services/local_asr_service.dart';
import '../services/local_parser.dart';
import '../services/op_log_service.dart';
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

  /// 语音识别联网开关：开 = 云端优先失败自动切本地；关 = 强制本地
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
    consumptionLpm: 40,
    warnMin: 10,
    alarmMin: 5,
  );

  bool syncing = false;
  String? syncError;
  Timer? _pollTimer;
  Timer? _tickTimer;
  final Map<String, int> _announced = {};

  /// 最近一次同步成功时间戳（0 = 从未成功过）
  int _lastSyncSuccessAt = 0;

  /// 平滑断线判定：最近 [connectionLostThreshold] 毫秒内无一次同步成功才视为断线，
  /// 避免网络瞬时抖动导致连接状态频繁变红。从未成功过时乐观视为已连接。
  static const int connectionLostThreshold = 30000;

  bool get connectionLost => isConnectionLost(
        lastSyncSuccessAt: _lastSyncSuccessAt,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// 本场景已被某设备结束任务（归档）：非空时看板顶部显示"切换到新任务"横幅
  SceneState? sceneEnded;

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

  Future<void> init() async {
    await tts.init();
    await alarm.init();
    await refreshConfig();
    startSync();
    loadRoster();
    // 启动后同步个人设置（服务器较新拉取、本地较新推送）
    syncSettings();
    // 启动后补传上次未上传完的操作日志（fire-and-forget）
    OpLogService.instance.flush(api: api);
    // 后台值守：开关开启则拉起前台服务（进程保活 + 常驻通知栏）
    await syncKeepAlive();
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
      sceneCode: await Settings.sceneCode,
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
        await Settings.applyFromServer(remote['settings'] as Map<String, dynamic>, updatedAt: remoteAt);
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
    final sceneCode = await Settings.sceneCode;
    final token = await Settings.apiToken;
    api = ApiClient(
      baseUrl: serverUrl,
      sceneCode: sceneCode,
      apiToken: token,
      deviceId: await OpLogService.instance.deviceId,
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
      entries = await api!.fetchEntries();
      try {
        notes = await api!.fetchNotes();
      } catch (_) {
        // 日志拉取失败不影响主流程（entries 已成功）
      }
      // 本场景被其他设备归档：检测后驱动看板横幅（失败静默，不阻断主流程）。
      // identical 校验：结束任务换码瞬间，并发轮询可能仍持旧 api 实例，
      // 其检测结果属于旧场景，忽略避免横幅残留在新场景。
      if (sceneEnded == null) {
        try {
          final a2 = api;
          final state = await api!.fetchSceneState();
          if (identical(a2, api)) sceneEnded = state;
        } catch (_) {}
      }
      syncError = null;
      _lastSyncSuccessAt = DateTime.now().millisecondsSinceEpoch;
      await _rescheduleNotifications();
    } catch (e) {
      syncError = e.toString();
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
    final active = entries.where((e) => e.isActive).toList();
    final activeIds = active.map((e) => e.id).toSet();
    final allIds = entries.map((e) => e.id).toSet();

    for (final e in active) {
      if (_scheduled[e.id] != e.exitAt) {
        _scheduled[e.id] = e.exitAt;
        await alarm.cancelForEntry(e.id);
        await alarm.scheduleForEntry(e, warnMin: calcConfig.warnMin, alarmMin: calcConfig.alarmMin);
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
        _announce(e, 'alarm', '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，立即撤离！');
      } else if (remaining <= calcConfig.warnMin * 60000) {
        _announce(e, 'warn', '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，准备撤离。');
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
    final e = await api!.createEntry(
      name: name,
      pressureMpa: pressureMpa,
      source: 'voice',
      rawText: rawText,
      force: force,
      volumeL: volumeL,
      consumptionLpm: calcConfig.consumptionLpm,
      opId: opId,
    );
    await sync();
    return e;
  }

  /// 合并：同名已在场的记录按本次复核压力重新倒计时（保留原记录，不重复计数）
  Future<Entry> mergeEntryPressure({required String id, required double pressureMpa, String? opId}) async {
    final e = await api!.updateEntry(
      id: id,
      pressureMpa: pressureMpa,
      consumptionLpm: calcConfig.consumptionLpm,
      opId: opId,
    );
    await sync();
    return e;
  }

  /// 更新压力：对在场人员提交一次压力读数（动态耗气率的采样点，服务端差分重算倒计时）
  Future<Entry> updatePressure({required String id, required double pressureMpa, String? opId}) async {
    final op = opId ?? '';
    OpLogService.instance.record(op, 'pressure_report', '更新压力 ${pressureMpa}MPa', data: {'entryId': id});
    final e = await api!.updateEntry(id: id, pressureMpa: pressureMpa, opId: op);
    await sync();
    return e;
  }

  Future<void> markExited(String id, {String? opId}) async {
    await api!.markExited(id, opId: opId);
    await sync();
  }

  /// 新增火场随手记（语音分流自动入日志 / 手动添加）
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    final cat = category ?? NoteCategory.fromText(text);
    final note = await api!.createNote(text: text, category: cat, opId: opId);
    notes = [note, ...notes];
    notifyListeners();
    return note;
  }

  /// 编辑日志条目：text/category 传 null 表示不改
  Future<Note> updateNote(String id, {String? text, String? category}) async {
    final updated = await api!.updateNote(id: id, text: text, category: category);
    notes = notes.map((n) => n.id == id ? updated : n).toList();
    notifyListeners();
    return updated;
  }

  /// 智能体问答：拉取历史（旧→新）
  Future<List<ChatMessage>> fetchChatHistory() async {
    final a = api;
    if (a == null) throw StateError('未连接服务器');
    return a.fetchChatMessages();
  }

  /// 智能体问答：提问并返回 AI 回复
  Future<ChatMessage> askAssistant(String message, {String? opId}) async {
    final op = opId ?? '';
    OpLogService.instance.record(op, 'chat_ask', '向辅助提问', data: {'text': message});
    return await api!.sendChatMessage(message, opId: op);
  }

  /// 流式提问：onChunk 逐段回调增量内容，返回完整回复文本（低延迟逐字显示）
  Future<String> askAssistantStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
  }) async {
    final op = opId ?? '';
    OpLogService.instance.record(op, 'chat_ask', '向辅助提问', data: {'text': message});
    return await api!.sendChatMessageStream(message, onChunk: onChunk, opId: op);
  }

  /// 清空本场景问答记录
  Future<void> clearChatHistory() async {
    final a = api;
    if (a == null) return;
    await a.clearChatMessages();
  }

  /// 结束任务（归档）：服务端标记本场景已结束并分配新场景码 → 本机切换。
  /// 其他设备轮询检测到归档后经 [switchToNewScene] 汇聚到同一新场景。
  Future<String> endTask({String? opId}) async {
    final a = api;
    if (a == null) throw StateError('未连接服务器');
    final op = opId ?? '';
    OpLogService.instance.record(op, 'scene_end', '结束任务（归档场景）');
    final newCode = await a.endTask(opId: op);
    await Settings.setSceneCode(newCode);
    // 换码瞬间并发轮询可能正用旧 api 检测到旧场景已归档，强制清状态与数据，
    // 保证界面立即清零且不残留"本场景已结束"横幅（sync 若被轮询占用跳过，轮询随后会拉到新场景数据）
    sceneEnded = null;
    entries = [];
    notes = [];
    await refreshConfig();
    await sync();
    sceneEnded = null; // 兜底：旧 api 轮询在换码窗口写入的归档状态
    notifyListeners();
    OpLogService.instance.record(
      op,
      'scene_end_done',
      '任务已结束，切换到新场景',
      data: {'newScene': newCode},
    );
    OpLogService.instance.flush(api: api);
    return newCode;
  }

  /// 其他设备响应归档横幅：切换到服务端统一分配的新场景码（各设备汇聚同一码）
  Future<void> switchToNewScene() async {
    final s = sceneEnded;
    final newCode = s?.newScene;
    if (newCode == null || newCode.isEmpty) return;
    OpLogService.instance.record(
      '',
      'scene_switch',
      '切换到已归档任务的新场景',
      data: {'newScene': newCode},
    );
    await Settings.setSceneCode(newCode);
    sceneEnded = null;
    entries = [];
    notes = [];
    await refreshConfig();
    await sync();
    sceneEnded = null; // 兜底：换码窗口内旧 api 轮询写入的归档状态
    notifyListeners();
    OpLogService.instance.flush(api: api);
  }

  Future<void> deleteNote(String id) async {
    await api!.deleteNote(id);
    notes = notes.where((n) => n.id != id).toList();
    notifyListeners();
  }

  /// 名单/热词本地缓存键（断网/服务器不可达时回退，保证本地识别热词与名单查看离线可用）
  static const _kCachedFirefighters = 'cached_firefighters';
  static const _kCachedHotwords = 'cached_hotwords';

  /// 拉取名单与热词：成功写入本地缓存；失败（断网/服务器不可达）回退缓存。
  /// 名单热词是本地识别的热词来源，火场无信号时也必须生效。
  Future<void> loadRoster() async {
    if (api == null) return;
    try {
      final f = await api!.fetchFirefighters();
      final h = await api!.fetchHotwords();
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
      await sp.setString(_kCachedHotwords, jsonEncode(hotwords.map((h) => h.word).toList()));
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  Future<void> _restoreCachedRoster() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final fNames = (jsonDecode(sp.getString(_kCachedFirefighters) ?? '[]') as List)
          .map((e) => e.toString())
          .toList();
      final hWords = (jsonDecode(sp.getString(_kCachedHotwords) ?? '[]') as List)
          .map((e) => e.toString())
          .toList();
      if (fNames.isEmpty && hWords.isEmpty) return; // 无缓存：保持现状（首次使用需在线同步一次）
      firefighters = fNames.map((n) => Firefighter(id: '', name: n)).toList();
      hotwords = hWords.map((w) => Hotword(id: '', word: w)).toList();
      notifyListeners();
    } catch (_) {
      // 缓存损坏时忽略
    }
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

  Future<String> _localTranscribe(Uint8List bytes, {String? opId}) async {
    final asr = localAsr;
    if (asr == null) throw StateError('未配置本地语音识别');
    final text = await asr.transcribe(bytes, hotwords: [..._rosterNames, ..._hotwordTerms]);
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
bool isConnectionLost({required int lastSyncSuccessAt, required int nowMs, int thresholdMs = 30000}) {
  if (lastSyncSuccessAt <= 0) return false;
  return nowMs - lastSyncSuccessAt > thresholdMs;
}
