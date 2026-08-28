import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/state/app_controller.dart';

class _OfflinePressureApi extends ApiClient {
  _OfflinePressureApi({required this.incident})
    : super(baseUrl: 'http://offline', incidentId: incident.id);

  final Incident incident;
  final fetchEntriesStarted = Completer<void>();
  final fetchEntriesGate = Completer<List<Entry>>();
  bool updateAttempted = false;

  @override
  Future<Entry> updateEntry({
    required String id,
    String? name,
    double? pressureMpa,
    double? consumptionLpm,
    String? opId,
  }) async {
    updateAttempted = true;
    throw TimeoutException('simulated offline');
  }

  @override
  Future<List<Incident>> fetchIncidents({String? status}) async => [incident];

  @override
  Future<Incident> fetchIncident(String id) async => incident;

  @override
  Future<List<Entry>> fetchEntries({bool activeOnly = false}) async {
    if (!fetchEntriesStarted.isCompleted) fetchEntriesStarted.complete();
    return fetchEntriesGate.future;
  }

  @override
  Future<List<Note>> fetchNotes() async => [];

  @override
  Future<List<IncidentForce>> fetchIncidentForces({
    String? forIncidentId,
  }) async => [];
}

class _MissingIncidentApi extends ApiClient {
  _MissingIncidentApi()
    : super(
        baseUrl: 'http://offline',
        incidentId: 'stale-incident',
        apiToken: 'token',
        unitId: 'unit-a',
        unitCode: '1234',
      );

  @override
  Future<List<Incident>> fetchIncidents({String? status}) async => [];

