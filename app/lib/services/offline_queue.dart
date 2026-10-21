import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../api/api_client.dart';
import 'settings.dart';

const _offlineOperationsTable = 'offline_operations';
const _offlineQuarantineTable = 'offline_operations_quarantine';

const _offlineQuarantineTableSql = '''
  CREATE TABLE IF NOT EXISTS offline_operations_quarantine (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    original_id INTEGER NOT NULL UNIQUE,
    incident_id TEXT NOT NULL,
    type TEXT NOT NULL,
    occurred_at INTEGER NOT NULL,
    client_op_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    error TEXT NOT NULL,
    quarantined_at INTEGER NOT NULL
  )
''';

typedef OfflineOperationUploader =
    Future<Map<String, dynamic>> Function(
      String incidentId,
      List<Map<String, dynamic>> operations,
    );

typedef OfflineOperationQuarantiner =
    Future<void> Function(Map<String, Object?> row, Object error);

typedef OfflineOperationRemover = Future<void> Function(String clientOpId);

/// 处理从本地队列读出的行。
///
/// 将 payload 解码放在每一行自己的保护范围内，避免一条损坏记录阻塞
/// 其他警情。隔离回调失败时不调用删除回调，原行会保留在活动队列表中，
/// 因而不会静默丢失原始数据。
Future<void> drainOfflineOperationRows(
  Iterable<Map<String, Object?>> rows, {
  required OfflineOperationUploader upload,
  required OfflineOperationQuarantiner quarantine,
  required OfflineOperationRemover removeAccepted,
  Set<String>? allowedIncidentIds,
  Future<void> Function(String, Map<String, dynamic>)? reject,
}) async {
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    try {
      final incidentId = row['incident_id'];
      if (incidentId is! String || incidentId.trim().isEmpty) {
        throw const FormatException('离线记录缺少警情 ID');
      }
      final rawPayload = row['payload'];
      if (rawPayload is! String) {
        throw const FormatException('离线记录 payload 不是文本');
      }
      final decoded = jsonDecode(rawPayload);
      if (decoded is! Map) {
        throw const FormatException('离线记录 payload 不是 JSON 对象');
      }
      final payload = Map<String, dynamic>.from(decoded);
      grouped.putIfAbsent(incidentId, () => []).add({
        'owner_member_id': row['owner_member_id'],
        'owner_unit_id': row['owner_unit_id'],
        'type': row['type'],
        'occurred_at': row['occurred_at'],
        'client_op_id': row['client_op_id'],
        'payload': payload,
      });
    } catch (error) {
      // 隔离失败时保持原行不动；合法分组仍继续处理。
      try {
        await quarantine(row, error);
      } catch (_) {}
    }
  }

  for (final entry in grouped.entries) {
    // 队列跨单位/警情长期保留以避免静默丢失；但切换单位后不能拿新身份
    // 尝试补传旧警情。调用方在当前认证上下文中提供允许的警情集合。
    if (allowedIncidentIds != null && !allowedIncidentIds.contains(entry.key)) {
      continue;
    }
    try {
      final batch = entry.value.take(100).toList();
      final response = await upload(entry.key, batch);
      final rawResults = response['results'];
      if (rawResults is! List) continue;
      final resultByOp = <String, Map<String, dynamic>>{};
      for (final rawResult in rawResults) {
        if (rawResult is! Map) continue;
        final opId = rawResult['client_op_id']?.toString();
        if (opId == null || opId.isEmpty) continue;
        resultByOp[opId] = Map<String, dynamic>.from(rawResult);
      }
      for (final op in batch) {
        final opId = op['client_op_id']?.toString();
        if (opId == null || opId.isEmpty) continue;
        final result = resultByOp[opId];
        if (result?['accepted'] == true) {
          await removeAccepted(opId);
        } else if (result != null &&
            result['code'] != 'OPERATION_IN_PROGRESS') {
          await reject?.call(opId, result);
        }
      }
    } catch (_) {
      // 网络仍不可用或服务端响应异常：保留该组，下一次同步继续补传。
    }
  }
}

