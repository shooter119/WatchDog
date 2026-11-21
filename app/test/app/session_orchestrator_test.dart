import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/app/app_scope.dart';
import 'package:watchdog/app/orchestrators/orchestrator_contracts.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/core/sync/sync_store.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/video_playback_session.dart';

class _FakeSyncDriver implements IncidentSyncDriver {
  bool _running = false;
  int startCount = 0;
  int stopCount = 0;
  int checkpointCount = 0;
  String? lastIncidentId;

  @override
  bool get running => _running;
  @override
  Future<void> start({String? incidentId}) async {
    startCount++;
    lastIncidentId = incidentId;
    _running = true;
  }

  @override
  Future<void> switchIncident(String? incidentId) async =>
      lastIncidentId = incidentId;
  @override
  Future<void> checkpointNow({bool force = false}) async => checkpointCount++;
  @override
  Future<void> stop() async {
    stopCount++;
    _running = false;
  }
}

http.Response _json(Object body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void _seedAuth(int expiresAt, {String realName = '张三', String unitName = '示例市消防救援支队', String unitId = 'u-1', String token = 'tok-1', String incidentId = ''}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'server_url': 'http://test',
    'real_name': realName,
    'unit_id': unitId,
    'unit_name': unitName,
    'unit_code': '1001',
    'session_token': token,
    'session_expires_at': expiresAt,
    if (incidentId.isNotEmpty) 'current_incident_id': incidentId,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{'server_url': 'http://test'});
  });

  AppScope buildScope({
    required Future<http.Response> Function(http.Request req) handler,
    int Function()? nowMs,
    List<_FakeSyncDriver>? drivers,
    IncidentDomainHooks domainHooks = IncidentDomainHooks.empty,
    Duration sessionRefreshInterval = const Duration(minutes: 15),
    void Function({required bool inForeground, required bool syncConnected})? reportLifecycle,
  }) => AppScope(
    videoPlaybackSession: VideoPlaybackSession.forTesting(),
    createDefaultLocalAsr: false,
    enableStartupMaintenance: false,
    deviceIdProvider: () async => 'dev-test-01',
    nowMs: nowMs,
    sessionRefreshInterval: sessionRefreshInterval,
    adminCapabilityInterval: const Duration(hours: 1),
    domainHooks: domainHooks,
    reportLifecycle: reportLifecycle ?? ({required inForeground, required syncConnected}) {},
    transportFactory: (c) => ApiHttpTransport(c, clientFactory: () => MockClient(handler)),
    syncDriverFactory: ({required config, required onSnapshot, required onEvent, required onState, required onStaleIncident}) {
      final d = _FakeSyncDriver();
      drivers?.add(d);
      return d;
    },
  );

  group('AppScope DI 容器与释放', () {
    test('创建全部 Store 与 Orchestrator 并支持幂等释放', () {
      final scope = buildScope(handler: (_) async => _json({}));
      expect(scope.isDisposed, isFalse);
      expect(scope.syncStore.isDisposed, isFalse);
      expect(scope.sessionStore.isDisposed, isFalse);
      expect(scope.incidentStore.disposed, isFalse);
      expect(scope.rosterStore.disposed, isFalse);
      expect(scope.updateStore.isDisposed, isFalse);
      expect(scope.sessionOrchestrator.isDisposed, isFalse);
      expect(scope.incidentOrchestrator.isDisposed, isFalse);

      scope.dispose();
      scope.dispose();
      expect(scope.isDisposed, isTrue);
      expect(scope.syncStore.isDisposed, isTrue);
      expect(scope.sessionStore.isDisposed, isTrue);
      expect(scope.incidentStore.disposed, isTrue);
      expect(scope.rosterStore.disposed, isTrue);
      expect(scope.updateStore.isDisposed, isTrue);
      expect(scope.sessionOrchestrator.isDisposed, isTrue);
      expect(scope.incidentOrchestrator.isDisposed, isTrue);
    });
  });

  group('SessionOrchestrator 认证、游客模式与退单清理', () {
    test('authenticate 校验必填字段并完成验证+探测+持久化+启动同步', () async {
      const now = 1_700_000_000_000;
      final drivers = <_FakeSyncDriver>[];
      final paths = <String>[];
      final scope = buildScope(
        nowMs: () => now,
        drivers: drivers,
        handler: (req) async {
          paths.add(req.url.path);
          if (req.url.path == '/api/auth/verify') {
            return _json({
              'unit': {'id': 'u-1', 'name': '示例市消防救援支队'},
              'user': {'id': 'm-1', 'role': 'admin'},
              'session_token': 'tok-valid-1',
              'expires_at': now + const Duration(hours: 6).inMilliseconds,
              'roster': {
                'firefighters': [{'id': 'f-1', 'name': '张三'}],
                'hotwords': [{'id': 'h-1', 'word': '排烟'}],
              },
              'stations': [{'id': 's-1', 'name': '示例路站'}],
            });
          }
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          if (req.url.path == '/api/admin-app/capability') return _json({'member': null});
          if (req.url.path == '/api/user-settings') return _json({'settings': {}, 'updated_at': 0});
          return _json([]);
        },
      );
      addTearDown(scope.dispose);

      await expectLater(
        () => scope.sessionOrchestrator.authenticate(unitName: ' ', realName: '张三', unitCode: '1001'),
        throwsA(isA<StateError>()),
      );

      final epochBefore = scope.sessionStore.protectedDataEpoch;
      await scope.sessionOrchestrator.authenticate(
        unitName: '示例市消防救援支队',
        realName: '张三',
        unitCode: '1001',
      );
      expect(paths, containsAll(['/api/auth/verify', '/api/incidents']));
      expect(scope.sessionStore.authenticated, isTrue);
      expect(scope.sessionStore.protectedDataRevoked, isFalse);
      expect(scope.sessionStore.protectedDataEpoch, epochBefore + 1);
      expect(await Settings.sessionToken, 'tok-valid-1');
      expect(await Settings.unitId, 'u-1');
      expect(scope.rosterStore.firefighters.map((f) => f.name), ['张三']);
      expect(scope.rosterStore.stations.map((s) => s.name), ['示例路站']);
      expect(drivers.single.running, isTrue);
    });

    test('enterGuestMode 吊销受保护数据一次并初始化单机演练警情', () async {
      final scope = buildScope(handler: (_) async => _json({}));
      addTearDown(scope.dispose);
      final epochBefore = scope.sessionStore.protectedDataEpoch;

      await scope.sessionOrchestrator.enterGuestMode();
      expect(scope.sessionStore.isGuest, isTrue);
      expect(scope.sessionStore.authenticated, isFalse);
      expect(scope.sessionStore.protectedDataRevoked, isTrue);
      expect(scope.sessionStore.protectedDataEpoch, epochBefore + 1);
      expect(await Settings.isGuestMode, isTrue);
      expect(scope.incidentStore.currentIncident?.id, 'guest-drill-incident');
      expect(scope.syncStore.syncing, isFalse);
    });

    test('leaveUnit 注销远端并原子清理全部 Store、定时任务与本地凭据', () async {
      const now = 1_700_000_000_000;
      var logoutCalls = 0, clearedDomain = 0, stoppedKeepAlive = 0, clearedNotif = 0, stoppedTick = 0;
      final drivers = <_FakeSyncDriver>[];
      _seedAuth(now + const Duration(hours: 5).inMilliseconds, incidentId: 'inc-1');
      final scope = buildScope(
        nowMs: () => now,
        drivers: drivers,
        domainHooks: IncidentDomainHooks(
          onClearIncidentDomainData: () => clearedDomain++,
          onStopKeepAlive: () async => stoppedKeepAlive++,
          onClearScheduledNotifications: () async => clearedNotif++,
          onStopTickTimer: () => stoppedTick++,
          onFlushLocalOpLogs: () async {},
        ),
        handler: (req) async {
          if (req.url.path == '/api/auth/logout') {
            logoutCalls++;
            return _json({'ok': true});
          }
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      await scope.incidentOrchestrator.realtimeStartFuture;
      final genBefore = scope.sessionOrchestrator.sessionGeneration;
      final epochBefore = scope.sessionStore.protectedDataEpoch;

      await scope.sessionOrchestrator.leaveUnit();
      expect(logoutCalls, 1);
      expect(scope.sessionOrchestrator.sessionGeneration, genBefore + 1);
      expect(scope.sessionStore.protectedDataEpoch, epochBefore + 1);
      expect(scope.sessionStore.authenticated, isFalse);
      expect(scope.sessionStore.protectedDataRevoked, isTrue);
      expect(scope.incidentStore.currentIncident, isNull);
      expect(scope.rosterStore.firefighters, isEmpty);
      expect(scope.syncStore.syncStarted, isFalse);
      expect(clearedDomain, 1);
      expect(stoppedKeepAlive, 1);
      expect(clearedNotif, 1);
      expect(stoppedTick, 1);
      expect(drivers.first.running, isFalse);
      expect(await Settings.sessionToken, isEmpty);
      expect(await Settings.realName, isEmpty);
      expect(await Settings.unitName, isEmpty);
      expect(await Settings.currentIncidentId, isEmpty);
    });
  });

  group('SessionOrchestrator 401 并发去重、15 分钟续期与代际防护', () {
    test('5 路并发 401 吊销去重：generation 与 protectedDataEpoch 仅递增一次且保留实名', () async {
      const now = 1_700_000_000_000;
      var logoutCalls = 0;
      _seedAuth(
        now + const Duration(hours: 4).inMilliseconds,
        realName: '李四',
        unitName: '示例县消防救援大队',
        unitId: 'u-2',
        token: 'tok-2',
        incidentId: 'inc-2',
      );
      final scope = buildScope(
        nowMs: () => now,
        handler: (req) async {
          if (req.url.path == '/api/auth/logout') logoutCalls++;
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      final genBefore = scope.sessionOrchestrator.sessionGeneration;
      final epochBefore = scope.sessionStore.protectedDataEpoch;

      final futures = List.generate(
        5,
        (_) => scope.sessionOrchestrator.invalidateAuthenticationOnce(),
      );
      expect(identical(futures[0], futures[1]), isTrue);
      expect(identical(futures[0], futures[4]), isTrue);
      await Future.wait(futures);

      expect(logoutCalls, 0);
      expect(scope.sessionOrchestrator.sessionGeneration, genBefore + 1);
      expect(scope.sessionStore.protectedDataEpoch, epochBefore + 1);
      expect(scope.sessionStore.authenticated, isFalse);
      expect(scope.sessionStore.protectedDataRevoked, isTrue);
      expect(await Settings.sessionToken, isEmpty);
      expect(await Settings.unitId, isEmpty);
      expect(await Settings.realName, '李四');
      expect(await Settings.unitName, '示例县消防救援大队');
    });

    test('会话临期自动续期 + 15 分钟周期定时续期 + 过期立即吊销', () async {
      var now = 1_700_000_000_000;
      var refreshCalls = 0;
      final refreshedTo = now + const Duration(hours: 8).inMilliseconds;
      _seedAuth(now + const Duration(minutes: 30).inMilliseconds, token: 'tok-ref');
      final scope = buildScope(
        nowMs: () => now,
        sessionRefreshInterval: const Duration(milliseconds: 40),
        handler: (req) async {
          if (req.url.path == '/api/auth/refresh') {
            refreshCalls++;
            return _json({'expires_at': refreshedTo});
          }
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(refreshCalls, 1);
      expect(await Settings.sessionExpiresAt, refreshedTo);

      await scope.sessionOrchestrator.refreshSession();
      expect(refreshCalls, 1);

      now = refreshedTo + 1000;
      await expectLater(() => scope.sessionOrchestrator.refreshSession(), throwsA(isA<StateError>()));
      expect(scope.sessionStore.authenticated, isFalse);
      expect(await Settings.sessionToken, isEmpty);
    });

    test('代际防护：慢速续期在 leaveUnit 之后返回时绝不覆写已清理会话', () async {
      const now = 1_700_000_000_000;
      final refreshGate = Completer<http.Response>();
      _seedAuth(now + const Duration(minutes: 10).inMilliseconds, token: 'tok-stale');
      final scope = buildScope(
        nowMs: () => now,
        handler: (req) async {
          if (req.url.path == '/api/auth/refresh') return refreshGate.future;
          if (req.url.path == '/api/auth/logout') return _json({'ok': true});
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      final pending = scope.sessionOrchestrator.refreshSession(force: true);
      await Future<void>.delayed(Duration.zero);

      await scope.sessionOrchestrator.leaveUnit();
      refreshGate.complete(_json({'expires_at': now + const Duration(hours: 12).inMilliseconds}));
      await pending;

      expect(scope.sessionStore.authenticated, isFalse);
      expect(await Settings.sessionExpiresAt, 0);
      expect(await Settings.sessionToken, isEmpty);
    });

    test('前后台生命周期：handleAppPaused/Resumed 切换状态并触发断线检测与 checkpoint', () async {
      var now = 1_700_000_000_000;
      final lifecycle = <(bool, bool)>[];
      var tickRestarts = 0;
      final drivers = <_FakeSyncDriver>[];
      _seedAuth(now + const Duration(hours: 5).inMilliseconds, token: 'tok-life');
      final scope = buildScope(
        nowMs: () => now,
        drivers: drivers,
        domainHooks: IncidentDomainHooks(onRestartTickTimer: () => tickRestarts++),
        reportLifecycle: ({required inForeground, required syncConnected}) =>
            lifecycle.add((inForeground, syncConnected)),
        handler: (req) async {
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      await scope.incidentOrchestrator.realtimeStartFuture;
      scope.sessionOrchestrator.handleAppPaused();
      expect(scope.sessionOrchestrator.appInForeground, isFalse);
      expect(lifecycle.last, (false, false));

      scope.syncStore.applyConnectionState(SyncConnectionState.reconnecting, error: 'timeout');
      now += 35_000;
      final before = drivers.first.checkpointCount;
      await scope.sessionOrchestrator.handleAppResumed();
      expect(scope.sessionOrchestrator.appInForeground, isTrue);
      expect(scope.syncStore.connectionLost, isTrue);
      expect(lifecycle.last, (true, false));
      expect(drivers.first.checkpointCount, before + 1);
      expect(tickRestarts, greaterThanOrEqualTo(2));
    });

    test('init 检测到本地已过期会话时自动吊销并阻止未认证启动同步', () async {
      const now = 1_700_000_000_000;
      final drivers = <_FakeSyncDriver>[];
      _seedAuth(now - 5000, token: 'tok-expired');
      final scope = buildScope(
        nowMs: () => now,
        drivers: drivers,
        handler: (_) async => _json({}),
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      expect(scope.sessionStore.authenticated, isFalse);
      expect(scope.sessionStore.protectedDataRevoked, isTrue);
      expect(await Settings.sessionToken, isEmpty);
      expect(drivers, isEmpty);
    });

    test('authenticate 受保护探测失败时中止落盘，不污染认证状态', () async {
      const now = 1_700_000_000_000;
      final scope = buildScope(
        nowMs: () => now,
        handler: (req) async {
          if (req.url.path == '/api/auth/verify') {
            return _json({
              'unit': {'id': 'u-1', 'name': '示例市消防救援支队'},
              'session_token': 'tok-bad',
              'expires_at': now + 3600000,
            });
          }
          if (req.url.path == '/api/incidents') {
            return _json({'error': '会话无效', 'code': 'SESSION_REQUIRED'}, status: 401);
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await expectLater(
        () => scope.sessionOrchestrator.authenticate(
          unitName: '示例市消防救援支队',
          realName: '张三',
          unitCode: '1001',
        ),
        throwsA(isA<ApiException>()),
      );
      expect(scope.sessionStore.authenticated, isFalse);
      expect(await Settings.sessionToken, isEmpty);
    });
  });
}