  @override
  Future<Incident> fetchIncident(String id) async => throw ApiException(
    '警情不存在或当前单位无权访问',
    statusCode: 404,
    code: 'INCIDENT_NOT_FOUND',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('当前单位无法访问已保存警情时清理旧快照', (tester) async {
    const incidentId = 'stale-incident';
    final incident = Incident(
      id: incidentId,
      number: '20260828-001',
      status: 'active',
      createdAt: 1700000000000,
      lastActivityAt: 1700000000000,
    );
    final controller = AppController(offlineQueueDrainer: () async {})
      ..api = _MissingIncidentApi()
      ..currentIncident = incident
      ..entries = [
        Entry(
          id: 'entry-stale',
          name: '旧单位人员',
          durationMin: 10,
          entryAt: 1700000000000,
          exitAt: 1700000600000,
          source: 'voice',
        ),
      ]
      ..notes = [
        Note(
          id: 'note-stale',
          text: '旧单位记录',
          category: NoteCategory.other,
          createdAt: 1700000000000,
          updatedAt: 1700000000000,
        ),
      ]
      ..forces = [
        IncidentForce(
          id: 'force-stale',
          incidentId: incidentId,
          stationName: '旧单位站点',
          vehicleCount: 1,
          personnelCount: 2,
          createdAt: 1700000000000,
          updatedAt: 1700000000000,
          version: 1,
        ),
      ];
    SharedPreferences.setMockInitialValues({'current_incident_id': incidentId});
    addTearDown(controller.dispose);

    await controller.sync();

    expect(controller.currentIncident, isNull);
    expect(controller.entries, isEmpty);
    expect(controller.notes, isEmpty);
    expect(controller.forces, isEmpty);
    expect(controller.syncError, isNull);
    expect(await Settings.currentIncidentId, isEmpty);
  });

  testWidgets('离线压力复核入队后立即投影记录级参数和新倒计时', (tester) async {
    const incidentId = 'incident-offline-pressure';
    const entryAt = 1700000000000;
    final incident = Incident(
      id: incidentId,
      number: '20260827-001',
      status: 'active',
      createdAt: entryAt,
      lastActivityAt: entryAt,
    );
    final entry = Entry(
      id: 'entry-offline-pressure',
      name: '张伟',
      pressureMpa: 20,
      durationMin: 20,
      entryAt: entryAt,
      exitAt: entryAt + 20 * 60000,
      source: 'voice',
      rawText: '张伟，20兆帕',
      cylinderVolL: 9,
      consumptionLpm: 80,
      consumptionActualLpm: 72,
    );
    final api = _OfflinePressureApi(incident: incident);
    final enqueued = <Map<String, dynamic>>[];
    final controller =
        AppController(
            offlineOperationEnqueuer:
                ({
                  required String incidentId,
                  required String type,
                  required int occurredAt,
                  required String clientOpId,
                  required Map<String, dynamic> payload,
                }) async {
                  enqueued.add({
                    'incidentId': incidentId,
                    'type': type,
                    'occurredAt': occurredAt,
                    'clientOpId': clientOpId,
                    'payload': payload,
                  });
                },
            offlineQueueDrainer: () async {},
          )
          ..api = api
          ..currentIncident = incident
          ..entries = [entry]
          ..calcConfig = CalcConfig(
            cylinderVolL: 6.8,
            fullPressureMpa: 30,
            consumptionLpm: 90,
            warnMin: 10,
            alarmMin: 5,
          );
    SharedPreferences.setMockInitialValues({'current_incident_id': incidentId});
    addTearDown(controller.dispose);

    final update = controller.updatePressure(
      id: entry.id,
      pressureMpa: 10,
      opId: 'offline-pressure-regression',
    );

    await api.fetchEntriesStarted.future;
    expect(api.updateAttempted, isTrue);
    expect(enqueued, hasLength(1));
    expect(enqueued.single['type'], 'pressure');
    expect(enqueued.single['clientOpId'], 'offline-pressure-regression');
    expect(enqueued.single['payload'], {
      'entry_id': entry.id,
      'pressure_mpa': 10,
      'volume_l': 9,
      'consumption_lpm': 80,
    });
    expect(controller.entries, hasLength(1));
    final projected = controller.entries.single;
    expect(projected.pressureMpa, 10);
    expect(projected.cylinderVolL, 9);
    expect(projected.consumptionLpm, 80);
    expect(projected.consumptionActualLpm, 72);
    expect(projected.durationMin, 11);
    expect(projected.exitAt, greaterThan(entry.exitAt));
    expect(
      projected.exitAt,
      greaterThanOrEqualTo(DateTime.now().millisecondsSinceEpoch + 10 * 60000),
    );

    api.fetchEntriesGate.complete([projected]);
    final returned = await update;
    expect(returned.pressureMpa, 10);
    expect(returned.durationMin, 11);
    expect(returned.cylinderVolL, 9);
    expect(returned.consumptionLpm, 80);
  });

  test('服务端旧快照同步后重新叠加待补传操作', () {
    final oldEntry = Entry(
      id: 'entry-1',
      name: '张伟',
      pressureMpa: 20,
      durationMin: 20,
      entryAt: 1700000000000,
      exitAt: 1700001200000,
      source: 'voice',
      rawText: '张伟，20兆帕',
      cylinderVolL: 9,
      consumptionLpm: 80,
    );
    final projected = AppController.applyOfflineOperationProjection(
      rows: [
        {
          'id': 1,
          'incident_id': 'incident-1',
          'type': 'pressure',
          'occurred_at': 1700000100000,
          'client_op_id': 'op-pressure',
          'payload': jsonEncode({
            'entry_id': 'entry-1',
            'pressure_mpa': 10,
            'volume_l': 9,
            'consumption_lpm': 80,
          }),
          'created_at': 1700000100000,
        },
        {
          'id': 2,
          'incident_id': 'incident-1',
          'type': 'exit',
          'occurred_at': 1700000200000,
          'client_op_id': 'op-exit',
          'payload': jsonEncode({'entry_id': 'entry-1'}),
          'created_at': 1700000200000,
        },
        {
          'id': 3,
          'incident_id': 'incident-1',
          'type': 'note',
          'occurred_at': 1700000300000,
          'client_op_id': 'op-note',
          'payload': jsonEncode({
            'note_id': 'note-1',
            'text': '已完成现场确认',
            'category': '现场动态',
          }),
          'created_at': 1700000300000,
        },
      ],
      entries: [oldEntry],
      notes: const [],
      calcConfig: CalcConfig(
        cylinderVolL: 6.8,
        fullPressureMpa: 30,
        consumptionLpm: 80,
        warnMin: 10,
        alarmMin: 5,
      ),
      author: '李娜',
    );

    expect(projected.$1.single.pressureMpa, 10);
    expect(projected.$1.single.durationMin, 11);
    expect(projected.$1.single.exitedAt, 1700000200000);
    expect(projected.$2.single.text, '已完成现场确认');
    expect(projected.$2.single.author, '李娜');
  });
}
