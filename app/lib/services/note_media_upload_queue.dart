import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/network/api_exceptions.dart';
import '../features/notes/data/models/note.dart';
import '../features/notes/data/models/note_category.dart';
import '../features/notes/data/models/note_media.dart';

const String _queueTable = 'note_media_upload_tasks';

/// 水印相机媒体入队结果。
enum NoteMediaEnqueueOutcome {
  enqueued,
  skippedGuest,
  skippedNoIncident,
  failed,
}

/// 单条水印相机媒体后台上传任务记录。
@immutable
class NoteMediaUploadTask {
  const NoteMediaUploadTask({
    required this.id,
    required this.unitId,
    required this.memberId,
    required this.incidentId,
    required this.localMediaId,
    required this.kind,
    required this.filePath,
    required this.thumbPath,
    required this.text,
    required this.category,
    required this.author,
    required this.durationMs,
    required this.capturedAt,
    required this.address,
    required this.weather,
    required this.syncObservation,
    required this.status,
    required this.attempts,
    required this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String unitId;
  final String memberId;
  final String incidentId;
  final String localMediaId;
  final String kind;
  final String filePath;
  final String thumbPath;
  final String text;
  final String category;
  final String author;
  final int durationMs;
  final int capturedAt;
  final String address;
  final String weather;
  final bool syncObservation;
  final String status; // queued | uploading | failed
  final int attempts;
  final String lastError;
  final int createdAt;
  final int updatedAt;

  NoteMediaUploadStatus get uploadStatus => switch (status) {
    'uploading' => NoteMediaUploadStatus.uploading,
    'failed' => NoteMediaUploadStatus.failed,
    _ => NoteMediaUploadStatus.queued,
  };

  NoteMediaUploadTask copyWith({
    String? status,
    int? attempts,
    String? lastError,
    int? updatedAt,
  }) => NoteMediaUploadTask(
    id: id,
    unitId: unitId,
    memberId: memberId,
    incidentId: incidentId,
    localMediaId: localMediaId,
    kind: kind,
    filePath: filePath,
    thumbPath: thumbPath,
    text: text,
    category: category,
    author: author,
    durationMs: durationMs,
    capturedAt: capturedAt,
    address: address,
    weather: weather,
    syncObservation: syncObservation,
    status: status ?? this.status,
    attempts: attempts ?? this.attempts,
    lastError: lastError ?? this.lastError,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'unit_id': unitId,
    'member_id': memberId,
    'incident_id': incidentId,
    'local_media_id': localMediaId,
    'kind': kind,
    'file_path': filePath,
    'thumb_path': thumbPath,
    'text': text,
    'category': category,
    'author': author,
    'duration_ms': durationMs,
    'captured_at': capturedAt,
    'address': address,
    'weather': weather,
    'sync_observation': syncObservation ? 1 : 0,
    'status': status,
    'attempts': attempts,
    'last_error': lastError,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory NoteMediaUploadTask.fromRow(Map<String, Object?> row) =>
      NoteMediaUploadTask(
        id: row['id']?.toString() ?? '',
        unitId: row['unit_id']?.toString() ?? '',
        memberId: row['member_id']?.toString() ?? '',
        incidentId: row['incident_id']?.toString() ?? '',
        localMediaId: row['local_media_id']?.toString() ?? '',
        kind: row['kind']?.toString() ?? 'photo',
        filePath: row['file_path']?.toString() ?? '',
        thumbPath: row['thumb_path']?.toString() ?? '',
        text: row['text']?.toString() ?? '',
        category: row['category']?.toString() ?? NoteCategory.other,
        author: row['author']?.toString() ?? '',
        durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
        capturedAt: (row['captured_at'] as num?)?.toInt() ?? 0,
        address: row['address']?.toString() ?? '',
        weather: row['weather']?.toString() ?? '',
        syncObservation: ((row['sync_observation'] as num?)?.toInt() ?? 0) == 1,
        status: row['status']?.toString() ?? 'queued',
        attempts: (row['attempts'] as num?)?.toInt() ?? 0,
        lastError: row['last_error']?.toString() ?? '',
        createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (row['updated_at'] as num?)?.toInt() ?? 0,
      );

  Note toOptimisticNote() => Note(
    id: 'pending-media-$id',
    text: text,
    category: category,
    author: author,
    createdAt: createdAt,
    updatedAt: updatedAt,
    media: <NoteMediaAttachment>[
      NoteMediaAttachment(
        id: 'pending-$id',
        kind: kind,
        durationMs: durationMs,
        capturedAt: capturedAt,
        address: address,
        weather: weather,
        available: true,
        localPath: filePath,
        localThumbPath: thumbPath,
        uploadStatus: uploadStatus,
        uploadError: lastError,
        queueTaskId: id,
      ),
    ],
  );
}

typedef NoteMediaUploader = Future<Note> Function(NoteMediaUploadTask task);

/// 持久化水印相机火场日志媒体后台上传队列。
///
/// 在相册保存/系统分享执行时把带水印成片拷贝至独立队列暂存区后入队，
/// 使原拍摄工作副本可立即安全清理；弱网或断网时保留待上传项并呈现在火场日志流中，
/// 恢复连接后严格单通道串行自动补传。
class NoteMediaUploadQueue extends ChangeNotifier {
  NoteMediaUploadQueue._({
    String? databasePath,
    String? stagingDirPath,
    DatabaseFactory? databaseFactory,
  }) : _databasePathOverride = databasePath,
       _stagingDirOverride = stagingDirPath,
       _databaseFactoryOverride = databaseFactory;

  factory NoteMediaUploadQueue.forTesting({
    required String databasePath,
    required String stagingDirPath,
    DatabaseFactory? databaseFactory,
  }) => NoteMediaUploadQueue._(
    databasePath: databasePath,
    stagingDirPath: stagingDirPath,
    databaseFactory: databaseFactory,
  );

  static final NoteMediaUploadQueue instance = NoteMediaUploadQueue._();

  static const int maxAttempts = 5;

  final String? _databasePathOverride;
  final String? _stagingDirOverride;
  final DatabaseFactory? _databaseFactoryOverride;

  Database? _db;
  Future<Database>? _opening;
  bool _cacheLoaded = false;
  List<NoteMediaUploadTask> _tasks = <NoteMediaUploadTask>[];
  Future<void>? _drainFuture;
  bool _drainAgain = false;
  int _seq = 0;

  List<NoteMediaUploadTask> get tasks =>
      List<NoteMediaUploadTask>.unmodifiable(_tasks);

  static String buildDefaultNoteText({
    required String kind,
    int durationMs = 0,
    String address = '',
  }) {
    final cleanAddr = address.trim();
    if (kind == 'photo') {
      return cleanAddr.isNotEmpty ? '现场拍照 · $cleanAddr' : '现场拍照';
    }
    final sec = (durationMs / 1000).round();
    final base = sec > 0 ? '现场拍摄视频（${sec}s）' : '现场拍摄视频';
    return cleanAddr.isNotEmpty ? '$base · $cleanAddr' : base;
  }

  Future<Database> _openDb() {
    final existing = _db;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= _initDb();
  }

  Future<Database> _initDb() async {
    try {
      final dbPath =
          _databasePathOverride ??
          p.join(await getDatabasesPath(), 'watchdog_note_media_queue.db');
      final dir = Directory(p.dirname(dbPath));
      if (!dir.existsSync()) await dir.create(recursive: true);
      final factory = _databaseFactoryOverride ?? databaseFactory;
      final db = await factory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (Database d, int _) async {
          await d.execute('''
            CREATE TABLE $_queueTable (
              id TEXT PRIMARY KEY,
              unit_id TEXT NOT NULL,
              member_id TEXT NOT NULL,
              incident_id TEXT NOT NULL,
              local_media_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              file_path TEXT NOT NULL,
              thumb_path TEXT NOT NULL,
              text TEXT NOT NULL,
              category TEXT NOT NULL,
              author TEXT NOT NULL,
              duration_ms INTEGER NOT NULL,
              captured_at INTEGER NOT NULL,
              address TEXT NOT NULL,
              weather TEXT NOT NULL,
              sync_observation INTEGER NOT NULL,
              status TEXT NOT NULL,
              attempts INTEGER NOT NULL,
              last_error TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await d.execute(
            'CREATE INDEX idx_note_media_queue_scope ON $_queueTable (unit_id, member_id, incident_id, created_at ASC)',
          );
        },
      ),
      );
      _db = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  Future<Directory> _stagingRoot() async {
    final base = _stagingDirOverride != null
        ? Directory(_stagingDirOverride)
        : Directory(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'note_media_upload_queue',
            ),
          );
    if (!base.existsSync()) await base.create(recursive: true);
    return base;
  }

  Future<void> loadCache({bool force = false}) async {
    if (_cacheLoaded && !force) return;
    final db = await _openDb();
    // 上次进程如在上传途中退出，恢复为 queued 以便重连后自动续传。
    await db.update(
      _queueTable,
      <String, Object?>{'status': 'queued'},
      where: 'status = ?',
      whereArgs: const <Object?>['uploading'],
    );
    final rows = await db.query(_queueTable, orderBy: 'created_at ASC');
    _tasks = rows.map(NoteMediaUploadTask.fromRow).toList();
    _cacheLoaded = true;
    notifyListeners();
  }

  List<Note> pendingNotesForIncident({
    required String incidentId,
    required String unitId,
    required String memberId,
  }) {
    if (incidentId.isEmpty) return const <Note>[];
    final matching =
        _tasks
            .where(
              (t) =>
                  t.incidentId == incidentId &&
                  (unitId.isEmpty || t.unitId == unitId) &&
                  (memberId.isEmpty || t.memberId == memberId),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return matching.map((t) => t.toOptimisticNote()).toList(growable: false);
  }

  Future<NoteMediaUploadTask> enqueue({
    required String unitId,
    required String memberId,
    required String incidentId,
    required String localMediaId,
    required String kind,
    required String sourceFilePath,
    String sourceThumbPath = '',
    String text = '',
    String? category,
    String author = '',
    int durationMs = 0,
    int capturedAt = 0,
    String address = '',
    String weather = '',
    bool syncObservation = false,
  }) async {
    await loadCache();
    final source = File(sourceFilePath);
    if (!source.existsSync() || source.lengthSync() <= 0) {
      throw StateError('待上传媒体文件不存在：$sourceFilePath');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final taskId =
        'nmq-${now.toRadixString(36)}-${(++_seq).toRadixString(36)}';
    final stagingRoot = await _stagingRoot();
    final taskDir = Directory(p.join(stagingRoot.path, taskId));
    await taskDir.create(recursive: true);

    try {
      final rawExt = p.extension(sourceFilePath).toLowerCase();
      final ext = rawExt.isNotEmpty
          ? rawExt
          : (kind == 'video' ? '.mp4' : '.jpg');
      final stagedMedia = File(p.join(taskDir.path, 'media$ext'));
      await source.copy(stagedMedia.path);

      var stagedThumbPath = '';
      if (sourceThumbPath.isNotEmpty) {
        final thumbFile = File(sourceThumbPath);
        if (thumbFile.existsSync() && thumbFile.lengthSync() > 0) {
          final stagedThumb = File(p.join(taskDir.path, 'thumb.jpg'));
          await thumbFile.copy(stagedThumb.path);
          stagedThumbPath = stagedThumb.path;
        }
      }

      final trimmedText = text.trim();
      final resolvedText = trimmedText.isNotEmpty
          ? trimmedText
          : buildDefaultNoteText(
              kind: kind,
              durationMs: durationMs,
              address: address,
            );
      final resolvedCategory = (category != null && category.trim().isNotEmpty)
          ? category.trim()
          : NoteCategory.fromText(resolvedText);

      final task = NoteMediaUploadTask(
        id: taskId,
        unitId: unitId,
        memberId: memberId,
        incidentId: incidentId,
        localMediaId: localMediaId,
        kind: kind,
        filePath: stagedMedia.path,
        thumbPath: stagedThumbPath,
        text: resolvedText,
        category: resolvedCategory,
        author: author.trim(),
        durationMs: durationMs,
        capturedAt: capturedAt > 0 ? capturedAt : now,
        address: address.trim(),
        weather: weather.trim(),
        syncObservation: syncObservation && trimmedText.isNotEmpty,
        status: 'queued',
        attempts: 0,
        lastError: '',
        createdAt: now,
        updatedAt: now,
      );

      final db = await _openDb();
      await db.insert(_queueTable, task.toRow());
      _tasks = <NoteMediaUploadTask>[..._tasks, task];
      notifyListeners();
      return task;
    } catch (_) {
      await _deleteTaskDir(taskId);
      rethrow;
    }
  }

  Future<void> drain(
    NoteMediaUploader uploader, {
    required String unitId,
    required String memberId,
    Set<String>? allowedIncidentIds,
    void Function(Note syncedNote, NoteMediaUploadTask task)? onUploaded,
  }) async {
    if (_drainFuture != null) {
      _drainAgain = true;
      await _drainFuture;
      return;
    }

    Future<void> runLoop() async {
      do {
        _drainAgain = false;
        await loadCache();
        final snapshot = _tasks
            .where(
              (t) =>
                  t.status == 'queued' &&
                  (unitId.isEmpty || t.unitId == unitId) &&
                  (memberId.isEmpty || t.memberId == memberId) &&
                  (allowedIncidentIds == null ||
                      allowedIncidentIds.contains(t.incidentId)),
            )
            .toList(growable: false);

        for (final current in snapshot) {
          if (!_tasks.any((t) => t.id == current.id && t.status == 'queued')) {
            continue;
          }
          if (!File(current.filePath).existsSync()) {
            await _markFailed(current, '本机待传文件已丢失');
            continue;
          }

          await _updateStatus(current.id, status: 'uploading', lastError: '');
          try {
            final synced = await uploader(current);
            await _removeCompleted(current.id);
            onUploaded?.call(synced, current);
          } catch (error) {
            final nextAttempts = current.attempts + 1;
            final permanent =
                _isPermanentError(error) || nextAttempts >= maxAttempts;
            await _updateStatus(
              current.id,
              status: permanent ? 'failed' : 'queued',
              attempts: nextAttempts,
              lastError: _errorMessage(error),
            );
            if (!permanent) {
              // 网络或服务端暂不可用时停止本轮后续尝试，等待恢复连接后再试。
              break;
            }
          }
        }
      } while (_drainAgain);
    }

    final future = runLoop();
    _drainFuture = future;
    try {
      await future;
    } finally {
      if (identical(_drainFuture, future)) {
        _drainFuture = null;
      }
    }
  }

  Future<void> retryTask(String taskId) async {
    await loadCache();
    await _updateStatus(taskId, status: 'queued', attempts: 0, lastError: '');
  }

  Future<void> discardTask(String taskId) async {
    await loadCache();
    await _removeCompleted(taskId);
  }

  Future<void> _markFailed(NoteMediaUploadTask task, String message) async {
    await _updateStatus(
      task.id,
      status: 'failed',
      attempts: maxAttempts,
      lastError: message,
    );
  }

  Future<void> _updateStatus(
    String taskId, {
    required String status,
    int? attempts,
    required String lastError,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _openDb();
    await db.update(
      _queueTable,
      <String, Object?>{
        'status': status,
        if (attempts != null) 'attempts': attempts,
        'last_error': lastError,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: <Object?>[taskId],
    );
    _tasks = _tasks
        .map(
          (t) => t.id == taskId
              ? t.copyWith(
                  status: status,
                  attempts: attempts ?? t.attempts,
                  lastError: lastError,
                  updatedAt: now,
                )
              : t,
        )
        .toList();
    notifyListeners();
  }

  Future<void> _removeCompleted(String taskId) async {
    final db = await _openDb();
    await db.delete(_queueTable, where: 'id = ?', whereArgs: <Object?>[taskId]);
    _tasks = _tasks.where((t) => t.id != taskId).toList();
    notifyListeners();
    await _deleteTaskDir(taskId);
  }

  Future<void> _deleteTaskDir(String taskId) async {
    try {
      final root = await _stagingRoot();
      final dir = Directory(p.join(root.path, taskId));
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // 删除暂存目录失败不影响队列状态与后续任务。
    }
  }

  static bool _isPermanentError(Object error) {
    if (error is ApiException) {
      final code = error.statusCode ?? 0;
      if (code == 400 || code == 404 || code == 413 || code == 415) return true;
      if (code == 409 &&
          const <String>{
            'INCIDENT_ARCHIVED',
            'CLIENT_OP_ID_CONFLICT',
            'OPERATION_REQUEST_CONFLICT',
          }.contains(error.code)) {
        return true;
      }
    }
    return false;
  }

  static String _errorMessage(Object error) {
    final raw = error.toString().trim();
    return raw.length > 200 ? raw.substring(0, 200) : raw;
  }

  @visibleForTesting
  Future<void> closeForTesting() async {
    final db = _db;
    _db = null;
    _cacheLoaded = false;
    _tasks = <NoteMediaUploadTask>[];
    if (db != null && db.isOpen) {
      await db.close();
    }
  }
}