class OfflineQueue {
  OfflineQueue._();
  OfflineQueue.forDatabase({
    required DatabaseFactory factory,
    required String path,
  }) : _factory = factory,
       _path = path;
  DatabaseFactory? _factory;
  String? _path;

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  static final OfflineQueue instance = OfflineQueue._();
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final location =
        _path ??
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'watchdog_offline.db',
        );
    _db = await (_factory ?? databaseFactory).openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
          CREATE TABLE offline_operations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            incident_id TEXT NOT NULL,
            type TEXT NOT NULL,
            occurred_at INTEGER NOT NULL,
            client_op_id TEXT NOT NULL UNIQUE,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
          await db.execute(_offlineQuarantineTableSql);
          await _upgradeOwnership(db);
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) {
            await db.execute(_offlineQuarantineTableSql);
          }
          if (oldVersion < 3) await _upgradeOwnership(db);
        },
      ),
    );
    return _db!;
  }

  static Future<void> _upgradeOwnership(Database db) async {
    await db.execute(
      "ALTER TABLE offline_operations ADD COLUMN owner_unit_id TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE offline_operations ADD COLUMN owner_member_id TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE offline_operations ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'",
    );
    await db.execute('ALTER TABLE offline_operations ADD COLUMN result TEXT');
    await db.execute(
      'ALTER TABLE offline_operations ADD COLUMN resolution TEXT',
    );
    await db.execute(
      'ALTER TABLE offline_operations ADD COLUMN retry_request TEXT',
    );
    await db.update(_offlineOperationsTable, {
      'status': 'review',
      'result': jsonEncode({'error': '旧记录缺少可靠成员归属，请原记录人核对'}),
    });
  }

  Future<void> enqueue({
    required String incidentId,
    required String type,
    required int occurredAt,
    required String clientOpId,
    required Map<String, dynamic> payload,
    Map<String, String>? owner,
  }) async {
    final db = await _database;
    final unitId = owner?['unit_id'] ?? await Settings.unitId;
    final memberId = owner?['member_id'] ?? await Settings.memberId;
    await db.transaction((txn) async {
      final data = Map<String, dynamic>.from(payload);
      final previous = await txn.query(
        _offlineOperationsTable,
        where:
            'incident_id=? AND owner_unit_id=? AND owner_member_id=? AND status<>?',
        whereArgs: [incidentId, unitId, memberId, 'resolved'],
        orderBy: 'id DESC',
      );
      for (final row in previous) {
        final old = jsonDecode(row['payload'] as String);
        if (data['entry_id'] != null && old['entry_id'] == data['entry_id']) {
          data['predecessor_op_id'] = row['client_op_id'];
          break;
        }
      }
      await txn.insert(_offlineOperationsTable, {
        'incident_id': incidentId,
        'type': type,
        'occurred_at': occurredAt,
        'client_op_id': clientOpId,
        'payload': jsonEncode(data),
        'owner_unit_id': unitId,
        'owner_member_id': memberId,
        'status': memberId.isEmpty || unitId.isEmpty ? 'review' : 'pending',
        'result': memberId.isEmpty || unitId.isEmpty
            ? jsonEncode({'error': '缺少成员身份，请重新认证后核对'})
            : null,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Future<int> pendingCount() async => (await _database)
      .rawQuery(
        "SELECT COUNT(*) AS count FROM $_offlineOperationsTable WHERE status='pending'",
      )
      .then((rows) => (rows.first['count'] as int?) ?? 0);

  /// 读取某一警情尚未补传的原始操作，供同步后重新叠加本地乐观状态。
  /// 返回顺序固定为入队顺序，调用方据此重放进场、压力复核和出场操作。
  Future<List<Map<String, Object?>>> pendingOperations(
    String incidentId,
  ) async => (await _database).query(
    _offlineOperationsTable,
    where:
        "incident_id=? AND owner_unit_id=? AND owner_member_id=? AND status='pending'",
    whereArgs: [incidentId, await Settings.unitId, await Settings.memberId],
    orderBy: 'id ASC',
  );

  Future<List<Map<String, Object?>>> reviewOperations() async =>
      (await _database).query(
        _offlineOperationsTable,
        where: "status='review' AND owner_unit_id=? AND owner_member_id=?",
        whereArgs: [await Settings.unitId, await Settings.memberId],
        orderBy: 'id ASC',
      );

  Future<List<Map<String, Object?>>> legacyOperations() async =>
      (await _database).query(
        _offlineOperationsTable,
        where: "status='review' AND (owner_unit_id='' OR owner_member_id='')",
        orderBy: 'id ASC',
      );

  Future<void> claimLegacy(String opId) async {
    final member = await Settings.memberId;
    final unit = await Settings.unitId;
    if (member.isEmpty || unit.isEmpty) throw StateError('请重新认证后核对');
    await (await _database).update(
      _offlineOperationsTable,
      {
        'owner_member_id': member,
        'owner_unit_id': unit,
        'resolution': 'original_actor_confirmed',
      },
      where:
          "client_op_id=? AND status='review' AND (owner_member_id='' OR owner_unit_id='')",
      whereArgs: [opId],
    );
  }

  Future<Map<String, dynamic>> prepareReview(
    String opId,
    Map<String, dynamic> request,
  ) async {
    final db = await _database;
    final unit = await Settings.unitId;
    final member = await Settings.memberId;
    return db.transaction((txn) async {
      final rows = await txn.query(
        _offlineOperationsTable,
        where:
            "client_op_id=? AND status='review' AND owner_unit_id=? AND owner_member_id=?",
        whereArgs: [opId, unit, member],
      );
      if (rows.isEmpty) throw StateError('记录身份或状态已改变，请刷新后核对');
      final existing = rows.single['retry_request'];
      if (existing is String) {
        return Map<String, dynamic>.from(jsonDecode(existing) as Map);
      }
      await txn.update(
        _offlineOperationsTable,
        {'retry_request': jsonEncode(request)},
        where: 'client_op_id=?',
        whereArgs: [opId],
      );
      return request;
    });
  }

  Future<void> clearReviewRequest(String opId) async {
    await (await _database).update(
      _offlineOperationsTable,
      {'retry_request': null},
      where: 'client_op_id=? AND owner_unit_id=? AND owner_member_id=?',
      whereArgs: [opId, await Settings.unitId, await Settings.memberId],
    );
  }

  Future<int> legacyReviewCount() async => (await _database)
      .rawQuery(
        "SELECT COUNT(*) AS count FROM offline_operations WHERE status='review' AND (owner_unit_id='' OR owner_member_id='')",
      )
      .then((rows) => (rows.first['count'] as int?) ?? 0);

  Future<void> resolveReview(String opId, String resolution) async {
    final db = await _database;
    await db.update(
      _offlineOperationsTable,
      {'status': 'resolved', 'resolution': resolution},
      where:
          "client_op_id=? AND owner_unit_id=? AND owner_member_id=? AND status='review'",
      whereArgs: [opId, await Settings.unitId, await Settings.memberId],
    );
  }

  /// 读取被隔离的原始记录，供诊断/人工恢复使用；不会返回到补传队列。
  Future<List<Map<String, Object?>>> quarantinedOperations() async =>
      (await _database).query(
        _offlineQuarantineTable,
        orderBy: 'quarantined_at ASC, id ASC',
      );

  Future<void> _quarantineRow(
    Database db,
    Map<String, Object?> row,
    Object error,
  ) async {
    final originalId = (row['id'] as num?)?.toInt();
    if (originalId == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rawError = error.toString();
    await db.transaction((txn) async {
      await txn.insert(_offlineQuarantineTable, {
        'original_id': originalId,
        'incident_id': row['incident_id']?.toString() ?? '',
        'type': row['type']?.toString() ?? '',
        'occurred_at': (row['occurred_at'] as num?)?.toInt() ?? 0,
        'client_op_id': row['client_op_id']?.toString() ?? '',
        // 保留损坏 payload 原文，不把它重新编码或静默丢弃。
        'payload': row['payload']?.toString() ?? '',
        'created_at': (row['created_at'] as num?)?.toInt() ?? 0,
        'error': rawError.length > 512 ? rawError.substring(0, 512) : rawError,
        'quarantined_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.delete(
        _offlineOperationsTable,
        where: 'id = ?',
        whereArgs: [originalId],
      );
    });
  }

  Future<void> drain(
    ApiClient Function(String incidentId) clientForIncident, {
    Set<String>? allowedIncidentIds,
  }) async {
    final db = await _database;
    final rows = await db.query(
      _offlineOperationsTable,
      where: "status='pending' AND owner_unit_id=? AND owner_member_id=?",
      whereArgs: [await Settings.unitId, await Settings.memberId],
      orderBy: 'id ASC',
    );
    await drainOfflineOperationRows(
      rows,
      allowedIncidentIds: allowedIncidentIds,
      upload: (incidentId, operations) async {
        final client = clientForIncident(incidentId);
        try {
          return await client.uploadOfflineOperations(operations);
        } finally {
          client.dispose();
        }
      },
      quarantine: (row, error) => _quarantineRow(db, row, error),
      reject: (opId, result) async {
        await db.update(
          _offlineOperationsTable,
          {'status': 'review', 'result': jsonEncode(result)},
          where: 'client_op_id=?',
          whereArgs: [opId],
        );
      },
      removeAccepted: (clientOpId) => db.update(
        _offlineOperationsTable,
        {'status': 'resolved', 'resolution': 'uploaded'},
        where: 'client_op_id = ?',
        whereArgs: [clientOpId],
      ),
    );
  }

  /// 新版数据纪元迁移：旧版本离线业务不能带着旧单位身份进入新协议。
  Future<void> clearAll() async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(_offlineOperationsTable);
      await txn.delete(_offlineQuarantineTable);
    });
  }
}
