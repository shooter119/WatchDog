import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;

/// 后台值守前台服务（flutter_foreground_task 10.x）：
/// - 前台服务保住进程 + CPU 唤醒锁，App 切后台/锁屏后 5 秒轮询与 1 秒阈值检查照常运行
///   （主 isolate 的 Timer 逻辑不变，服务 isolate 独立拉数据只负责刷新常驻通知栏）。
/// - 常驻通知栏显示"火场指挥中 · 在场 N 人 · 最早剩余 M:SS"，每 5 秒自刷新。
/// - specialUse 类型：Android 15 无 dataSync 的 6 小时时长限制，可开机自启。
class ForegroundKeepAlive {
  static const channelId = 'watchdog_keepalive';
  static const channelName = '后台值守';
  static const channelDesc = '火场指挥持续值守，保持后台轮询与报警';

  static const _kServerUrl = 'keepalive_server_url';
  static const _kSceneCode = 'keepalive_scene_code';
  static const _kToken = 'keepalive_token';
  static const _kWarnMin = 'keepalive_warn_min';
  static const _kAlarmMin = 'keepalive_alarm_min';

  static bool _inited = false;

  /// 必须在 runApp 前调用一次（注册静态 TaskHandler，供服务 isolate 恢复）
  static void init() {
    if (_inited) return;
    _inited = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: channelId,
        channelName: channelName,
        channelDescription: channelDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showBadge: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 服务内用 5s 周期回调拉数据刷通知栏（同步主 isolate 轮询节奏）
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    FlutterForegroundTask.setTaskHandler(WatchdogTaskHandler());
  }

  /// 启动保活服务：先把轮询所需配置写入服务数据，再启动（服务内独立拉看板数据）
  static Future<void> start({
    required String serverUrl,
    required String sceneCode,
    required String token,
    required int warnMin,
    required int alarmMin,
  }) async {
    if (!Platform.isAndroid) return; // 非 Android（含测试环境）无前台服务
    await FlutterForegroundTask.saveData(key: _kServerUrl, value: serverUrl);
    await FlutterForegroundTask.saveData(key: _kSceneCode, value: sceneCode);
    await FlutterForegroundTask.saveData(key: _kToken, value: token);
    await FlutterForegroundTask.saveData(key: _kWarnMin, value: warnMin);
    await FlutterForegroundTask.saveData(key: _kAlarmMin, value: alarmMin);
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.specialUse],
      notificationTitle: '火场指挥中',
      notificationText: '后台轮询与报警保护已开启',
    );
  }

  /// 停止保活服务
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
  }

  static Future<bool> get isRunning async =>
      FlutterForegroundTask.isRunningService;

  /// 请求通知权限（Android 13+，前台服务通知必须可见）
  static Future<NotificationPermission> requestNotificationPermission() =>
      FlutterForegroundTask.requestNotificationPermission();

  /// 请求电池优化豁免（国产 ROM 也会尽力保活，仍需厂商白名单配合）
  static Future<bool> requestIgnoreBatteryOptimization() async {
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) return true;
    return FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  /// 打开系统精确闹钟设置页（Android 12+ 可能被用户关闭）
  static Future<void> openAlarmsAndRemindersSettings() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.openAlarmsAndRemindersSettings();
  }
}

/// 服务 isolate 内的任务处理器：每 5 秒拉一次看板数据，刷新常驻通知栏
class WatchdogTaskHandler extends TaskHandler {
  String _serverUrl = '';
  String _sceneCode = '';
  String _token = '';
  int _warnMin = 10;
  int _alarmMin = 5;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 服务 isolate 运行在独立后台 isolate：Flutter 3.38+ 引擎启动 isolate 时自动注册插件
    _serverUrl =
        await FlutterForegroundTask.getData<String>(key: 'keepalive_server_url') ?? '';
    _sceneCode =
        await FlutterForegroundTask.getData<String>(key: 'keepalive_scene_code') ?? '';
    _token =
        await FlutterForegroundTask.getData<String>(key: 'keepalive_token') ?? '';
    _warnMin =
        await FlutterForegroundTask.getData<int>(key: 'keepalive_warn_min') ?? 10;
    _alarmMin =
        await FlutterForegroundTask.getData<int>(key: 'keepalive_alarm_min') ?? 5;
    await _refresh();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // fire-and-forget：拉数据刷通知栏，失败静默（下次周期重试）
    unawaited(_refresh());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  Future<void> _refresh() async {
    if (_serverUrl.isEmpty) return;
    try {
      final res = await http.get(
        Uri.parse('$_serverUrl/api/entries?active=1'),
        // 中文场景码 URL 编码（dart:io 拒绝非 ASCII 头值，服务端 sceneKey 解码还原）
        headers: {'X-Scene-Code': Uri.encodeComponent(_sceneCode), 'X-Api-Token': _token},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
      final now = DateTime.now().millisecondsSinceEpoch;
      final active = <Map<String, dynamic>>[];
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        if (m['exited_at'] != null) continue;
        final exitAt = (m['exit_at'] as num?)?.toInt() ?? 0;
        if (exitAt <= now) continue;
        active.add({'name': m['name'] ?? '?', 'exitAt': exitAt});
      }
      active.sort((a, b) => (a['exitAt'] as int).compareTo(b['exitAt'] as int));

      String title = '火场指挥中';
      String text = '后台轮询与报警保护已开启';
      if (active.isNotEmpty) {
        final earliest = active.first;
        final name = earliest['name'];
        final leftMs = (earliest['exitAt'] as int) - now;
        final warnMs = _warnMin * 60000;
        final alarmMs = _alarmMin * 60000;
        final status = leftMs < 0
            ? '超时！'
            : leftMs <= alarmMs
                ? '报警！'
                : leftMs <= warnMs
                    ? '注意'
                    : '';
        title = '火场指挥中 · 在场 ${active.length} 人$status';
        text = '最早剩余 ${_fmt(leftMs)}（$name）';
      }
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (_) {
      // 网络波动静默，下个周期重试
    }
  }

  /// 毫秒 → M:SS / H:MM:SS（超时显示 0:00）
  static String _fmt(int ms) {
    final s = ms < 0 ? 0 : ms ~/ 1000;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
