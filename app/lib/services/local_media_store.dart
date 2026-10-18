import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'local_asr_service.dart';

/// 本机媒体记录：照片与录像只存在设备上，服务端不保存任何媒体文件。
///
/// 表里保存的是「拍摄那一刻冻结的水印值」与「离线转写结果」，
/// 因此即使视频被用户删除，口述文字仍可留着作为现场记录。
class LocalMedia {
  final String id;
  final String incidentId;
  final String kind; // photo | video
  final String path;
  final int durationMs;
  final int capturedAt;
  final double? lat;
  final double? lon;
  final String address;
  final String weather;
  final String transcript;
  final List<LocalAsrSegment> segments;
  final List<String> frames;
  final String observationId;

  const LocalMedia({
    required this.id,
    required this.incidentId,
    required this.kind,
    required this.path,
    required this.durationMs,
    required this.capturedAt,
    required this.lat,
    required this.lon,
    required this.address,
    required this.weather,
    required this.transcript,
    required this.segments,
    required this.frames,
    required this.observationId,
  });

  bool get isVideo => kind == 'video';
  bool get hasTranscript => transcript.trim().isNotEmpty;

  factory LocalMedia.fromRow(Map<String, Object?> row) {
    final segmentsRaw = row['segments'] as String?;
    final framesRaw = row['frames'] as String?;
    return LocalMedia(
      id: row['id'] as String,
      incidentId: (row['incident_id'] as String?) ?? '',
      kind: (row['kind'] as String?) ?? 'photo',
      path: (row['path'] as String?) ?? '',
      durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
      capturedAt: (row['captured_at'] as num?)?.toInt() ?? 0,
      lat: (row['lat'] as num?)?.toDouble(),
      lon: (row['lon'] as num?)?.toDouble(),
      address: (row['address'] as String?) ?? '',
      weather: (row['weather'] as String?) ?? '',
      transcript: (row['transcript'] as String?) ?? '',
      segments: _decodeSegments(segmentsRaw),
      frames: _decodeFrames(framesRaw),
      observationId: (row['observation_id'] as String?) ?? '',
    );
  }

  static List<LocalAsrSegment> _decodeSegments(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(LocalAsrSegment.fromJson)
          .whereType<LocalAsrSegment>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static List<String> _decodeFrames(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

/// 本机媒体库。默认保留 30 天，超期记录与文件一并清理。
class LocalMediaStore {
  LocalMediaStore._();

  /// 仅供测试构造子类替换实现；业务代码始终通过 [instance] 访问。
  @visibleForTesting
  LocalMediaStore.forTesting();

  static final LocalMediaStore _defaultInstance = LocalMediaStore._();

  /// 测试钩子：置为非 null 时 [instance] 返回该实现，测试结束需恢复为 null。
  @visibleForTesting
  static LocalMediaStore? overrideInstance;

  static LocalMediaStore get instance => overrideInstance ?? _defaultInstance;

  static const int retentionDays = 30;
  Database? _db;

  static String newId() {
    final random = Random();
    final suffix = List.generate(6, (_) => random.nextInt(36).toRadixString(36)).join();
    return 'media_${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(
      p.join(dir.path, 'watchdog_media.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE local_media (
            id TEXT PRIMARY KEY,
            incident_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            path TEXT NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            captured_at INTEGER NOT NULL,
            lat REAL,
            lon REAL,
            address TEXT NOT NULL DEFAULT '',
            weather TEXT NOT NULL DEFAULT '',
            transcript TEXT NOT NULL DEFAULT '',
            segments TEXT NOT NULL DEFAULT '[]',
            frames TEXT NOT NULL DEFAULT '[]',
            observation_id TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_local_media_incident ON local_media(incident_id, captured_at DESC)',
        );
      },
    );
    return _db!;
  }

  Future<void> insert(LocalMedia media) async {
    final db = await _database;
    await db.insert(
      'local_media',
      {
        'id': media.id,
        'incident_id': media.incidentId,
        'kind': media.kind,
        'path': media.path,
        'duration_ms': media.durationMs,
        'captured_at': media.capturedAt,
        'lat': media.lat,
        'lon': media.lon,
        'address': media.address,
        'weather': media.weather,
        'transcript': media.transcript,
        'segments': jsonEncode(
          media.segments.map((s) => s.toJson()).toList(growable: false),
        ),
        'frames': jsonEncode(media.frames),
        'observation_id': media.observationId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Set<String>> allPaths() async {
    final db = await _database;
    final rows = await db.query('local_media', columns: ['path']);
    return rows
        .map((row) => (row['path'] as String?) ?? '')
        .where((path) => path.isNotEmpty)
        .toSet();
  }

  /// 未关联警情的媒体：没有当前警情时拍摄的文件，避免它们在资料页里消失。
  Future<List<LocalMedia>> listUnlinked() async {
    final db = await _database;
    final rows = await db.query(
      'local_media',
      where: "incident_id = ''",
      orderBy: 'captured_at DESC',
    );
    return rows.map(LocalMedia.fromRow).toList(growable: false);
  }

  Future<void> attachToIncident(String id, String incidentId) async {
    final db = await _database;
    await db.update(
      'local_media',
      {'incident_id': incidentId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> insertRecovered(LocalMedia media) async {
    final db = await _database;
    // 同路径已存在时不重复登记
    final existing = await db.query(
      'local_media',
      columns: ['id'],
      where: 'path = ?',
      whereArgs: [media.path],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await insert(media);
  }

  Future<List<LocalMedia>> listForIncident(String incidentId) async {
    final db = await _database;
    final rows = await db.query(
      'local_media',
      where: 'incident_id = ?',
      whereArgs: [incidentId],
      orderBy: 'captured_at DESC',
    );
    return rows.map(LocalMedia.fromRow).toList(growable: false);
  }

  Future<LocalMedia?> byId(String id) async {
    final db = await _database;
    final rows = await db.query('local_media', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return LocalMedia.fromRow(rows.first);
  }

  Future<void> updateDerived({
    required String id,
    String? transcript,
    List<LocalAsrSegment>? segments,
    List<String>? frames,
    String? observationId,
  }) async {
    final db = await _database;
    final values = <String, Object?>{};
    if (transcript != null) values['transcript'] = transcript;
    if (segments != null) {
      values['segments'] = jsonEncode(
        segments.map((s) => s.toJson()).toList(growable: false),
      );
    }
    if (frames != null) values['frames'] = jsonEncode(frames);
    if (observationId != null) values['observation_id'] = observationId;
    if (values.isEmpty) return;
    await db.update('local_media', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteById(String id) async {
    final db = await _database;
    await db.delete('local_media', where: 'id = ?', whereArgs: [id]);
  }

  /// 清理超期记录；文件删除失败时仍移除记录，避免数据库无限增长。
  Future<List<String>> purgeExpired({
    int days = retentionDays,
    DateTime? now,
  }) async {
    final db = await _database;
    final cutoff = (now ?? DateTime.now())
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    final rows = await db.query(
      'local_media',
      columns: ['path', 'frames'],
      where: 'captured_at < ?',
      whereArgs: [cutoff],
    );
    final removed = <String>[];
    for (final row in rows) {
      removed.add((row['path'] as String?) ?? '');
      final frames = LocalMedia._decodeFrames(row['frames'] as String?);
      removed.addAll(frames);
    }
    await db.delete('local_media', where: 'captured_at < ?', whereArgs: [cutoff]);
    return removed.where((path) => path.isNotEmpty).toList(growable: false);
  }
}
