import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/admin_login.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/board_page.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/op_log_service.dart';
import 'package:watchdog/services/realtime_sync_client.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/sync_coordinator.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

class _FakeAudioService extends AudioService {
  @override
  Future<void> dispose() async {}
}

class _FakeRealtimeClient extends RealtimeClient {
  _FakeRealtimeClient({
    required super.api,
    required super.onMessage,
    super.onError,
    super.onDone,
  });

  bool _connected = false;
  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  bool get connected => _connected;

  @override
  Future<void> connect({
    required String unitCursor,
    required String incidentCursor,
    String? incidentId,
  }) async {
    connectCalls++;
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected = false;
  }

  void simulateDrop() {
    _connected = false;
    onDone?.call();
  }
}

class _ColdStartSyncApi extends ApiClient {
  _ColdStartSyncApi({
    super.baseUrl = 'https://api.fireman119.xyz',
    super.incidentId = 'inc-1',
  }) : super(
         sessionToken: 'session-token',
         deviceId: 'dev-test',
         actorName: '张伟',
         unitId: 'unit-1',
         unitCode: '1001',
       );

  Object? bootstrapError;
  Object? checkpointError;
  Completer<Map<String, dynamic>>? bootstrapGate;

  int bootstrapCalls = 0;
  int checkpointCalls = 0;
  int eventsCalls = 0;
  int firefightersCalls = 0;
  int hotwordsCalls = 0;
  int stationsCalls = 0;
  int adminCapabilityCalls = 0;
  int memberReviewCapabilityCalls = 0;
  int userSettingsCalls = 0;
  int sendLogsCalls = 0;
  int refreshSessionCalls = 0;

  Map<String, dynamic> buildSnapshot() => <String, dynamic>{
    'cursors': {'unit': '5', 'incident': '12'},
    'unit': {'id': 'unit-1', 'name': '示例市消防救援支队'},
    'roster': {
      'firefighters': [
        {'id': 'f1', 'name': '张伟', 'source': 'builtin'},
        {'id': 'f2', 'name': '李娜', 'source': 'user'},
      ],
      'hotwords': [
        {'id': 'h1', 'word': '空气呼吸器', 'source': 'builtin'},
      ],
    },
    'stations': [
      {'id': 's1', 'name': '示例路站'},
    ],
    'active_incidents': [
      {
        'id': 'inc-1',
        'number': '20261115-001',
        'title': '示例小区测试警情',
        'status': 'active',
        'created_at': 1700000000000,
        'last_activity_at': 1700000000000,
      },
    ],
    'incident_snapshot': {
      'incident': {
        'id': 'inc-1',
        'number': '20261115-001',
        'title': '示例小区测试警情',
        'status': 'active',
        'created_at': 1700000000000,
        'last_activity_at': 1700000000000,
      },
      'entries': <Map<String, dynamic>>[],
      'notes': <Map<String, dynamic>>[],
      'forces': <Map<String, dynamic>>[],
    },
  };

  @override
  Future<Map<String, dynamic>> fetchSyncBootstrap({
    String? forIncidentId,
  }) async {
    bootstrapCalls++;
    final gate = bootstrapGate;
    if (gate != null && !gate.isCompleted) {
      return gate.future;
    }
    if (bootstrapError != null) throw bootstrapError!;
    return buildSnapshot();
  }

  @override
  Future<Map<String, dynamic>> fetchSyncCheckpoint({
    String? forIncidentId,
  }) async {
    checkpointCalls++;
    if (checkpointError != null) throw checkpointError!;
    return {
      'cursors': {'unit': '5', 'incident': '12'},
    };
  }

  @override
  Future<List<Map<String, dynamic>>> fetchSyncEvents({
    required String unitCursor,
    required String incidentCursor,
    String? forIncidentId,
    int limit = 500,
  }) async {
    eventsCalls++;
    return const [];
  }

  @override
  Future<List<Firefighter>> fetchFirefighters() async {
    firefightersCalls++;
    return [Firefighter(id: 'f1', name: '张伟')];
  }

  @override
  Future<List<Hotword>> fetchHotwords() async {
    hotwordsCalls++;
    return [Hotword(id: 'h1', word: '空气呼吸器')];
  }

  @override
  Future<List<Station>> fetchStations() async {
    stationsCalls++;
    return [const Station(id: 's1', name: '示例路站')];
  }

  @override
  Future<AdminCapability?> fetchAdminCapability() async {
    adminCapabilityCalls++;
    return null;
  }

  @override
  Future<bool> fetchMemberReviewCapability() async {
    memberReviewCapabilityCalls++;
    return false;
  }

  @override
  Future<Map<String, dynamic>> fetchUserSettings() async {
    userSettingsCalls++;
    return {'updatedAt': 0, 'settings': <String, dynamic>{}};
  }

  @override
  Future<void> pushUserSettings(Map<String, dynamic> settings) async {}

  @override
  Future<void> sendLogs(List<Map<String, dynamic>> entries) async {
    sendLogsCalls++;
  }

