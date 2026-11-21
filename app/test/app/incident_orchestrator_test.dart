import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/app/app_scope.dart';
import 'package:watchdog/app/orchestrators/orchestrator_contracts.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/core/sync/sync_store.dart';
import 'package:watchdog/features/incident/data/models/external_incident.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/data/models/incident_force.dart';
import 'package:watchdog/features/monitor/data/models/calc_config.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/sync_reducer.dart';
import 'package:watchdog/services/video_playback_session.dart';

class _FakeSyncDriver implements IncidentSyncDriver {
  bool _running = false;
  int startCount = 0, stopCount = 0, checkpointCalls = 0;
  bool lastForceCheckpoint = false;
  String? startedIncidentId;

  @override
  bool get running => _running;
  @override
  Future<void> start({String? incidentId}) async {
    startCount++;
    startedIncidentId = incidentId;
    _running = true;
  }

  @override
  Future<void> switchIncident(String? incidentId) async =>
      startedIncidentId = incidentId;
  @override
  Future<void> checkpointNow({bool force = false}) async {
    checkpointCalls++;
    lastForceCheckpoint = force;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _running = false;
  }
}

class _DomainHarness {
  List<Entry> entries = <Entry>[];
  List<Note> notes = <Note>[];
  int clearCount = 0, rescheduleCount = 0, clearNotifCount = 0, stopKeepAlive = 0;
  int? lastActiveCount, lastEarliestExit;

  IncidentDomainHooks toHooks() => IncidentDomainHooks(
    onClearIncidentDomainData: () {
      clearCount++;
      entries = <Entry>[];
      notes = <Note>[];
    },
    onApplySnapshotDomainData: ({required entries, required notes}) {
      this.entries = List<Entry>.of(entries);
      this.notes = List<Note>.of(notes);
    },
    onEntryEvent: (e) => entries = [e, ...entries.where((x) => x.id != e.id)],
    onNoteUpserted: (n) => notes = [n, ...notes.where((x) => x.id != n.id)],
    onNoteDeleted: (id) => notes = notes.where((x) => x.id != id).toList(),
    readEntries: () => entries,
    readNotes: () => notes,
    readCalcConfig: () => CalcConfig(
      cylinderVolL: 6.8,
      fullPressureMpa: 30,
      consumptionLpm: 80,
      warnMin: 10,
      alarmMin: 5,
    ),
    onRescheduleNotifications: () async => rescheduleCount++,
    onClearScheduledNotifications: () async => clearNotifCount++,
    onStopKeepAlive: () async => stopKeepAlive++,
    onReportMainSnapshot: ({required activeCount, required earliestExitAt, required mainInForeground, required mainSyncConnected}) {
      lastActiveCount = activeCount;
      lastEarliestExit = earliestExitAt;
    },
  );
}

