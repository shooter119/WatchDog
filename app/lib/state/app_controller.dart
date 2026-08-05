import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/alarm_service.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/tts_service.dart';

class AppController extends ChangeNotifier {
  ApiClient? api;
  final AlarmService alarm = AlarmService();
  final TtsService tts = TtsService();

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
  }

  Future<void> refreshConfig() async {
    final serverUrl = await Settings.serverUrl;
    final sceneCode = await Settings.sceneCode;
    final token = await Settings.apiToken;
    api = ApiClient(baseUrl: serverUrl, sceneCode: sceneCode, apiToken: token);
    tts.enabled = await Settings.ttsEnabled;
    alarm.soundEnabled = await Settings.alarmSoundEnabled;
    await ScreenOn.setKeepScreenOn(await Settings.keepScreenOn);
    try {
      final cfg = await api!.fetchConfig();
      calcConfig = cfg;
    } catch (_) {
      // 服务不可达时用本地默认参数
    }
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

  /// 新条目到达时调度本地通知
  final Set<String> _scheduledIds = {};

  Future<void> _rescheduleNotifications() async {
    final active = entries.where((e) => e.isActive).toList();
    final activeIds = active.map((e) => e.id).toSet();
    final allIds = entries.map((e) => e.id).toSet();

    for (final e in active) {
      if (!_scheduledIds.contains(e.id)) {
        _scheduledIds.add(e.id);
        await alarm.scheduleForEntry(e, warnMin: calcConfig.warnMin, alarmMin: calcConfig.alarmMin);
      }
    }
    // 已出火场或已消失的条目：取消通知
    for (final id in List.of(_scheduledIds)) {
      if (!activeIds.contains(id) || !allIds.contains(id)) {
        _scheduledIds.remove(id);
        await alarm.cancelForEntry(id);
      }
    }
  }

  /// 每秒检查：剩余10分钟提醒、5分钟报警、超时报警（前台 TTS+声音）
  void _checkThresholds() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in entries.where((e) => e.isActive)) {
      final remaining = e.exitAt - now;
      if (remaining <= 0) {
        _announce(e, 'timeout', '${e.name}超时！${e.name}超时！立即确认！');
      } else if (remaining <= calcConfig.alarmMin * 60000) {
        _announce(e, 'alarm', '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，立即撤离！');
      } else if (remaining <= calcConfig.warnMin * 60000) {
        _announce(e, 'warn', '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，准备撤离。');
      }
    }
  }

  void _announce(Entry e, String kind, String text) {
    final key = '${e.id}:$kind';
    if (_announced[key] != null) return;
    _announced[key] = DateTime.now().millisecondsSinceEpoch;
    tts.speak(text);
    alarm.fire(key, ttsText: text);
  }

  Future<Entry?> createEntryFromVoice({required String name, required double pressureMpa, String? rawText}) async {
    final e = await api!.createEntry(name: name, pressureMpa: pressureMpa, source: 'voice', rawText: rawText);
    await sync();
    return e;
  }

  Future<void> markExited(String id) async {
    await api!.markExited(id);
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

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    tts.stop();
    super.dispose();
  }
}