  @override
  Future<Map<String, dynamic>> refreshSession() async {
    refreshSessionCalls++;
    return {
      'expires_at': DateTime.now()
          .add(const Duration(hours: 8))
          .millisecondsSinceEpoch,
    };
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://api.fireman119.xyz',
      'real_name': '张伟',
      'unit_id': 'unit-1',
      'unit_code': '1001',
      'unit_name': '示例市消防救援支队',
      'session_token': 'session-token',
      'session_expires_at': DateTime.now()
          .add(const Duration(hours: 8))
          .millisecondsSinceEpoch,
      'current_incident_id': 'inc-1',
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('watchdog/screen'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
  });

  AppController createController(
    _ColdStartSyncApi api,
    List<_FakeRealtimeClient> clients,
  ) {
    return AppController(
      apiFactory:
          ({
            required baseUrl,
            required incidentId,
            required sessionToken,
            required deviceId,
            required actorName,
            required unitId,
            required unitCode,
            onAuthenticationFailure,
          }) => api,
      syncClientFactory:
          ({required api, required onMessage, onError, onDone}) {
            final client = _FakeRealtimeClient(
              api: api,
              onMessage: onMessage,
              onError: onError,
              onDone: onDone,
            );
            clients.add(client);
            return client;
          },
    );
  }

