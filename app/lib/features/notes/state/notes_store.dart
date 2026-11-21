import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../services/offline_queue.dart';
import '../../../services/settings.dart';
import '../data/models/note.dart';
import '../data/models/note_category.dart';
import '../data/notes_repository.dart';

typedef NotesRepositoryProvider = NotesRepository? Function();
typedef NotesIncidentIdProvider = String? Function();
typedef NotesUnitIdProvider = String Function();
typedef NotesMemberIdProvider = Future<String> Function();
typedef NotesRealNameProvider = Future<String> Function();
typedef NotesSyncCallback = Future<void> Function();
typedef NotesOfflineEnqueuer =
    Future<void> Function({
      required String incidentId,
      required String type,
      required int occurredAt,
      required String clientOpId,
      required Map<String, dynamic> payload,
      Map<String, String>? owner,
    });

/// 火场日志域状态容器。
///
/// 独立持有当前警情的日志列表与分类筛选状态，负责新增/编辑/删除、
/// 进出场规范化动作日志、超长 `opId` 的 SHA-256 摘要幂等键、离线入队与
/// 实时事件按 `note.id` 去重，严禁反向依赖其他 Store 或 `app/`。
class NotesStore extends ChangeNotifier {
  static const String allCategory = '全部';

  static const Set<String> conflictErrorCodes = <String>{
    'VERSION_CONFLICT',
    'ENTRY_EXITED',
    'STALE_PRESSURE',
  };

  NotesStore({
    List<Note> initialNotes = const <Note>[],
    NotesRepositoryProvider? repositoryProvider,
    NotesIncidentIdProvider? incidentIdProvider,
    NotesUnitIdProvider? unitIdProvider,
    NotesMemberIdProvider? memberIdProvider,
    NotesRealNameProvider? realNameProvider,
    NotesSyncCallback? onSync,
    NotesOfflineEnqueuer? offlineEnqueuer,
    int Function()? nowMs,
    int Function()? nowMicros,
  }) : _notes = List<Note>.of(initialNotes),
       _repositoryProvider = repositoryProvider,
       _incidentIdProvider = incidentIdProvider,
       _unitIdProvider = unitIdProvider,
       _memberIdProvider = memberIdProvider,
       _realNameProvider = realNameProvider,
       _onSync = onSync,
       _offlineEnqueuer = offlineEnqueuer,
       _nowMs = nowMs ?? _defaultNowMs,
       _nowMicros = nowMicros ?? _defaultNowMicros;

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;
  static int _defaultNowMicros() => DateTime.now().microsecondsSinceEpoch;

  final NotesRepositoryProvider? _repositoryProvider;
  final NotesIncidentIdProvider? _incidentIdProvider;
  final NotesUnitIdProvider? _unitIdProvider;
  final NotesMemberIdProvider? _memberIdProvider;
  final NotesRealNameProvider? _realNameProvider;
  final NotesSyncCallback? _onSync;
  final NotesOfflineEnqueuer? _offlineEnqueuer;
  final int Function() _nowMs;
  final int Function() _nowMicros;

  List<Note> _notes;
  String _selectedCategory = allCategory;
  bool _disposed = false;

  List<Note> get notes => List<Note>.unmodifiable(_notes);
  String get selectedCategory => _selectedCategory;
  bool get disposed => _disposed;

  /// 按当前分类筛选后的日志列表。
  List<Note> get filteredNotes {
    if (_selectedCategory == allCategory) {
      return List<Note>.unmodifiable(_notes);
    }
    return List<Note>.unmodifiable(
      _notes.where((Note n) => n.category == _selectedCategory),
    );
  }

  /// 最近若干条火场日志（默认 5 条），供指挥台首页预览。
  List<Note> recentNotes({int limit = 5}) {
    if (limit <= 0 || _notes.isEmpty) return const <Note>[];
    return List<Note>.unmodifiable(_notes.take(limit));
  }

  static bool isConflictError(Object error) =>
      error is ApiException && conflictErrorCodes.contains(error.code);

