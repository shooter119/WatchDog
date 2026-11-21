import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../services/alarm_service.dart';
import '../../../services/tts_service.dart';
import '../data/models/calc_config.dart';
import '../data/models/entry.dart';

/// 现场监控时钟与告警调度容器。
///
/// 职责边界：
/// - 维护高频 [clockTick]（`ValueNotifier<int>`），前台/PiP 1s、后台 5s 节拍，
///   仅局部刷新倒计时与阈值检查，不触发高频 `notifyListeners()`；
/// - 衔接冻结的 [AlarmService] 与 [TtsService]，执行 10 分钟提醒、5 分钟告警、超时播报与循环警笛；
/// - 严格遵循 [shouldRescheduleNotification]：仅在 `exitAt` 变化时重排系统通知，杜绝重复 IPC；
/// - 零跨 Store 依赖，所有人员/配置读取由外部回调注入。
class AlertClockStore extends ChangeNotifier {
  static const Duration foregroundTickInterval = Duration(seconds: 1);
  static const Duration backgroundTickInterval = Duration(seconds: 5);

  static CalcConfig _fallbackCalcConfig() => CalcConfig(
    cylinderVolL: 6.8,
    fullPressureMpa: 30,
    consumptionLpm: 80,
    warnMin: 10,
    alarmMin: 5,
  );

  AlertClockStore({
    AlarmService? alarm,
    TtsService? tts,
    List<Entry> Function()? entriesProvider,
    CalcConfig Function()? calcConfigProvider,
    VoidCallback? onTick,
    int Function()? nowMs,
  }) : alarm = alarm ?? AlarmService(),
       tts = tts ?? TtsService(),
       _entriesProvider = entriesProvider,
       _calcConfigProvider = calcConfigProvider,
       _onTick = onTick,
       _nowMs = nowMs ?? _defaultNowMs;

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

  final AlarmService alarm;
  final TtsService tts;
  final List<Entry> Function()? _entriesProvider;
  final CalcConfig Function()? _calcConfigProvider;
  final VoidCallback? _onTick;
  final int Function() _nowMs;

  /// 倒计时高频节拍器（供单卡 `ValueListenableBuilder` 局部监听）。
  final ValueNotifier<int> clockTick = ValueNotifier<int>(0);

  Timer? _tickTimer;
  bool _appInForeground = true;
  bool _pipActive = false;
  bool _alarmReady = false;
  bool _disposed = false;

  final Map<String, int> _announced = <String, int>{};
  final Map<String, int> _scheduled = <String, int>{};

  bool get isRunning => _tickTimer != null;
  bool get appInForeground => _appInForeground;
  bool get pipActive => _pipActive;
  bool get alarmReady => _alarmReady;
  bool get soundEnabled => alarm.soundEnabled;
  bool get disposed => _disposed;

  /// 当前生效的节拍周期：前台或系统 PiP 1 秒，后台 5 秒。
  Duration get tickInterval => (_appInForeground || _pipActive)
      ? foregroundTickInterval
      : backgroundTickInterval;

  @visibleForTesting
  Map<String, int> get scheduledExitAtMap => Map<String, int>.unmodifiable(_scheduled);

  @visibleForTesting
  Map<String, int> get announcedMap => Map<String, int>.unmodifiable(_announced);

  /// 通知只在 `exitAt` 变化（改名/压力复核）时重排；同一到期时间重复同步不得反复
  /// cancel+schedule，否则每次快照都会白跑 3 个精确闹钟的 IPC。
  static bool shouldRescheduleNotification({
    required int? scheduledExitAt,
    required int exitAt,
  }) => scheduledExitAt != exitAt;

  /// 初始化冻结告警与 TTS 服务（异常时保持降级，不中断主流程）。
  Future<void> initServices() async {
    try {
      await alarm.init();
      _alarmReady = true;
    } catch (error) {
      _alarmReady = false;
      debugPrint('AlertClockStore alarm.init failed: $error');
    }
    try {
      await tts.init();
    } catch (error) {
      debugPrint('AlertClockStore tts.init failed: $error');
    }
  }

  /// 显式标记闹钟插件就绪态（供编排器桥接或单元测试注入）。
  void setAlarmReady(bool ready) {
    _alarmReady = ready;
  }

  /// 更新报警音开关（低频变更，通知观察者更新横幅）。
  Future<void> setSoundEnabled(bool enabled) async {
    if (_disposed) return;
    if (alarm.soundEnabled == enabled) return;
    alarm.soundEnabled = enabled;
    if (!enabled) {
      await _stopAlarmSafely();
    }
    _notify();
  }

  /// 同步外部已修改的 `alarm.soundEnabled` 状态并通知监听者。
  void notifySoundStateChanged() => _notify();

  /// 启动周期时钟（重复调用按当前生命周期重设周期）。
  void start() {
    if (_disposed) return;
    _restartTickTimer();
  }

