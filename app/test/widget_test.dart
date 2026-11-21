import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/state/app_controller.dart';

class _SelectIncidentController extends AppController {
  @override
  bool get needsAuthentication => false;

  @override
  Future<void> init() async {}

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<void> refreshConfig() async {}

  @override
  Future<void> syncKeepAlive() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('连接状态（平滑阈值）', () {
    test('isConnectionLost：从未成功乐观绿，30 秒阈值判定', () {
      const now = 1_000_000;
      expect(isConnectionLost(lastSyncSuccessAt: 0, nowMs: now), false);
      expect(
        isConnectionLost(lastSyncSuccessAt: now - 1000, nowMs: now),
        false,
      );
      expect(
        isConnectionLost(lastSyncSuccessAt: now - 29000, nowMs: now),
        false,
      );
      expect(
        isConnectionLost(lastSyncSuccessAt: now - 30000, nowMs: now),
        false,
      );
      expect(
        isConnectionLost(lastSyncSuccessAt: now - 30001, nowMs: now),
        true,
      );
      expect(
        isConnectionLost(lastSyncSuccessAt: now - 60000, nowMs: now),
        true,
      );
      expect(
        isConnectionLost(
          lastSyncSuccessAt: now - 60000,
          nowMs: now,
          syncConnected: true,
        ),
        false,
      );
    });
  });

  group('警情选择流程', () {
    test('加入已有警情先完成本机选择，不等待后台同步', () async {
      SharedPreferences.setMockInitialValues({});
      final c = _SelectIncidentController()..currentIncident = null;
      addTearDown(c.dispose);
      const incident = Incident(
        id: 'known-incident',
        number: '2026-8-9-8-59',
        title: '已存在警情',
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );

      await c.selectIncident(incident.id, knownIncident: incident);

      expect(c.currentIncident, same(incident));
      expect(await Settings.currentIncidentId, incident.id);
    });
  });
}
