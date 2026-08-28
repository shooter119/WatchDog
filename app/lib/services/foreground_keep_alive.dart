import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;

import 'settings.dart';

bool _isSafeServerUrl(String value) => Settings.isSafeHttpUrl(value);

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
  static const _kIncidentId = 'keepalive_incident_id';
  static const _kToken = 'keepalive_token';
  static const _kUnitId = 'keepalive_unit_id';
  static const _kUnitCode = 'keepalive_unit_code';
  static const _kWarnMin = 'keepalive_warn_min';
  static const _kAlarmMin = 'keepalive_alarm_min';

  static bool _inited = false;
  static Future<void>? _initFuture;
  static Future<void> _operationTail = Future<void>.value();

  /// 必须在 runApp 前调用一次（注册静态 TaskHandler，供服务 isolate 恢复）
  static Future<void> init() {
    if (_inited) return Future<void>.value();
    final pending = _initFuture;
    if (pending != null) return pending;
    final future = _initInternal();
    _initFuture = future;
    future.then<void>(
      (_) {
        if (identical(_initFuture, future)) _initFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_initFuture, future)) _initFuture = null;
      },
    );
    return future;
  }

  static Future<void> _initInternal() async {
    try {
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
      _inited = true;
    } catch (error) {
      // 允许下一次真正使用前台服务时重试；启动阶段失败不应影响核心业务。
      _inited = false;
      rethrow;
    }
  }

  /// 串行化 start/stop，避免设置页自动保存、启动恢复和退出单位同时向插件
  /// 发起互相覆盖的服务操作。失败不会阻塞后续操作。
  static Future<void> _enqueueOperation(Future<void> Function() operation) {
    final previous = _operationTail;
    final future = previous
        .catchError((Object _) {})
        .then<void>((_) => operation());
    _operationTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return future;
  }

  /// 启动保活服务：先把轮询所需配置写入服务数据，再启动（服务内独立拉看板数据）
  static Future<void> start({
    required String serverUrl,
    required String incidentId,
    required String token,
    required String unitId,
    required String unitCode,
    required int warnMin,
    required int alarmMin,
  }) {
    if (!Platform.isAndroid) {
      return Future<void>.value(); // 非 Android（含测试环境）无前台服务
    }
    if (!_isSafeServerUrl(serverUrl)) {
      throw ArgumentError('后台值守服务器地址必须使用 HTTPS');
    }
    return _enqueueOperation(() async {
      await init();
      await FlutterForegroundTask.saveData(key: _kServerUrl, value: serverUrl);
      await FlutterForegroundTask.saveData(
        key: _kIncidentId,
        value: incidentId,
      );
      await FlutterForegroundTask.saveData(key: _kToken, value: token);
      await FlutterForegroundTask.saveData(key: _kUnitId, value: unitId);
      await FlutterForegroundTask.saveData(key: _kUnitCode, value: unitCode);
      await FlutterForegroundTask.saveData(key: _kWarnMin, value: warnMin);
      await FlutterForegroundTask.saveData(key: _kAlarmMin, value: alarmMin);
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceTypes: const [ForegroundServiceTypes.specialUse],
        notificationTitle: '火场指挥中',
        notificationText: '后台轮询与报警保护已开启',
        callback: watchdogStartCallback,
      );
    });
  }

  /// 停止保活服务
  static Future<void> stop() {
    if (!Platform.isAndroid) return Future<void>.value();
    return _enqueueOperation(() async {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    });
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

/// 前台服务启动后在独立 isolate 中注册任务处理器。
/// 不能在主 isolate 初始化时调用 setTaskHandler，否则会向尚未创建的
/// background channel 发送消息，产生 MissingPluginException。
@pragma('vm:entry-point')
void watchdogStartCallback() {
  FlutterForegroundTask.setTaskHandler(WatchdogTaskHandler());
}

/// 服务 isolate 内的任务处理器：每 5 秒拉一次看板数据，刷新常驻通知栏
class WatchdogTaskHandler extends TaskHandler {
  String _serverUrl = '';
  String _incidentId = '';
  String _token = '';
  String _unitId = '';
  String _unitCode = '';
  int _warnMin = 10;
  int _alarmMin = 5;
  bool _refreshing = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 服务 isolate 运行在独立后台 isolate：Flutter 3.38+ 引擎启动 isolate 时自动注册插件
    _serverUrl =
        await FlutterForegroundTask.getData<String>(
          key: 'keepalive_server_url',
        ) ??
        '';
    _incidentId =
        await FlutterForegroundTask.getData<String>(
          key: 'keepalive_incident_id',
        ) ??
        '';
    _token =
        await FlutterForegroundTask.getData<String>(key: 'keepalive_token') ??
        '';
    _unitId =
        await FlutterForegroundTask.getData<String>(key: 'keepalive_unit_id') ??
        '';
    _unitCode =
        await FlutterForegroundTask.getData<String>(
          key: 'keepalive_unit_code',
        ) ??
        '';
    _warnMin =
        await FlutterForegroundTask.getData<int>(key: 'keepalive_warn_min') ??
        10;
    _alarmMin =
        await FlutterForegroundTask.getData<int>(key: 'keepalive_alarm_min') ??
        5;
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
    if (_serverUrl.isEmpty || _incidentId.isEmpty) return;
    if (!_isSafeServerUrl(_serverUrl)) return;
    if (_refreshing) return;
    _refreshing = true;
    try {
      final res = await http
          .get(
            Uri.parse('$_serverUrl/api/entries?active=1'),
            headers: {
              'X-Incident-Id': _incidentId,
              'X-Api-Token': _token,
              if (_unitId.isNotEmpty) 'X-Unit-Id': _unitId,
              if (_unitCode.isNotEmpty) 'X-Unit-Code': _unitCode,
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
      final now = DateTime.now().millisecondsSinceEpoch;
      final active = <Map<String, dynamic>>[];
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        if (m['exited_at'] != null) continue;
        final exitAt = (m['exit_at'] as num?)?.toInt() ?? 0;
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
    } finally {
      _refreshing = false;
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