  /// 停止周期时钟。
  void stop() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  /// 切换前后台生命周期；若定时器运行中则立即切换节拍频率。
  void setAppInForeground(bool inForeground) {
    if (_appInForeground == inForeground) return;
    _appInForeground = inForeground;
    if (_tickTimer != null) {
      _restartTickTimer();
    }
  }

  /// 切换系统画中画（PiP）态；PiP 期间保持 1 秒倒计时节拍。
  void setPipActive(bool active) {
    if (_pipActive == active) return;
    _pipActive = active;
    if (_tickTimer != null) {
      _restartTickTimer();
    }
  }

  /// 同步系统本地通知计划：仅当 `exitAt` 变化时 cancel+schedule，并清理已出场条目。
  Future<void> rescheduleNotifications({
    List<Entry>? entries,
    CalcConfig? calcConfig,
  }) async {
    if (!_alarmReady || _disposed) return;
    final list = entries ?? _entriesProvider?.call() ?? const <Entry>[];
    final cfg = calcConfig ?? _calcConfigProvider?.call() ?? _fallbackCalcConfig();
    final active = list.where((e) => e.isActive).toList();
    final activeIds = active.map((e) => e.id).toSet();
    final allIds = list.map((e) => e.id).toSet();

    for (final e in active) {
      if (shouldRescheduleNotification(
        scheduledExitAt: _scheduled[e.id],
        exitAt: e.exitAt,
      )) {
        try {
          await alarm.cancelForEntry(e.id);
          await alarm.scheduleForEntry(
            e,
            warnMin: cfg.warnMin,
            alarmMin: cfg.alarmMin,
          );
          _scheduled[e.id] = e.exitAt;
        } catch (_) {
          _scheduled.remove(e.id);
          rethrow;
        }
      }
    }

    for (final id in List<String>.of(_scheduled.keys)) {
      if (!activeIds.contains(id) || !allIds.contains(id)) {
        _scheduled.remove(id);
        await alarm.cancelForEntry(id);
      }
    }
  }

  /// 检查所有在场人员的预警/告警/超时阈值，触发去重 TTS 与循环警笛。
  void checkThresholds({List<Entry>? entries, CalcConfig? calcConfig}) {
    if (_disposed) return;
    final list = entries ?? _entriesProvider?.call() ?? const <Entry>[];
    final cfg = calcConfig ?? _calcConfigProvider?.call() ?? _fallbackCalcConfig();
    final now = _nowMs();
    var inDanger = false;

    for (final e in list.where((item) => item.isActive)) {
      final remaining = e.exitAt - now;
      if (remaining <= 0) {
        inDanger = true;
        _announce(e, 'timeout', '${e.name}超时！${e.name}超时！立即确认！', now);
      } else if (remaining <= cfg.alarmMin * 60000) {
        inDanger = true;
        _announce(
          e,
          'alarm',
          '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，立即撤离！',
          now,
        );
      } else if (remaining <= cfg.warnMin * 60000) {
        _announce(
          e,
          'warn',
          '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，准备撤离。',
          now,
        );
      }
    }

    if (inDanger) {
      unawaited(_startAlarmLoopSafely());
    } else {
      unawaited(_stopAlarmSafely());
    }
  }

  /// 清理当前已调度的全部系统本地通知并停止循环警报。
  Future<void> clearScheduledNotifications() async {
    final ids = List<String>.of(_scheduled.keys);
    _scheduled.clear();
    if (!_alarmReady) return;
    for (final id in ids) {
      try {
        await alarm.cancelForEntry(id);
      } catch (_) {
        // 插件未就绪或系统回收时仍确保本地缓存清理完成。
      }
    }
    await _stopAlarmSafely();
  }

  /// 重置会话级播报去重与闹钟缓存（切换警情/登出时调用）。
  void resetSession() {
    _announced.clear();
    _scheduled.clear();
    alarm.resetSession();
  }

  /// 通过冻结的 [TtsService] 播报文本。
  void speak(String text) {
    if (_disposed) return;
    tts.speak(text);
  }

  void _restartTickTimer() {
    _tickTimer?.cancel();
    if (_disposed) return;
    _tickTimer = Timer.periodic(tickInterval, (_) {
      if (_disposed) return;
      _onTick?.call();
      checkThresholds();
      clockTick.value++;
    });
  }

  void _announce(Entry entry, String kind, String text, int nowMs) {
    final key = '${entry.id}:$kind';
    if (_announced[key] != null) return;
    _announced[key] = nowMs;
    tts.speak(text);
    unawaited(alarm.fire(key, ttsText: text));
  }

  Future<void> _startAlarmLoopSafely() async {
    try {
      await alarm.startAlarmLoop();
    } catch (error) {
      debugPrint('AlertClockStore startAlarmLoop failed: $error');
    }
  }

  Future<void> _stopAlarmSafely() async {
    try {
      await alarm.stopAlarm();
    } catch (error) {
      debugPrint('AlertClockStore stopAlarm failed: $error');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tickTimer?.cancel();
    _tickTimer = null;
    clockTick.dispose();
    super.dispose();
  }
}
