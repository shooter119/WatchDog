import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/models.dart';

/// 闹钟/提醒服务：
/// - 前台：播放警报音 + 语音播报
/// - 后台：本地通知（剩余10分钟提醒 / 剩余5分钟报警 / 到点超时报警）
class AlarmService {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final AudioPlayer _player = AudioPlayer();
  bool soundEnabled = true;
  bool _inited = false;
  final Set<String> _firedLocal = {};
  String _lastSpokenKey = '';
  bool _looping = false;
  /// 精确闹钟是否可用（Android 12+ 可能被系统/用户关闭）
  bool exactAlarmAvailable = true;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    tzdata.initializeTimeZones();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _notifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );
    // Android 13+：运行时申请通知权限
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    // Android 12+：检测精确闹钟授权（USE_EXACT_ALARM 默认授予；SCHEDULE_EXACT_ALARM 需手动）
    exactAlarmAvailable =
        await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.canScheduleExactNotifications() ??
        true;
    await _player.setPlayerMode(PlayerMode.lowLatency);
    await _player.setSource(AssetSource('sounds/alarm.wav'));
  }

  AndroidScheduleMode get _scheduleMode => exactAlarmAvailable
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle;

  /// 每个条目调度本地通知：warn 提醒、alarm 报警、timeout 超时（已过时间点跳过）
  Future<void> scheduleForEntry(Entry e, {required int warnMin, required int alarmMin}) async {
    final now = tz.TZDateTime.now(tz.local);
    final exit = tz.TZDateTime.from(DateTime.fromMillisecondsSinceEpoch(e.exitAt), tz.local);
    final warnAt = exit.subtract(Duration(minutes: warnMin));
    final alarmAt = exit.subtract(Duration(minutes: alarmMin));

    if (warnAt.isAfter(now)) {
      await _notifications.zonedSchedule(
        _id('warn', e.id),
        '⚠️ ${e.name} 气瓶剩余 $warnMin 分钟',
        '请提醒 ${e.name} 准备撤离',
        warnAt,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'watchdog_warn',
            '气瓶提醒',
            channelDescription: '剩余10分钟提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: _scheduleMode,
      );
    }
    if (alarmAt.isAfter(now)) {
      await _notifications.zonedSchedule(
        _id('alarm', e.id),
        '🚨 ${e.name} 气瓶剩余 $alarmMin 分钟，立即撤离！',
        '请确认 ${e.name} 已出火场',
        alarmAt,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'watchdog_alarm',
            '气瓶报警',
            channelDescription: '剩余5分钟报警',
            importance: Importance.max,
            priority: Priority.max,
            sound: RawResourceAndroidNotificationSound('alarm'),
            fullScreenIntent: true,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: _scheduleMode,
      );
    }
    if (exit.isAfter(now)) {
      await _notifications.zonedSchedule(
        _id('timeout', e.id),
        '🚨🚨 ${e.name} 气瓶超时！',
        '${e.name} 已超出可用时间，立即确认！',
        exit,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'watchdog_timeout',
            '气瓶超时',
            channelDescription: '超时报警',
            importance: Importance.max,
            priority: Priority.max,
            sound: RawResourceAndroidNotificationSound('alarm'),
            fullScreenIntent: true,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: _scheduleMode,
      );
    }
  }

  int _id(String kind, String entryId) => ('$kind:$entryId'.hashCode & 0x7fffffff);

  /// 取消条目的所有通知
  Future<void> cancelForEntry(String entryId) async {
    for (final kind in ['warn', 'alarm', 'timeout']) {
      await _notifications.cancel(_id(kind, entryId));
    }
  }

  /// 前台循环警报音：存在 alarm/timeout 状态人员时持续响（幂等）
  Future<void> startAlarmLoop() async {
    if (!soundEnabled) return;
    if (_looping) return;
    _looping = true;
    await _player.setPlayerMode(PlayerMode.lowLatency);
    await _player.setSource(AssetSource('sounds/alarm.wav'));
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.resume();
  }

  Future<void> stopAlarm() async {
    if (!_looping) return;
    _looping = false;
    await _player.stop();
  }

  /// 对某人员状态变化触发前台提醒（去重；声音由 [startAlarmLoop] 统一管理）
  Future<void> fire(String key, {required String ttsText}) async {
    if (_lastSpokenKey == key) return;
    _lastSpokenKey = key;
  }

  void resetSession() {
    _firedLocal.clear();
    _lastSpokenKey = '';
  }
}
