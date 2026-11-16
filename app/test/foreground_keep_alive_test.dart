import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/services/foreground_keep_alive.dart';
import 'package:watchdog/state/app_controller.dart';

class _RecordingKeepAliveClient extends http.BaseClient {
  _RecordingKeepAliveClient({this.responseBody = '[]'});

  final String responseBody;
  final requests = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.headers['X-Incident-Id'] ?? '');
    final bytes = utf8.encode(responseBody);
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      contentLength: bytes.length,
      request: request,
    );
  }

  @override
  void close() {}
}

class _RealHttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      'DIRECT';
}

Future<T> _withRealHttp<T>(Future<T> Function() fn) =>
    HttpOverrides.runWithHttpOverrides(fn, _RealHttpOverrides());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('主 isolate 摘要在 8 秒内新鲜时跳过服务端重复拉取', () {
    expect(isMainSnapshotFresh(lastSyncAt: 1000, nowMs: 8999), isTrue);
    expect(isMainSnapshotFresh(lastSyncAt: 1000, nowMs: 9000), isFalse);
  });

  test('未来时间戳不被误判为新鲜摘要', () {
    expect(isMainSnapshotFresh(lastSyncAt: 2000, nowMs: 1999), isFalse);
  });

  test('后台值守只有在已认证且已选择警情时运行', () {
    expect(
      shouldRunForegroundKeepAlive(
        enabled: true,
        authenticated: true,
        incidentId: 'incident-a',
      ),
      isTrue,
    );
    expect(
      shouldRunForegroundKeepAlive(
        enabled: true,
        authenticated: true,
        incidentId: '  ',
      ),
      isFalse,
    );
    expect(
      shouldRunForegroundKeepAlive(
        enabled: true,
        authenticated: false,
        incidentId: 'incident-a',
      ),
      isFalse,
    );
  });

  test('服务收到上下文刷新信号后使用新警情，不继续请求旧警情', () async {
    final client = _RecordingKeepAliveClient();
    SharedPreferences.setMockInitialValues({
      'com.pravera.flutter_foreground_task.prefs.keepalive_server_url':
          'http://localhost',
      'com.pravera.flutter_foreground_task.prefs.keepalive_incident_id': 'old',
      'com.pravera.flutter_foreground_task.prefs.keepalive_unit_id': 'unit',
      'com.pravera.flutter_foreground_task.prefs.keepalive_warn_min': 10,
      'com.pravera.flutter_foreground_task.prefs.keepalive_alarm_min': 5,
      'current_incident_id': 'old',
      'keepalive_token': 'token',
      'keepalive_session_token': 'session',
      'keepalive_unit_code': 'unit-code',
    });
    FlutterForegroundTask.skipServiceResponseCheck = true;
    final handler = WatchdogTaskHandler(httpClient: client);
    await handler.onStart(DateTime.now(), TaskStarter.developer);
    expect(client.requests, ['old']);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'com.pravera.flutter_foreground_task.prefs.keepalive_incident_id',
      'new',
    );
    await prefs.setString('current_incident_id', 'new');
    handler.onReceiveData({'type': 'keepalive_context_updated'});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(client.requests, ['old', 'new']);
    await handler.onDestroy(DateTime.now(), false);
    FlutterForegroundTask.resetStatic();
  });

  test('服务自恢复发现 App 无当前警情时不恢复旧监控', () async {
    final client = _RecordingKeepAliveClient();
    SharedPreferences.setMockInitialValues({
      'com.pravera.flutter_foreground_task.prefs.keepalive_server_url':
          'http://localhost',
      'com.pravera.flutter_foreground_task.prefs.keepalive_incident_id': 'old',
      'current_incident_id': '',
    });
    final handler = WatchdogTaskHandler(httpClient: client);

    await handler.onStart(DateTime.now(), TaskStarter.system);

    expect(client.requests, isEmpty);
    await handler.onDestroy(DateTime.now(), false);
  });

  test('非 Android 环境调用新增生命周期与快照上报接口安全空操作', () async {
    await ForegroundKeepAlive.start(
      serverUrl: 'https://example.invalid',
      incidentId: 'incident-a',
      token: 'token',
      sessionToken: 'session',
      unitId: 'unit',
      unitCode: '1001',
      warnMin: 10,
      alarmMin: 5,
      mainInForeground: true,
    );
    ForegroundKeepAlive.reportMainSnapshot(
      activeCount: 1,
      earliestExitAt: 123456,
      mainInForeground: true,
      mainSyncConnected: true,
    );
    ForegroundKeepAlive.reportMainLifecycle(
      inForeground: true,
      syncConnected: true,
    );
    await ForegroundKeepAlive.stop();
  });

  test('mainInForeground=true 且收到 main_lifecycle 或 main_snapshot 时不发起冗余 HTTP 与后台 WS', () async {
    final client = _RecordingKeepAliveClient(
      responseBody:
          '{"cursors":{"unit":"1","incident":"2"},"incident_snapshot":{"entries":[]}}',
    );
    final wsAttempts = <Map<String, dynamic>>[];
    SharedPreferences.setMockInitialValues({
      'com.pravera.flutter_foreground_task.prefs.keepalive_server_url':
          'http://127.0.0.1:8080',
      'com.pravera.flutter_foreground_task.prefs.keepalive_incident_id':
          'incident-a',
      'com.pravera.flutter_foreground_task.prefs.keepalive_unit_id': 'unit',
      'com.pravera.flutter_foreground_task.prefs.keepalive_warn_min': 10,
      'com.pravera.flutter_foreground_task.prefs.keepalive_alarm_min': 5,
      'com.pravera.flutter_foreground_task.prefs.keepalive_main_in_foreground':
          true,
      'current_incident_id': 'incident-a',
      'keepalive_token': 'token',
      'keepalive_session_token': 'session',
      'keepalive_unit_code': 'unit-code',
    });
    FlutterForegroundTask.skipServiceResponseCheck = true;
    final handler = WatchdogTaskHandler(
      httpClient: client,
      socketFactory: (url, {headers}) async {
        wsAttempts.add(Map<String, dynamic>.from(headers ?? const {}));
        throw const SocketException('should not connect');
      },
    );

    await handler.onStart(DateTime.now(), TaskStarter.developer);
    expect(client.requests, isEmpty);
    expect(wsAttempts, isEmpty);

    handler.onReceiveData({
      'type': 'main_lifecycle',
      'at': 1000,
      'inForeground': true,
      'syncConnected': true,
    });
    // 即使超过 8 秒且暂无快照，只要主通道在前台且已连接，也不得发起 HTTP 或 WS。
    handler.onRepeatEvent(DateTime.fromMillisecondsSinceEpoch(60000));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.requests, isEmpty);
    expect(wsAttempts, isEmpty);

    // 收到带前后台与连线标记的 main_snapshot 同样不发起冗余请求。
    handler.onReceiveData({
      'type': 'main_snapshot',
      'at': 61000,
      'activeCount': 2,
      'earliestExitAt': 180000,
      'mainInForeground': true,
      'mainSyncConnected': false,
    });
    handler.onRepeatEvent(DateTime.fromMillisecondsSinceEpoch(65000));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.requests, isEmpty);
    expect(wsAttempts, isEmpty);

    await handler.onDestroy(DateTime.now(), false);
    FlutterForegroundTask.resetStatic();
  });

  test('收到 main_lifecycle(false, false) 且超过新鲜窗口后按需接管，回前台连线后立即释放后台 WS', () => _withRealHttp(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSockets = <WebSocket>[];
    final serverSyncClients = <String?>[];
    final firstServerSocketDone = Completer<void>();
    final firstServerConnected = Completer<void>();

    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        serverSyncClients.add(request.headers.value('x-sync-client'));
        final ws = await WebSocketTransformer.upgrade(request);
        serverSockets.add(ws);
        if (!firstServerConnected.isCompleted) {
          firstServerConnected.complete();
        }
        ws.listen(
          (_) {},
          onDone: () {
            if (!firstServerSocketDone.isCompleted) {
              firstServerSocketDone.complete();
            }
          },
        );
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final client = _RecordingKeepAliveClient(
      responseBody:
          '{"cursors":{"unit":"1","incident":"2"},"incident_snapshot":{"entries":[]}}',
    );
    final wsHeaders = <Map<String, dynamic>>[];

    try {
      SharedPreferences.setMockInitialValues({
        'com.pravera.flutter_foreground_task.prefs.keepalive_server_url':
            'http://127.0.0.1:${server.port}',
        'com.pravera.flutter_foreground_task.prefs.keepalive_incident_id':
            'incident-a',
        'com.pravera.flutter_foreground_task.prefs.keepalive_unit_id': 'unit',
        'com.pravera.flutter_foreground_task.prefs.keepalive_warn_min': 10,
        'com.pravera.flutter_foreground_task.prefs.keepalive_alarm_min': 5,
        'com.pravera.flutter_foreground_task.prefs.keepalive_main_in_foreground':
            true,
        'current_incident_id': 'incident-a',
        'keepalive_token': 'token',
        'keepalive_session_token': 'session',
        'keepalive_unit_code': 'unit-code',
      });
      FlutterForegroundTask.skipServiceResponseCheck = true;

      final handler = WatchdogTaskHandler(
        httpClient: client,
        socketFactory: (url, {headers}) {
          wsHeaders.add(Map<String, dynamic>.from(headers ?? const {}));
          return WebSocket.connect(url, headers: headers);
        },
      );

      await handler.onStart(DateTime.now(), TaskStarter.developer);
      handler.onReceiveData({
        'type': 'main_snapshot',
        'at': 10000,
        'activeCount': 1,
        'earliestExitAt': 9999999999999,
        'mainInForeground': true,
        'mainSyncConnected': true,
      });
      handler.onReceiveData({
        'type': 'main_lifecycle',
        'at': 10100,
        'inForeground': false,
        'syncConnected': false,
      });

      // 仍在 8 秒新鲜窗口内，不提前接管。
      handler.onRepeatEvent(DateTime.fromMillisecondsSinceEpoch(15000));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.requests, isEmpty);
      expect(wsHeaders, isEmpty);

      // 超过 8 秒新鲜窗口后，后台值守按需拉取快照并建立 keepalive WebSocket。
      handler.onRepeatEvent(DateTime.fromMillisecondsSinceEpoch(18000));
      await firstServerConnected.future.timeout(const Duration(seconds: 3));
      expect(client.requests, ['incident-a']);
      expect(wsHeaders, hasLength(1));
      expect(wsHeaders.single['X-Sync-Client'], 'keepalive');
      expect(serverSyncClients, ['keepalive']);

      // 主 isolate 回到前台且连线就绪后，后台立即关闭 WebSocket 让位。
      handler.onReceiveData({
        'type': 'main_lifecycle',
        'at': 19000,
        'inForeground': true,
        'syncConnected': true,
      });
      await firstServerSocketDone.future.timeout(const Duration(seconds: 3));

      // 让位后再次触发周期回调，仍保持静默不重连。
      handler.onRepeatEvent(DateTime.fromMillisecondsSinceEpoch(60000));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.requests, ['incident-a']);
      expect(wsHeaders, hasLength(1));

      await handler.onDestroy(DateTime.now(), false);
    } finally {
      for (final ws in serverSockets) {
        await ws.close();
      }
      await server.close(force: true);
      FlutterForegroundTask.resetStatic();
    }
  }));
}
