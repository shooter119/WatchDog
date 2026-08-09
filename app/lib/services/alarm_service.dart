import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/models.dart';

/// Android 原生通道：报警音量提升 / 勿扰策略 / 通知设置（watchdog/alarm）
class AlarmNative {
  static const MethodChannel _channel = MethodChannel('watchdog/alarm');

  /// 把 ALARM 音频流音量拉到最大（火场高分贝环境确保听到）
  static Future<void> maximizeAlarmVolume() async {
    if (!Platform.isAndroid) return; // 非 Android（含测试环境）无此通道
    try {
      await _channel
          .invokeMethod('maxAlarmVolume')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 平台不支持时静默忽略
    }
  }

  /// 勿扰（免打扰）策略访问是否已授权（bypassDnd 生效的前提）
  static Future<bool> isNotificationPolicyAccessGranted() async {
    if (!Platform.isAndroid) return true; // 非 Android 视为已授权
    try {
      final ok = await _channel
          .invokeMethod<bool>('isNotificationPolicyAccessGranted')
          .timeout(const Duration(seconds: 2));
      return ok ?? false;
    } catch (_) {
      return true; // 异常时视为已授权，避免误报引导
    }
  }

  /// 跳系统勿扰设置页（策略访问被拒后的恢复路径）
  static Future<void> openNotificationPolicySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod('openNotificationPolicySettings')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 平台不支持时静默忽略
    }
  }

  /// 跳本应用通知设置页（Android 14+ 全屏通知默认关闭，需手动开启）
  static Future<void> openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod('openNotificationSettings')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 平台不支持时静默忽略
    }
  }
}

/// 闹钟/提醒服务：
/// - 前台：播放警报音 + 语音播报
/// - 后台：本地通知（剩余10分钟提醒 / 剩余5分钟报警 / 到点超时报警）
class AlarmService {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  // 报警音走 ALARM 音频流（不随媒体音量/静音，配合音量强制提升）；stayAwake 持锁屏唤醒
  final AudioPlayer _player = AudioPlayer();
  bool soundEnabled = true;
  bool _inited = false;
  final Set<String> _firedLocal = {};
  String _lastSpokenKey = '';
  bool _looping = false;

  /// 精确闹钟是否可用（Android 12+ 可能被系统/用户关闭）
  bool exactAlarmAvailable = true;

  /// Android 14+ 全屏通知是否可用（默认被系统关闭，需用户手动开启）
  bool fullScreenIntentEnabled = true;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    tzdata.initializeTimeZones();
    // 应用使用 drawable 中的正式图标。Release 开启 shrinkResources 后，
    // 未被 Android 清单直接引用的 mipmap 图标可能被移除，导致通知插件
    // 初始化抛出 invalid_icon，进而阻断 AppController 的服务器初始化。
    const androidInit = AndroidInitializationSettings(
      '@drawable/fire_control_logo',
    );
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _notifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );
    // 报警音走 ALARM 音频流（不受媒体音量/静音影响，配合音量强制提升），锁屏时持唤醒锁
    await _player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gain,
          stayAwake: true,
        ),
      ),
    );
    // Android 13+：运行时申请通知权限
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    // Android 12+：检测精确闹钟授权（USE_EXACT_ALARM 默认授予；SCHEDULE_EXACT_ALARM 需手动）
    exactAlarmAvailable =
        await _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.canScheduleExactNotifications() ??
        true;
    // Android 14+：全屏通知（API 34 起默认关闭，需用户手动开启；request 返回 true=已开启）
    fullScreenIntentEnabled =
        await _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestFullScreenIntentPermission() ??
        true;
    await _player.setPlayerMode(PlayerMode.lowLatency);
    await _player.setSource(AssetSource('sounds/alarm.wav'));
  }

  AndroidScheduleMode get _scheduleMode => exactAlarmAvailable
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle;

  /// 每个条目调度本地通知：warn 提醒、alarm 报警、timeout 超时（已过时间点跳过）
  Future<void> scheduleForEntry(
    Entry e, {
    required int warnMin,
    required int alarmMin,
  }) async {
    final now = tz.TZDateTime.now(tz.local);
    final exit = tz.TZDateTime.from(
      DateTime.fromMillisecondsSinceEpoch(e.exitAt),
      tz.local,
    );
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
            channelBypassDnd: true,
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
            channelBypassDnd: true,
            audioAttributesUsage: AudioAttributesUsage.alarm,
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
            channelBypassDnd: true,
            audioAttributesUsage: AudioAttributesUsage.alarm,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: _scheduleMode,
      );
    }
  }

  int _id(String kind, String entryId) =>
      ('$kind:$entryId'.hashCode & 0x7fffffff);

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
    // 火场高分贝环境：把 ALARM 流音量拉到最大（报警音走 ALARM 流）
    await AlarmNative.maximizeAlarmVolume();
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
