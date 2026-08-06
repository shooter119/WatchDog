import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/alarm_service.dart';
import '../services/local_asr_service.dart';
import '../services/local_parser.dart';
import '../services/op_log_service.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/tts_service.dart';

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
      syncError = null;
      await _rescheduleNotifications();
    } catch (e) {
      syncError = e.toString();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

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

  /// 报数：对在场人员提交一次压力读数（动态耗气率的采样点，服务端差分重算倒计时）
  Future<Entry> reportPressure({required String id, required double pressureMpa, String? opId}) async {
    final op = opId ?? '';
    OpLogService.instance.record(op, 'pressure_report', '报数 ${pressureMpa}MPa', data: {'entryId': id});
    final e = await api!.updateEntry(id: id, pressureMpa: pressureMpa, opId: op);
    await sync();
    return e;
  }

  Future<void> markExited(String id, {String? opId}) async {
    await api!.markExited(id, opId: opId);
    await sync();
  }

  Future<void> loadRoster() async {
    if (api == null) return;
    try {
      final f = await api!.fetchFirefighters();
      final h = await api!.fetchHotwords();
      firefighters = f;
      hotwords = h;
      notifyListeners();
    } catch (_) {}
  }

  List<String> get _rosterNames => firefighters.map((f) => f.name).toList();

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
    final text = await asr.transcribe(bytes);
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
