import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/services/foreground_keep_alive.dart';
import 'package:watchdog/state/app_controller.dart';

class _RecordingKeepAliveClient extends http.BaseClient {
  final requests = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.headers['X-Incident-Id'] ?? '');
    return http.StreamedResponse(
      Stream<List<int>>.value(<int>[91, 93]),
      HttpStatus.ok,
      contentLength: 2,
      request: request,
    );
  }

  @override
  void close() {}
}

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
}
