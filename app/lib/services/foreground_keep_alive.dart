import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;

import 'secure_store.dart';
import 'settings.dart';

bool _isSafeServerUrl(String value) => Settings.isSafeHttpUrl(value);

/// 主 isolate 最近一次成功同步仍在有效窗口内时，前台服务无需重复拉取。
bool isMainSnapshotFresh({
  required int lastSyncAt,
  required int nowMs,
  int freshnessMs = 8000,
}) => lastSyncAt > 0 && nowMs >= lastSyncAt && nowMs - lastSyncAt < freshnessMs;

/// 后台值守前台服务（flutter_foreground_task 10.x）：
/// - 前台服务保住进程 + CPU 唤醒锁；主 isolate 在线时交接快照，后台优先
///   持有一条业务 WebSocket，连接不可用时才按 30 秒 bootstrap 校准。
/// - 常驻通知栏显示"火场指挥中 · 在场 N 人 · 最早剩余 M:SS"。
/// - specialUse 类型：Android 15 无 dataSync 的 6 小时时长限制，可开机自启。
class ForegroundKeepAlive {
  static const channelId = 'watchdog_keepalive';
  static const channelName = '后台值守';
  static const channelDesc = '火场指挥持续值守，保持后台实时同步与报警';

  static const _kServerUrl = 'keepalive_server_url';
  static const _kIncidentId = 'keepalive_incident_id';
  static const _kToken = 'keepalive_token';
  static const _kSessionToken = 'keepalive_session_token';
  static const _kUnitId = 'keepalive_unit_id';
  static const _kUnitCode = 'keepalive_unit_code';
  static const _kWarnMin = 'keepalive_warn_min';
  static const _kAlarmMin = 'keepalive_alarm_min';
  static const _contextUpdatedMessage = 'keepalive_context_updated';

  /// 将主 isolate 的最新摘要交给服务 isolate，避免前台时重复请求。
  static void reportMainSnapshot({
    required int activeCount,
    required int earliestExitAt,
  }) {
    if (!Platform.isAndroid) return;
    try {
      FlutterForegroundTask.sendDataToTask({
        'type': 'main_snapshot',
        'at': DateTime.now().millisecondsSinceEpoch,
        'activeCount': activeCount,
        'earliestExitAt': earliestExitAt,
      });
    } catch (_) {
      // 服务未启动或插件尚未就绪时忽略；下一次服务启动会自行拉取完整快照。
    }
  }

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
          eventAction: ForegroundTaskEventAction.repeat(30000),
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

  /// 启动保活服务：先把实时连接所需配置写入服务数据，再启动。
  static Future<void> start({
    required String serverUrl,
    required String incidentId,
    required String token,
    required String sessionToken,
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
      await _writeSensitive(_kToken, token);
      await _writeSensitive(_kSessionToken, sessionToken);
      await FlutterForegroundTask.saveData(key: _kUnitId, value: unitId);
      await _writeSensitive(_kUnitCode, unitCode);
      await FlutterForegroundTask.saveData(key: _kWarnMin, value: warnMin);
      await FlutterForegroundTask.saveData(key: _kAlarmMin, value: alarmMin);
      if (await FlutterForegroundTask.isRunningService) {
        // 配置已经完整写入后再通知服务 isolate 重读；消息本身不携带
        // 令牌或现场数据，避免在跨 isolate 通道中传递敏感上下文。
        try {
          FlutterForegroundTask.sendDataToTask({
            'type': _contextUpdatedMessage,
          });
        } catch (_) {
          // 服务正在退出时消息可能无接收端；下一次启动会读取最新配置。
        }
        return;
      }
      await FlutterForegroundTask.startService(
        serviceTypes: const [ForegroundServiceTypes.specialUse],
        notificationTitle: '火场指挥中',
        notificationText: '后台实时同步与报警保护已开启',
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
      // 前台服务存储独立于 Settings；退出单位后必须清掉其中的令牌和警情，
      // 避免服务停止后仍在设备持久化区残留可用凭据或旧现场上下文。
      for (final key in [
        _kServerUrl,
        _kIncidentId,
        _kToken,
        _kSessionToken,
        _kUnitId,
        _kUnitCode,
        _kWarnMin,
        _kAlarmMin,
      ]) {
        try {
          await FlutterForegroundTask.removeData(key: key);
        } catch (_) {
          // 继续清理其他键；插件清理失败不应中断安全存储清理。
        }
      }
      await _deleteSensitive(_kToken);
      await _deleteSensitive(_kSessionToken);
      await _deleteSensitive(_kUnitCode);
    });
  }

