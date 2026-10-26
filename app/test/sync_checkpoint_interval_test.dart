import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/services/sync_coordinator.dart';

/// 只用于构造 coordinator：bootstrap 必然失败，因此不会建立 WS。
class _FailingBootstrapApi extends ApiClient {
  _FailingBootstrapApi()
      : super(baseUrl: 'http://127.0.0.1:1', incidentId: 'test-incident');

  @override
  Future<Map<String, dynamic>> fetchSyncBootstrap({String? forIncidentId}) async {
    throw StateError('offline');
  }
}

void main() {
  test('连接期 120 秒、断线 30 秒的降频规则', () {
    expect(
      SyncCoordinator.checkpointIntervalFor(connected: true),
      const Duration(seconds: 120),
    );
    expect(
      SyncCoordinator.checkpointIntervalFor(connected: false),
      const Duration(seconds: 30),
    );
  });

  test('bootstrap 失败（无 WS）时检查点定时器使用 30 秒兜底周期', () async {
    final api = _FailingBootstrapApi();
    final coordinator = SyncCoordinator(
      api: api,
      onSnapshot: (_) {},
      onEvent: (_) {},
      onState: (_, __) {},
    );
    addTearDown(() async {
      await coordinator.stop();
      api.dispose();
    });

    await coordinator.start();
    expect(coordinator.debugCheckpointTimerPeriod, const Duration(seconds: 30));
    expect(coordinator.checkpointInterval, const Duration(seconds: 30));
  });
}