  static bool isNetworkError(Object error) =>
      error is TimeoutException ||
      (error is ApiException && (error.statusCode ?? 0) >= 500) ||
      error.toString().contains('SocketException') ||
      error.toString().contains('ClientException') ||
      error.toString().contains('Connection closed');

  /// 超长派生操作号按完整内容生成固定 64 位 SHA-256 摘要，保证重试幂等。
  static String? normalizeActionOpId(String? opId) {
    if (opId == null) return null;
    return opId.length > 64 ? sha256.convert(utf8.encode(opId)).toString() : opId;
  }

  static String formatPressureMpa(double pressure) =>
      pressure == pressure.roundToDouble()
          ? pressure.toInt().toString()
          : pressure.toString();

  /// 将仍在本地离线队列中待补传的日志记录叠加到服务端快照上。
  static List<Note> applyOfflineOperationProjection({
    required Iterable<Map<String, Object?>> rows,
    required List<Note> notes,
    required String author,
  }) {
    var projected = List<Note>.of(notes);
    for (final row in rows) {
      try {
        if (row['type']?.toString() != 'note') continue;
        final occurredAt = (row['occurred_at'] as num?)?.toInt() ?? 0;
        if (occurredAt <= 0) continue;
        final rawPayload = row['payload'];
        if (rawPayload is! String) continue;
        final decoded = jsonDecode(rawPayload);
        if (decoded is! Map) continue;
        final payload = Map<String, dynamic>.from(decoded);
        final id = payload['note_id']?.toString();
        final text = payload['text']?.toString();
        if (id == null || id.isEmpty || text == null || text.isEmpty) continue;
        projected = <Note>[
          Note(
            id: id,
            text: text,
            category: payload['category']?.toString() ?? NoteCategory.other,
            author: author,
            createdAt: occurredAt,
            updatedAt: occurredAt,
          ),
          ...projected.where((Note item) => item.id != id),
        ];
      } catch (_) {
        // 单条损坏的离线记录不能阻塞其余日志恢复。
      }
    }
    return projected;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setCategory(String category) {
    if (_selectedCategory == category) return;
    _selectedCategory = category;
    _notify();
  }

  void setNotes(List<Note> next, {bool notify = true}) {
    _notes = List<Note>.of(next);
    if (notify) _notify();
  }

  void clear({bool notify = true}) {
    _notes = <Note>[];
    if (notify) _notify();
  }

  /// 应用实时同步全量快照中的日志段。
  void applySyncSnapshot(
    Map<String, dynamic> snapshot, {
    bool notify = true,
  }) {
    final incidentSnapshot = snapshot['incident_snapshot'];
    if (incidentSnapshot is Map) {
      final data = Map<String, dynamic>.from(incidentSnapshot);
      _notes = (data['notes'] as List? ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> n) => Note.fromJson(Map<String, dynamic>.from(n)))
          .toList();
    } else if ((snapshot['cursors'] as Map?)?['incident'] == '0') {
      _notes = <Note>[];
    }
    if (notify) _notify();
  }

  /// 应用实时增量日志事件，按 `note.id` 幂等去重。
  bool applySyncEvent({
    required String eventType,
    required Map<String, dynamic> payload,
    String? aggregateId,
    bool notify = true,
  }) {
    switch (eventType) {
      case 'note.created':
      case 'note.updated':
        if (payload.isEmpty) return false;
        final note = Note.fromJson(payload);
        _notes = <Note>[
          note,
          ..._notes.where((Note item) => item.id != note.id),
        ];
        if (notify) _notify();
        return true;
      case 'note.deleted':
        final id = aggregateId ?? payload['id']?.toString();
        if (id == null || id.isEmpty) return false;
        _notes = _notes.where((Note item) => item.id != id).toList();
        if (notify) _notify();
        return true;
      default:
        return false;
    }
  }