  testWidgets(
    '冷启动 DNS 解析失败保持顺滑“同步中”，恢复后 refreshNow 重新 bootstrap 并建连',
    (tester) async {
      final api = _ColdStartSyncApi()
        ..bootstrapError = const SocketException(
          "Failed host lookup: 'api.fireman119.xyz'",
          osError: OSError('No address associated with hostname', 7),
        );
      final clients = <_FakeRealtimeClient>[];
      final controller = createController(api, clients);
      try {
        await controller.init();
        await tester.pump();

        expect(api.bootstrapCalls, 1);
        expect(api.checkpointCalls, 0);
        expect(controller.syncing, isTrue);
        expect(controller.syncError, isNull);
        expect(controller.connectionLost, isFalse);
        expect(controller.syncConnectionState, SyncConnectionState.reconnecting);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, __) => HomePage(
                  controller: controller,
                  audioService: _FakeAudioService(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('同步中'), findsOneWidget);
        expect(find.text('同步失败'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);
        expect(find.textContaining('SocketException'), findsNothing);
        expect(find.textContaining('Failed host lookup'), findsNothing);
        expect(find.textContaining('网络已中断'), findsNothing);

        // 点击首页连接胶囊打开详情弹窗，确认无“同步异常”字样且状态为“状态：同步中”
        await tester.tap(find.byType(ConnectionStatus));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('连接与同步状态'), findsOneWidget);
        expect(find.text('状态：同步中'), findsOneWidget);
        expect(find.textContaining('同步异常'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);
        expect(find.textContaining('SocketException'), findsNothing);

        // 关闭弹窗并切换到 BoardPage 检查断网续传期间同样只展示“同步中”，不弹断线横幅
        await tester.tap(find.text('立即重试同步'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, __) => BoardPage(controller: controller),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('同步中'), findsOneWidget);
        expect(find.text('同步失败'), findsNothing);
        expect(find.textContaining('网络已中断'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);

        // 超过 30s 阈值但仍在自动重连同步中时，看板仍不展示红色断线横幅
        api.bootstrapError = http.ClientException(
          "SocketException: Failed host lookup: 'api.fireman119.xyz'",
        );
        await tester.pump(const Duration(seconds: 31));
        expect(controller.syncing, isTrue);
        expect(controller.syncError, isNull);
        expect(find.text('同步中'), findsOneWidget);
        expect(find.textContaining('网络已中断'), findsNothing);

        // 恢复网络后切回 HomePage，调用 refreshNow() 必须重新执行 fetchSyncBootstrap 而非死锁在 checkpoint
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, __) => HomePage(
                  controller: controller,
                  audioService: _FakeAudioService(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        api.bootstrapError = null;
        final callsBeforeRecovery = api.bootstrapCalls;
        final firefightersBeforeRecovery = api.firefightersCalls;
        await controller.refreshNow();
        await tester.pump();

        expect(api.bootstrapCalls, callsBeforeRecovery + 1);
        expect(api.checkpointCalls, 0);
        expect(clients, isNotEmpty);
        expect(clients.last.connectCalls, 1);
        expect(clients.last.connected, isTrue);
        expect(controller.syncConnectionState, SyncConnectionState.connected);
        expect(controller.syncing, isFalse);
        expect(controller.syncError, isNull);
        expect(controller.connectionLost, isFalse);
        expect(controller.firefighters.map((f) => f.name), containsAll(['张伟', '李娜']));
        expect(api.firefightersCalls, firefightersBeforeRecovery);
        expect(find.text('已连接'), findsOneWidget);
        expect(find.text('同步中'), findsNothing);
        expect(
          OpLogService.instance.logs.any((entry) => entry.stage == 'sync_retry'),
          isTrue,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.pump();
      }
    },
  );

  testWidgets('未完成 bootstrap 时 30 秒周期检查点自动走 _bootstrapAndConnect 恢复', (
    tester,
  ) async {
    final api = _ColdStartSyncApi()
      ..bootstrapError = const SocketException(
        "Failed host lookup: 'api.fireman119.xyz'",
        osError: OSError('No address associated with hostname', 7),
      );
    final clients = <_FakeRealtimeClient>[];
    final states = <SyncConnectionState>[];
    final coordinator = SyncCoordinator(
      api: api,
      onSnapshot: (_) {},
      onEvent: (_) {},
      onState: (state, _) => states.add(state),
      clientFactory: ({required api, required onMessage, onError, onDone}) {
        final client = _FakeRealtimeClient(
          api: api,
          onMessage: onMessage,
          onError: onError,
          onDone: onDone,
        );
        clients.add(client);
        return client;
      },
    );
    try {
      await coordinator.start(incidentId: 'inc-1');
      expect(api.bootstrapCalls, 1);
      expect(states.last, SyncConnectionState.reconnecting);

      // 推进 1s + 2s + 5s + 10s = 18s（均失败，第 5 次重连将排到 38s），随后恢复网络
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 10));
      expect(api.bootstrapCalls, 5);
      expect(clients, isEmpty);

      api.bootstrapError = null;
      // 在 30s 检查点定时器触发（t=30s）时必须先执行 bootstrap + WS 建连，而不是调 checkpoint
      await tester.pump(const Duration(seconds: 12));

      expect(api.bootstrapCalls, 6);
      expect(api.checkpointCalls, 0);
      expect(clients, hasLength(1));
      expect(clients.single.connected, isTrue);
      expect(states.last, SyncConnectionState.connected);
    } finally {
      await coordinator.stop();
      api.dispose();
      await tester.pump();
    }
  });

  testWidgets('App 从后台回到前台时若同步未连接则立即触发 checkpointNow 恢复', (
    tester,
  ) async {
    final api = _ColdStartSyncApi()
      ..bootstrapError = const SocketException(
        "Failed host lookup: 'api.fireman119.xyz'",
        osError: OSError('No address associated with hostname', 7),
      );
    final clients = <_FakeRealtimeClient>[];
    final controller = createController(api, clients);
    try {
      await controller.init();
      await tester.pump();
      expect(controller.syncConnectionState, SyncConnectionState.reconnecting);
      final callsBeforeResume = api.bootstrapCalls;

      api.bootstrapError = null;
      await controller.handleAppResumed();
      await tester.pump();

      expect(api.bootstrapCalls, callsBeforeResume + 1);
      expect(api.checkpointCalls, 0);
      expect(clients, hasLength(1));
      expect(clients.single.connected, isTrue);
      expect(controller.syncConnectionState, SyncConnectionState.connected);
      expect(controller.syncing, isFalse);
      expect(controller.syncError, isNull);
    } finally {
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets('冷启动请求错峰且 bootstrap 已含名单时跳过冗余 fetchFirefighters/fetchHotwords', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    final api = _ColdStartSyncApi()..bootstrapGate = gate;
    final clients = <_FakeRealtimeClient>[];
    final controller = createController(api, clients);
    try {
      await controller.init();
      await tester.pump();

      // bootstrap 尚未完成时，次要启动请求全部等待，不与冷启动抢占连接/DNS
      expect(api.bootstrapCalls, 1);
      expect(api.adminCapabilityCalls, 0);
      expect(api.firefightersCalls, 0);
      expect(api.hotwordsCalls, 0);
      expect(api.stationsCalls, 0);
      expect(api.userSettingsCalls, 0);
      expect(api.memberReviewCapabilityCalls, 0);
      expect(api.sendLogsCalls, 0);

      gate.complete(api.buildSnapshot());
      await tester.pump();
      await tester.pump();

      expect(controller.syncConnectionState, SyncConnectionState.connected);
      expect(controller.firefighters.map((f) => f.name), ['张伟', '李娜']);
      expect(controller.hotwords.map((h) => h.word), ['空气呼吸器']);
      expect(controller.stations.map((s) => s.name), ['示例路站']);
      expect(api.firefightersCalls, 0);
      expect(api.hotwordsCalls, 0);
      expect(api.stationsCalls, 0);
      expect(api.adminCapabilityCalls, 1);
      expect(api.userSettingsCalls, 1);
      expect(api.memberReviewCapabilityCalls, 1);
    } finally {
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets('bootstrap 返回 401 SESSION_EXPIRED 时立即失效认证且不进入重连死循环', (
    tester,
  ) async {
    final api = _ColdStartSyncApi()
      ..bootstrapError = ApiException(
        '认证会话已过期，请重新认证',
        statusCode: 401,
        code: 'SESSION_EXPIRED',
      );
    final clients = <_FakeRealtimeClient>[];
    final controller = createController(api, clients);
    try {
      await controller.init();
      await tester.pump();
      await tester.pump(const Duration(seconds: 35));

      expect(controller.needsAuthentication, isTrue);
      expect(controller.syncing, isFalse);
      expect(api.bootstrapCalls, 1);
      expect(clients, isEmpty);
      expect(await Settings.sessionToken, isEmpty);
    } finally {
      controller.dispose();
      await tester.pump();
    }
  });
}