  static Future<void> _writeSensitive(String key, String value) async {
    if (value.trim().isEmpty) {
      await SecureStore.delete(key);
    } else {
      await SecureStore.write(key, value);
    }
    // 删除旧版本前台服务写入的 SharedPreferences 数据；新版本不再使用
    // flutter_foreground_task 的持久化区保存凭据。
    try {
      await FlutterForegroundTask.removeData(key: key);
    } catch (_) {}
  }

  static Future<void> _deleteSensitive(String key) async {
    try {
      await SecureStore.delete(key);
    } catch (_) {}
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

/// 服务 isolate 内的任务处理器：优先保持业务 WebSocket，断线时每 30 秒快照校准。
class WatchdogTaskHandler extends TaskHandler {
  WatchdogTaskHandler({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  WebSocket? _socket;
  String _serverUrl = '';
  String _incidentId = '';
  String _token = '';
  String _sessionToken = '';
  String _unitId = '';
  String _unitCode = '';
  int _warnMin = 10;
  int _alarmMin = 5;
  int _contextGeneration = 0;
  Future<void>? _refreshFuture;
  int _lastMainSyncAt = 0;
  int _mainActiveCount = 0;
  int _mainEarliestExitAt = 0;
  String _unitCursor = '0';
  String _incidentCursor = '0';
  final Map<String, Map<String, Object>> _backgroundEntries = {};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 服务 isolate 运行在独立后台 isolate：Flutter 3.38+ 引擎启动 isolate 时自动注册插件
    await _reloadContext();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_incidentId.isEmpty) return;
    if (isMainSnapshotFresh(
      lastSyncAt: _lastMainSyncAt,
      nowMs: timestamp.millisecondsSinceEpoch,
    )) {
      return;
    }
    if (_socket?.readyState == WebSocket.open) {
      unawaited(_updateNotificationFromEntries());
      return;
    }
    // fire-and-forget：连接不可用时拉快照刷通知栏，失败静默（下次周期重试）
    unawaited(_refreshForContext(_contextGeneration));
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map &&
        data['type'] == ForegroundKeepAlive._contextUpdatedMessage) {
      // 只接收刷新信号，完整上下文仍从各自的持久化存储读取。
      unawaited(_reloadContext());
      return;
    }
    if (data is! Map || data['type'] != 'main_snapshot') return;
    final at = (data['at'] as num?)?.toInt() ?? 0;
    if (at <= _lastMainSyncAt) return;
    _lastMainSyncAt = at;
    _mainActiveCount = (data['activeCount'] as num?)?.toInt() ?? 0;
    _mainEarliestExitAt = (data['earliestExitAt'] as num?)?.toInt() ?? 0;
    unawaited(_updateNotificationFromMain(at));
  }

  Future<void> _updateNotificationFromMain(int at) async {
    if (at != _lastMainSyncAt || _incidentId.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_mainActiveCount <= 0) {
      await FlutterForegroundTask.updateService(
        notificationTitle: '火场指挥中',
        notificationText: '当前暂无在场人员',
      );
      return;
    }
    final leftMs = _mainEarliestExitAt - now;
    final warnMs = _warnMin * 60000;
    final alarmMs = _alarmMin * 60000;
    final status = leftMs < 0
        ? '超时！'
        : leftMs <= alarmMs
        ? '报警！'
        : leftMs <= warnMs
        ? '注意'
        : '';
    await FlutterForegroundTask.updateService(
      notificationTitle: '火场指挥中 · 在场 $_mainActiveCount 人$status',
      notificationText: '最早剩余 ${_fmt(leftMs)}',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _socket?.close(WebSocketStatus.normalClosure);
    _socket = null;
    _httpClient.close();
  }

  Future<void> _reloadContext() async {
    final generation = ++_contextGeneration;
    // 在异步读取完成前先清空旧上下文，防止切换窗口继续用旧警情请求。
    _serverUrl = '';
    _incidentId = '';
    _token = '';
    _sessionToken = '';
    _unitId = '';
    _unitCode = '';
    _lastMainSyncAt = 0;
    _mainActiveCount = 0;
    _mainEarliestExitAt = 0;
    _unitCursor = '0';
    _incidentCursor = '0';
    _backgroundEntries.clear();
    await _socket?.close(WebSocketStatus.normalClosure);
    _socket = null;

    final serverUrl =
        await FlutterForegroundTask.getData<String>(
          key: ForegroundKeepAlive._kServerUrl,
        ) ??
        '';
    final incidentId =
        await FlutterForegroundTask.getData<String>(
          key: ForegroundKeepAlive._kIncidentId,
        ) ??
        '';
    final token = await SecureStore.read(ForegroundKeepAlive._kToken) ?? '';
    final sessionToken =
        await SecureStore.read(ForegroundKeepAlive._kSessionToken) ?? '';
    final unitId =
        await FlutterForegroundTask.getData<String>(
          key: ForegroundKeepAlive._kUnitId,
        ) ??
        '';
    final unitCode =
        await SecureStore.read(ForegroundKeepAlive._kUnitCode) ?? '';
    final warnMin =
        await FlutterForegroundTask.getData<int>(
          key: ForegroundKeepAlive._kWarnMin,
        ) ??
        10;
    final alarmMin =
        await FlutterForegroundTask.getData<int>(
          key: ForegroundKeepAlive._kAlarmMin,
        ) ??
        5;
    if (generation != _contextGeneration) return;

    // 前台服务可配置为开机/应用更新后自启。服务 isolate 恢复时必须和
    // App 的当前警情选择交叉校验，避免退出警情后仅凭旧服务配置恢复监控。
    final selectedIncidentId = await Settings.currentIncidentId;
    if (generation != _contextGeneration) return;
    if (selectedIncidentId.isEmpty || selectedIncidentId != incidentId) {
      await _stopForStaleContext();
      return;
    }

    _serverUrl = serverUrl;
    _incidentId = incidentId;
    _token = token;
    _sessionToken = sessionToken;
    _unitId = unitId;
    _unitCode = unitCode;
    _warnMin = warnMin;
    _alarmMin = alarmMin;

    // 清理旧版本可能已写入 flutter_foreground_task SharedPreferences 的
    // 敏感键，但不读取它们，避免升级后继续使用明文凭据。
    for (final key in [
      ForegroundKeepAlive._kToken,
      ForegroundKeepAlive._kSessionToken,
      ForegroundKeepAlive._kUnitCode,
    ]) {
      try {
        await FlutterForegroundTask.removeData(key: key);
      } catch (_) {}
    }
    if (generation != _contextGeneration) return;
    await _refreshForContext(generation);
  }

  Future<void> _stopForStaleContext() async {
    try {
      await ForegroundKeepAlive.stop();
    } catch (_) {
      // 服务可能已经被系统回收；主 isolate 下次同步仍会再次清理。
    }
  }

  Future<void> _refreshForContext(int generation) async {
    if (generation != _contextGeneration || _incidentId.isEmpty) return;
    final existing = _refreshFuture;
    if (existing != null) {
      await existing;
      if (generation != _contextGeneration) {
        await _refreshForContext(_contextGeneration);
      }
      return;
    }
    final future = _refresh(generation);
    _refreshFuture = future;
    try {
      await future;
    } finally {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    }
  }

  Future<void> _refresh(int generation) async {
    if (generation != _contextGeneration ||
        _serverUrl.isEmpty ||
        _incidentId.isEmpty) {
      return;
    }
    if (!_isSafeServerUrl(_serverUrl)) return;
    final incidentId = _incidentId;
    try {
      final res = await _httpClient
          .get(
            Uri.parse('$_serverUrl/api/sync/bootstrap?incident_id=${Uri.encodeQueryComponent(incidentId)}'),
            headers: {
              'X-Incident-Id': incidentId,
              'X-Api-Token': _token,
              if (_sessionToken.isNotEmpty)
                'Authorization': 'Bearer $_sessionToken',
              if (_unitId.isNotEmpty) 'X-Unit-Id': _unitId,
              if (_unitCode.isNotEmpty) 'X-Unit-Code': _unitCode,
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      if (generation != _contextGeneration || incidentId != _incidentId) return;
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final cursors = body['cursors'] as Map<String, dynamic>?;
      _unitCursor = cursors?['unit']?.toString() ?? _unitCursor;
      _incidentCursor = cursors?['incident']?.toString() ?? _incidentCursor;
      final snapshot = body['incident_snapshot'] as Map<String, dynamic>?;
      final list = (snapshot?['entries'] as List?) ?? const [];
      final now = DateTime.now().millisecondsSinceEpoch;
      final active = <Map<String, dynamic>>[];
      _backgroundEntries.clear();
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        if (m['exited_at'] != null) continue;
        final exitAt = (m['exit_at'] as num?)?.toInt() ?? 0;
        active.add({'name': m['name'] ?? '?', 'exitAt': exitAt});
        final id = m['id']?.toString();
        if (id != null && id.isNotEmpty) {
          _backgroundEntries[id] = {'name': m['name'] ?? '?', 'exitAt': exitAt};
        }
      }
      active.sort((a, b) => (a['exitAt'] as int).compareTo(b['exitAt'] as int));

      String title = '火场指挥中';
      String text = '后台实时同步与报警保护已开启';
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
      await _connectRealtime(generation);
    } catch (_) {
      // 网络波动静默，下个周期重试
    }
  }

  Future<void> _connectRealtime(int generation) async {
    if (generation != _contextGeneration || _incidentId.isEmpty || _serverUrl.isEmpty) return;
    if (_socket?.readyState == WebSocket.open) return;
    final base = Uri.tryParse(_serverUrl);
    if (base == null || base.host.isEmpty) return;
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/api/realtime',
      query: '',
    );
    try {
      final socket = await WebSocket.connect(uri.toString(), headers: {
        'X-Incident-Id': _incidentId,
        if (_token.isNotEmpty) 'X-Api-Token': _token,
        if (_sessionToken.isNotEmpty) 'Authorization': 'Bearer $_sessionToken',
        if (_unitId.isNotEmpty) 'X-Unit-Id': _unitId,
        if (_unitCode.isNotEmpty) 'X-Unit-Code': _unitCode,
      });
      if (generation != _contextGeneration || _incidentId.isEmpty) {
        await socket.close(WebSocketStatus.normalClosure);
        return;
      }
      _socket = socket;
      socket.listen(
        (data) => _handleRealtimeMessage(generation, data),
        onError: (_, __) {
          if (identical(_socket, socket)) _socket = null;
        },
        onDone: () {
          if (identical(_socket, socket)) _socket = null;
        },
        cancelOnError: false,
      );
      socket.add(jsonEncode({
        'type': 'subscribe',
        'incident_id': _incidentId,
        'unit_cursor': _unitCursor,
        'incident_cursor': _incidentCursor,
      }));
    } catch (_) {
      _socket = null;
    }
  }

  void _handleRealtimeMessage(int generation, Object data) {
    if (generation != _contextGeneration || _incidentId.isEmpty) return;
    try {
      final message = jsonDecode(data.toString());
      if (message is! Map<String, dynamic>) return;
      if (message['type'] == 'resync_required') {
        final socket = _socket;
        _socket = null;
        unawaited(socket?.close(WebSocketStatus.normalClosure) ?? Future<void>.value());
        return;
      }
      if (message['type'] != 'event') return;
      final stream = message['stream']?.toString();
      if (stream == 'unit') {
        _unitCursor = message['sequence']?.toString() ?? _unitCursor;
        return;
      }
      _incidentCursor = message['sequence']?.toString() ?? _incidentCursor;
      final type = message['event_type']?.toString() ?? '';
      final payload = message['payload'];
      if (payload is! Map) return;
      final id = payload['id']?.toString() ?? payload['entry_id']?.toString();
      if (id == null || id.isEmpty) return;
      if (type == 'entry.created' || type == 'entry.pressure_updated') {
        _backgroundEntries[id] = {
          'name': payload['name'] ?? '?',
          'exitAt': (payload['exit_at'] as num?)?.toInt() ?? 0,
        };
      } else if (type == 'entry.exited') {
        _backgroundEntries.remove(id);
      }
      unawaited(_updateNotificationFromEntries());
    } catch (_) {}
  }

  Future<void> _updateNotificationFromEntries() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final active = _backgroundEntries.values.toList()
      ..removeWhere((item) => (item['exitAt'] as int? ?? 0) <= 0);
    active.sort((a, b) => (a['exitAt'] as int).compareTo(b['exitAt'] as int));
    if (active.isEmpty) {
      await FlutterForegroundTask.updateService(
        notificationTitle: '火场指挥中',
        notificationText: '当前暂无在场人员',
      );
      return;
    }
    final earliest = active.first;
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
    await FlutterForegroundTask.updateService(
      notificationTitle: '火场指挥中 · 在场 ${active.length} 人$status',
      notificationText: '最早剩余 ${_fmt(leftMs)}（${earliest['name']}）',
    );
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
