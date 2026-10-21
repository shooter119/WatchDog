import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/services/offline_queue.dart';

class _Uploader extends ApiClient {
  final List<Map<String, dynamic>> received;
  _Uploader(this.received)
    : super(baseUrl: 'http://localhost', incidentId: 'incident');
  @override
  Future<Map<String, dynamic>> uploadOfflineOperations(
    List<Map<String, dynamic>> operations,
  ) async {
    received.addAll(operations);
    return {
      'results': [
        for (final op in operations)
          {
            'client_op_id': op['client_op_id'],
            'accepted': op['type'] == 'note',
            if (op['type'] != 'note') ...{
              'code': 'VERSION_CONFLICT',
              'error': '记录已改变',
              'current': {'pressure_mpa': 16},
            },
          },
      ],
    };
  }
}

void owner(String member) => SharedPreferences.setMockInitialValues({
  'unit_id': 'unit',
  'auth_member_id': member,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late String path;
  late OfflineQueue queue;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('watchdog-queue-test-');
    path = '${dir.path}/queue.db';
    queue = OfflineQueue.forDatabase(factory: databaseFactoryFfi, path: path);
    owner('member-a');
  });
  tearDown(() async {
    await queue.close();
    await dir.delete(recursive: true);
  });

  test('实际SQLite按成员隔离队列，同一人员连续操作保存前序依赖', () async {
    await queue.enqueue(
      incidentId: 'incident',
      type: 'entry',
      occurredAt: 1,
      clientOpId: 'entry-op',
      payload: {'entry_id': 'entry', 'name': '队员', 'pressure_mpa': 25},
    );
    await queue.enqueue(
      incidentId: 'incident',
      type: 'pressure',
      occurredAt: 2,
      clientOpId: 'pressure-op',
      payload: {'entry_id': 'entry', 'expected_version': 1, 'pressure_mpa': 20},
    );
    final rows = await queue.pendingOperations('incident');
    expect(rows, hasLength(2));
    expect(
      jsonDecode(rows.last['payload'] as String)['predecessor_op_id'],
      'entry-op',
    );
    owner('member-b');
    expect(await queue.pendingOperations('incident'), isEmpty);
    final received = <Map<String, dynamic>>[];
    await queue.drain((_) => _Uploader(received));
    expect(received, isEmpty);
    owner('member-a');
    expect(await queue.pendingOperations('incident'), hasLength(2));
  });

  test('冲突进入持久待核对，独立日志成功；原始记录、重试请求与处理审计跨重启保留', () async {
    await queue.enqueue(
      incidentId: 'incident',
      type: 'pressure',
      occurredAt: 1,
      clientOpId: 'pressure-op',
      payload: {'entry_id': 'entry', 'expected_version': 1, 'pressure_mpa': 20},
    );
    await queue.enqueue(
      incidentId: 'incident',
      type: 'note',
      occurredAt: 2,
      clientOpId: 'note-op',
      payload: {'text': '现场记录'},
    );
    final received = <Map<String, dynamic>>[];
    await queue.drain((_) => _Uploader(received));
    expect(received.every((op) => op['owner_member_id'] == 'member-a'), isTrue);
    expect(await queue.pendingOperations('incident'), isEmpty);
    expect(await queue.reviewOperations(), hasLength(1));
    final request = {
      'op_id': 'stable-retry-id',
      'version': 2,
      'type': 'pressure',
      'payload': {'pressure_mpa': 15},
    };
    await queue.prepareReview('pressure-op', request);
    await queue.close();
    queue = OfflineQueue.forDatabase(factory: databaseFactoryFfi, path: path);
    final review = (await queue.reviewOperations()).single;
    expect(jsonDecode(review['retry_request'] as String), request);
    expect(jsonDecode(review['payload'] as String)['pressure_mpa'], 20);
    owner('member-b');
    await queue.resolveReview('pressure-op', 'wrong-owner');
    owner('member-a');
    expect(await queue.reviewOperations(), hasLength(1));
    await queue.resolveReview('pressure-op', 'manually-confirmed');
    await queue.close();
    final db = await databaseFactoryFfi.openDatabase(path);
    final stored = await db.query('offline_operations', orderBy: 'id');
    expect(stored, hasLength(2));
    expect(stored.first['resolution'], 'manually-confirmed');
    expect(stored.last['resolution'], 'uploaded');
    await db.close();
  });

  test('v2迁移保留旧原文；无归属记录只有人工认领后才进入本人待核对', () async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE offline_operations(id INTEGER PRIMARY KEY AUTOINCREMENT, incident_id TEXT NOT NULL, type TEXT NOT NULL, occurred_at INTEGER NOT NULL, client_op_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, created_at INTEGER NOT NULL)',
          );
        },
      ),
    );
    await db.insert('offline_operations', {
      'incident_id': 'incident',
      'type': 'pressure',
      'occurred_at': 1,
      'client_op_id': 'legacy',
      'payload': '{"entry_id":"entry","pressure_mpa":24}',
      'created_at': 1,
    });
    await db.close();
    expect(await queue.pendingOperations('incident'), isEmpty);
    expect(await queue.reviewOperations(), isEmpty);
    final legacy = (await queue.legacyOperations()).single;
    expect(legacy['payload'], '{"entry_id":"entry","pressure_mpa":24}');
    await queue.claimLegacy('legacy');
    expect(await queue.legacyOperations(), isEmpty);
    expect(await queue.reviewOperations(), hasLength(1));
    expect(await queue.pendingOperations('incident'), isEmpty);
  });
}
