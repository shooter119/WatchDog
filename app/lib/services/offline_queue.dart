import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../api/api_client.dart';

class OfflineQueue {
  OfflineQueue._();
  static final OfflineQueue instance = OfflineQueue._();
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(
      p.join(dir.path, 'watchdog_offline.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE offline_operations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          incident_id TEXT NOT NULL,
          type TEXT NOT NULL,
          occurred_at INTEGER NOT NULL,
          client_op_id TEXT NOT NULL UNIQUE,
          payload TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      '''),
    );
    return _db!;
  }

  Future<void> enqueue({required String incidentId, required String type, required int occurredAt, required String clientOpId, required Map<String, dynamic> payload}) async {
    final db = await _database;
    await db.insert('offline_operations', {
      'incident_id': incidentId,
      'type': type,
      'occurred_at': occurredAt,
      'client_op_id': clientOpId,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<int> pendingCount() async => (await _database).rawQuery('SELECT COUNT(*) AS count FROM offline_operations').then((rows) => (rows.first['count'] as int?) ?? 0);

  Future<void> drain(ApiClient Function(String incidentId) clientForIncident) async {
    final db = await _database;
    final rows = await db.query('offline_operations', orderBy: 'id ASC');
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      grouped.putIfAbsent(row['incident_id'] as String, () => []).add({
        'type': row['type'],
        'occurred_at': row['occurred_at'],
        'client_op_id': row['client_op_id'],
        'payload': payload,
      });
    }
    for (final entry in grouped.entries) {
      try {
        final response = await clientForIncident(entry.key).uploadOfflineOperations(entry.value);
        final results = response['results'] as List? ?? const [];
        final resultByOp = {for (final r in results) (r as Map)['client_op_id']?.toString(): r};
        for (final op in entry.value) {
          final result = resultByOp[op['client_op_id']];
          if (result != null && (result['accepted'] == true || result['code'] == 'OFFLINE_WINDOW_EXPIRED')) {
            await db.delete('offline_operations', where: 'client_op_id = ?', whereArgs: [op['client_op_id']]);
          }
        }
      } catch (_) {
        // 网络仍不可用：保留队列，下一次同步继续按发生顺序补传。
      }
    }
  }
}