http.Response _json(Object body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _incJson(String id, String title, {String status = 'active'}) => {
  'id': id,
  'number': 'INC-$id',
  'title': title,
  'status': status,
  'created_at': 1000,
  'last_activity_at': 2000,
  'version': 1,
};

Entry _sampleEntry(String id, String name) => Entry(
  id: id,
  name: name,
  pressureMpa: 28,
  durationMin: 20,
  entryAt: 1000,
  exitAt: 1200000,
  source: 'voice',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const baseNow = 1_700_000_000_000;

  void seedAuth({String incidentId = 'inc-a'}) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_url': 'http://test',
      'real_name': '张三',
      'unit_id': 'u-1',
      'unit_name': '示例市消防救援支队',
      'unit_code': '1001',
      'session_token': 'tok-1',
      'session_expires_at': baseNow + const Duration(hours: 6).inMilliseconds,
      'current_incident_id': incidentId,
    });
  }

  AppScope buildScope({
    required Future<http.Response> Function(http.Request req) handler,
    required _DomainHarness domain,
    List<_FakeSyncDriver>? drivers,
    bool enableDriver = true,
    OfflineQueueDrainerCallback? drainer,
    OfflinePendingRowsProvider? pendingRows,
  }) => AppScope(
    videoPlaybackSession: VideoPlaybackSession.forTesting(),
    createDefaultLocalAsr: false,
    enableStartupMaintenance: false,
    deviceIdProvider: () async => 'dev-inc-01',
    nowMs: () => baseNow,
    domainHooks: domain.toHooks(),
    reportLifecycle: ({required inForeground, required syncConnected}) {},
    offlineQueueDrainer: drainer,
    offlinePendingRowsProvider: pendingRows,
    transportFactory: (c) => ApiHttpTransport(c, clientFactory: () => MockClient(handler)),
    syncDriverFactory: enableDriver
        ? ({required config, required onSnapshot, required onEvent, required onState, required onStaleIncident}) {
            final d = _FakeSyncDriver();
            drivers?.add(d);
            return d;
          }
        : null,
  );

  group('IncidentOrchestrator 原子切换/新建/认领/归档/退出防串场', () {
    test('selectIncident 原子清空旧警情人员/日志/力量并重建同步，零串场污染', () async {
      seedAuth(incidentId: 'inc-a');
      final domain = _DomainHarness();
      final drivers = <_FakeSyncDriver>[];
      final scope = buildScope(
        domain: domain,
        drivers: drivers,
        handler: (req) async => req.url.path == '/api/unit-members/capability'
            ? _json({'can_review_members': false})
            : _json({}),
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      scope.incidentStore.setCurrentIncident(
        Incident.fromJson(_incJson('inc-a', '示例仓库火警')),
        forces: const [
          IncidentForce(
            id: 'f-a', incidentId: 'inc-a', stationName: '示例一站',
            vehicleCount: 2, personnelCount: 10, createdAt: 1000, updatedAt: 1000, version: 1,
          ),
        ],
      );
      domain.entries = [_sampleEntry('e-a', '张三')];
      domain.notes = [
        Note(id: 'n-a', text: '警情A日志', category: NoteCategory.other, author: '张三', createdAt: 1000, updatedAt: 1000),
      ];

      final genBefore = scope.sessionOrchestrator.sessionGeneration;
      final incB = Incident.fromJson(_incJson('inc-b', '示例厂房火警'));
      await scope.incidentOrchestrator.selectIncident('inc-b', knownIncident: incB);
      await scope.incidentOrchestrator.realtimeStartFuture;

      expect(scope.sessionOrchestrator.sessionGeneration, genBefore + 1);
      expect(scope.incidentStore.currentIncident?.id, 'inc-b');
      expect(scope.incidentStore.forces, isEmpty);
      expect(domain.entries, isEmpty);
      expect(domain.notes, isEmpty);
      expect(domain.clearCount, greaterThanOrEqualTo(1));
      expect(domain.clearNotifCount, greaterThanOrEqualTo(1));
      expect(await Settings.currentIncidentId, 'inc-b');
      expect(drivers.last.startedIncidentId, 'inc-b');
    });

    test('createIncident 与 claimExternalIncident 原子切场并置顶活跃列表', () async {
      seedAuth(incidentId: '');
      final domain = _DomainHarness();
      final scope = buildScope(
        domain: domain,
        handler: (req) async {
          if (req.url.path == '/api/incidents' && req.method == 'POST') {
            return _json(_incJson('inc-new', '新建警情'), status: 201);
          }
          if (req.url.path == '/api/incidents/claim-external' && req.method == 'POST') {
            return _json(_incJson('inc-ext', '认领警情'), status: 201);
          }
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      final created = await scope.incidentOrchestrator.createIncident();
      expect(created.id, 'inc-new');
      expect(scope.incidentStore.currentIncident?.id, 'inc-new');
      expect(await Settings.currentIncidentId, 'inc-new');

      domain.entries = [_sampleEntry('e-old', '李四')];
      final claimed = await scope.incidentOrchestrator.claimExternalIncident(
        ExternalIncident(
          externalId: 'ext-1', incidentNumber: 'EXT-2026-001',
          crimeAddress: '示例路1号', registerTime: baseNow,
        ),
      );
      expect(claimed.id, 'inc-ext');
      expect(scope.incidentStore.currentIncident?.id, 'inc-ext');
      expect(scope.incidentStore.activeIncidents.first.id, 'inc-ext');
      expect(domain.entries, isEmpty);
      expect(await Settings.currentIncidentId, 'inc-ext');
    });

    test('archiveCurrent 与 exitCurrentIncident 原子清理现场数据并进入无警情态', () async {
      seedAuth(incidentId: 'inc-1');
      final domain = _DomainHarness();
      var archiveCalls = 0;
      final scope = buildScope(
        domain: domain,
        handler: (req) async {
          if (req.url.path == '/api/incidents/inc-1/archive' && req.method == 'POST') {
            archiveCalls++;
            return _json(_incJson('inc-1', '已归档警情', status: 'archived'));
          }
          if (req.url.path == '/api/unit-members/capability') {
            return _json({'can_review_members': false});
          }
          return _json({});
        },
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      final inc1 = Incident.fromJson(_incJson('inc-1', '警情一'));
      final inc2 = Incident.fromJson(_incJson('inc-2', '警情二'));
      scope.incidentStore.setActiveIncidents([inc1, inc2]);
      scope.incidentStore.setCurrentIncident(inc1);
      domain.entries = [_sampleEntry('e-1', '张三')];

      await scope.incidentOrchestrator.archiveCurrent();
      expect(archiveCalls, 1);
      expect(scope.incidentStore.currentIncident, isNull);
      expect(scope.incidentStore.activeIncidents.map((i) => i.id), ['inc-2']);
      expect(scope.sessionStore.enteredWithoutIncident, isTrue);
      expect(scope.sessionStore.hasCurrentIncident, isFalse);
      expect(domain.entries, isEmpty);
      expect(await Settings.currentIncidentId, isEmpty);

      await scope.incidentOrchestrator.selectIncident('inc-2', knownIncident: inc2);
      await scope.incidentOrchestrator.exitCurrentIncident();
      expect(archiveCalls, 1);
      expect(scope.incidentStore.currentIncident, isNull);
      expect(scope.incidentStore.activeIncidents.map((i) => i.id), ['inc-2']);
      expect(scope.sessionStore.enteredWithoutIncident, isTrue);
      expect(await Settings.currentIncidentId, isEmpty);
    });
  });

  group('IncidentOrchestrator 快照/事件分发、刷新与离线投影', () {
    test('applySyncSnapshot 与 applySyncEvent 跨 Store 精准分发', () async {
      seedAuth(incidentId: 'inc-live');
      final domain = _DomainHarness();
      final scope = buildScope(
        domain: domain,
        handler: (req) async => req.url.path == '/api/unit-members/capability'
            ? _json({'can_review_members': false})
            : _json({}),
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      scope.incidentOrchestrator.applySyncSnapshot({
        'unit': {'id': 'u-1'},
        'roster': {
          'firefighters': [{'id': 'ff-1', 'name': '张三'}],
          'hotwords': [{'id': 'hw-1', 'word': '排烟'}],
        },
        'stations': [{'id': 'st-1', 'name': '示例路站'}],
        'active_incidents': [_incJson('inc-live', '示例火警')],
        'incident_snapshot': {
          'incident': _incJson('inc-live', '示例火警'),
          'entries': [
            {
              'id': 'e-1', 'name': '张三', 'pressure_mpa': 28,
              'duration_min': 22, 'entry_at': 1000, 'exit_at': 1321000, 'source': 'voice',
            },
          ],
          'notes': [
            {
              'id': 'n-1', 'text': '现场已出水', 'category': 'tactics',
              'author': '张三', 'created_at': 1500, 'updated_at': 1500,
            },
          ],
          'forces': [
            {
              'id': 'fc-1', 'incident_id': 'inc-live', 'station_name': '示例路站',
              'vehicle_count': 3, 'personnel_count': 15, 'updated_at': 1600,
            },
          ],
        },
      });

      expect(scope.syncStore.syncSnapshotApplied, isTrue);
      expect(scope.rosterStore.firefighters.map((f) => f.name), ['张三']);
      expect(scope.incidentStore.currentIncident?.id, 'inc-live');
      expect(scope.incidentStore.forces, hasLength(1));
      expect(domain.entries.map((e) => e.id), ['e-1']);
      expect(domain.notes.map((n) => n.id), ['n-1']);
      expect(domain.lastActiveCount, 1);
      expect(domain.lastEarliestExit, 1321000);
      expect(domain.rescheduleCount, greaterThanOrEqualTo(1));

      scope.incidentOrchestrator.applySyncEvent(
        const SyncEvent(
          stream: 'incident', sequence: '1', eventId: 'ev-1',
          eventType: 'entry.created', occurredAt: 2000,
          payload: {
            'id': 'e-2', 'name': '李四', 'pressure_mpa': 30,
            'duration_min': 25, 'entry_at': 2000, 'exit_at': 1502000, 'source': 'voice',
          },
        ),
      );
      expect(domain.entries.map((e) => e.id), containsAll(['e-1', 'e-2']));

      scope.incidentOrchestrator.applySyncEvent(
        const SyncEvent(
          stream: 'incident', sequence: '2', eventId: 'ev-2',
          eventType: 'note.deleted', aggregateId: 'n-1', occurredAt: 2100, payload: {},
        ),
      );
      expect(domain.notes, isEmpty);

      scope.incidentOrchestrator.applySyncEvent(
        SyncEvent(
          stream: 'unit', sequence: '3', eventId: 'ev-3',
          eventType: 'incident.archived', occurredAt: 2200,
          payload: _incJson('inc-live', '示例火警', status: 'archived'),
        ),
      );
      expect(scope.incidentStore.currentIncident, isNull);
      expect(scope.incidentStore.forces, isEmpty);
      expect(domain.entries, isEmpty);
      expect(scope.sessionStore.hasCurrentIncident, isFalse);
    });

    test('refreshNow 强刷检查点、过期 bootstrap 清理与 401 连接错误吊销', () async {
      seedAuth(incidentId: 'inc-live');
      final domain = _DomainHarness();
      final drivers = <_FakeSyncDriver>[];
      final scope = buildScope(
        domain: domain,
        drivers: drivers,
        handler: (req) async => req.url.path == '/api/unit-members/capability'
            ? _json({'can_review_members': false})
            : _json({}),
      );
      addTearDown(scope.dispose);

      await scope.sessionOrchestrator.init();
      await scope.incidentOrchestrator.realtimeStartFuture;
      scope.incidentOrchestrator.handleSyncState(SyncConnectionState.connected, null);
      expect(scope.syncStore.isSyncConnected, isTrue);

      await scope.incidentOrchestrator.refreshNow();
      expect(drivers.first.checkpointCalls, 1);
      expect(drivers.first.lastForceCheckpoint, isTrue);
      expect(scope.syncStore.manualRefreshInFlight, isFalse);

      scope.incidentStore.setCurrentIncident(Incident.fromJson(_incJson('inc-live', '示例火警')));
      domain.entries = [_sampleEntry('e-stale', '张三')];
      scope.incidentOrchestrator.handleStaleBootstrapIncident('inc-live');
      expect(scope.incidentStore.currentIncident, isNull);
      expect(domain.entries, isEmpty);
      expect(await Settings.currentIncidentId, isEmpty);

      scope.incidentOrchestrator.handleSyncState(
        SyncConnectionState.error,
        ApiException('会话已吊销', statusCode: 401, code: 'SESSION_INVALID'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(scope.sessionStore.authenticated, isFalse);
      expect(scope.sessionStore.protectedDataRevoked, isTrue);
    });

    test('兜底 HTTP sync 叠加本地离线投影并在 INCIDENT_NOT_FOUND 时原子清空', () async {
      seedAuth(incidentId: 'inc-off');
      final domain = _DomainHarness();
      var returnNotFound = false;
      final scope = buildScope(
        domain: domain,
        enableDriver: false,
        drainer: (config, allowedIds) async => 2,
        pendingRows: (incidentId) async => [
          {
            'type': 'entry',
            'occurred_at': baseNow,
            'payload': jsonEncode({'entry_id': 'offline-e-1', 'name': '王五', 'pressure_mpa': 24}),
          },
          {
            'type': 'note',
            'occurred_at': baseNow + 1000,
            'payload': jsonEncode({'note_id': 'offline-n-1', 'text': '离线补传测试日志', 'category': NoteCategory.other}),
          },
        ],
        handler: (req) async {
          if (req.url.path == '/api/incidents') return _json([_incJson('inc-off', '弱网火警')]);
          if (req.url.path == '/api/incidents/inc-off') {
            return returnNotFound
                ? _json({'error': '警情不存在', 'code': 'INCIDENT_NOT_FOUND'}, status: 404)
                : _json(_incJson('inc-off', '弱网火警'));
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

      await scope.sessionOrchestrator.init();
      await scope.incidentOrchestrator.sync();
      expect(scope.sessionStore.offlineReviewCount, 2);
      expect(scope.incidentStore.currentIncident?.id, 'inc-off');
      expect(domain.entries.map((e) => e.id), ['offline-e-1']);
      expect(domain.entries.first.name, '王五');
      expect(domain.notes.map((n) => n.id), ['offline-n-1']);

      returnNotFound = true;
      await scope.incidentOrchestrator.sync();
      expect(scope.incidentStore.currentIncident, isNull);
      expect(domain.entries, isEmpty);
      expect(domain.notes, isEmpty);
      expect(domain.stopKeepAlive, greaterThanOrEqualTo(1));
      expect(await Settings.currentIncidentId, isEmpty);
    });
  });
}