  /// 新增火场随手记（语音分流自动入日志 / 手动添加）。
  ///
  /// - 实名作者随请求直接提交；
  /// - 联网请求返回与实时 `note.created` 可能乱序到达，统一按 `note.id` 去重；
  /// - 断网或服务端 5xx 时入本地离线队列，避免现场记录丢失。
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    final cat = category ?? NoteCategory.fromText(text);
    final author = await (_realNameProvider?.call() ?? Settings.realName);
    final incidentId = _incidentIdProvider?.call();
    final repo = _repositoryProvider?.call();
    final owner = <String, String>{
      'unit_id': _unitIdProvider?.call() ?? '',
      'member_id': await (_memberIdProvider?.call() ?? Settings.memberId),
    };

    Note note;
    if (repo == null) {
      final at = _nowMs();
      final noteId = 'local-note-${_nowMicros()}';
      note = Note(
        id: noteId,
        text: text,
        category: cat,
        author: author,
        createdAt: at,
        updatedAt: at,
      );
    } else {
      try {
        note = await repo.createNote(
          text: text,
          category: cat,
          opId: opId,
          author: author,
        );
      } catch (error) {
        if (isConflictError(error)) {
          await _onSync?.call();
          rethrow;
        }
        if (!isNetworkError(error) ||
            incidentId == null ||
            incidentId.isEmpty) {
          rethrow;
        }
        final at = _nowMs();
        final noteId = 'offline-note-${_nowMicros()}';
        final enqueue = _offlineEnqueuer ?? OfflineQueue.instance.enqueue;
        await enqueue(
          owner: owner,
          incidentId: incidentId,
          type: 'note',
          occurredAt: at,
          clientOpId: opId ?? noteId,
          payload: <String, dynamic>{
            'note_id': noteId,
            'text': text,
            'category': cat,
          },
        );
        note = Note(
          id: noteId,
          text: text,
          category: cat,
          author: author,
          createdAt: at,
          updatedAt: at,
        );
      }
      if (!identical(_repositoryProvider?.call(), repo)) return note;
    }

    _notes = <Note>[note, ..._notes.where((Note item) => item.id != note.id)];
    _notify();
    return note;
  }

  /// 进出场确认同步写入火场日志，使用规范化作战表述并对超长 `opId` 做 SHA-256 摘要。
  Future<Note> addActionLog({
    required Iterable<String> names,
    required String action,
    required String category,
    Map<String, double>? pressuresMpa,
    String? opId,
  }) {
    final cleanNames = names
        .map((String name) => name.trim())
        .where((String name) => name.isNotEmpty)
        .toList();
    if (cleanNames.isEmpty) throw StateError('缺少火场日志人员');

    final text = switch (action) {
      '进场' => cleanNames
          .map((String name) {
            final pressure = pressuresMpa?[name];
            final pressureText = pressure == null
                ? ''
                : '，空气呼吸器压力${formatPressureMpa(pressure)}兆帕';
            return '$name进入救援现场$pressureText';
          })
          .join('、'),
      '出场' => cleanNames.map((String name) => '$name撤离救援现场').join('、'),
      _ => cleanNames.map((String name) => '$name$action').join('、'),
    };

    return addNote(
      text,
      category: category,
      opId: normalizeActionOpId(opId),
    );
  }

  /// 编辑日志条目：`text`/`category` 传 null 表示不改。
  Future<Note> updateNote(
    String id, {
    String? text,
    String? category,
  }) async {
    final repo = _repositoryProvider?.call();
    Note updated;
    if (repo == null) {
      final existing = _notes.firstWhere(
        (Note n) => n.id == id,
        orElse: () => throw StateError('未找到待编辑日志'),
      );
      updated = Note(
        id: existing.id,
        text: text ?? existing.text,
        category: category ?? existing.category,
        author: existing.author,
        createdAt: existing.createdAt,
        updatedAt: _nowMs(),
      );
    } else {
      updated = await repo.updateNote(id: id, text: text, category: category);
    }
    _notes = _notes.map((Note n) => n.id == id ? updated : n).toList();
    _notify();
    return updated;
  }

  /// 删除日志条目。
  Future<void> deleteNote(String id) async {
    final repo = _repositoryProvider?.call();
    if (repo != null) {
      await repo.deleteNote(id);
    }
    _notes = _notes.where((Note n) => n.id != id).toList();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
