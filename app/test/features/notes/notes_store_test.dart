import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/features/notes/data/notes_repository.dart';
import 'package:watchdog/features/notes/state/notes_store.dart';

class _FakeNotesRepository extends NotesRepository {
  _FakeNotesRepository()
    : super(
        ApiHttpTransport(
          const ApiConfig(baseUrl: 'http://test', incidentId: 'inc-1'),
        ),
      );

  Object? nextCreateError;
  Object? nextUpdateError;
  Object? nextDeleteError;
  String? lastCreateOpId;
  String? lastCreateAuthor;
  String? lastCreateCategory;
  String? lastCreateText;
  String? lastDeletedId;
  int nextId = 1;

  @override
  Future<Note> createNote({
    required String text,
    String? category,
    String? opId,
    String? author,
  }) async {
    lastCreateText = text;
    lastCreateCategory = category;
    lastCreateOpId = opId;
    lastCreateAuthor = author;
    if (nextCreateError != null) throw nextCreateError!;
    final id = 'srv-${nextId++}';
    return Note(
      id: id,
      text: text,
      category: category ?? NoteCategory.other,
      author: author ?? '',
      createdAt: 1000,
      updatedAt: 1000,
    );
  }

  @override
  Future<Note> updateNote({
    required String id,
    String? text,
    String? category,
  }) async {
    if (nextUpdateError != null) throw nextUpdateError!;
    return Note(
      id: id,
      text: text ?? '',
      category: category ?? NoteCategory.other,
      author: '张三',
      createdAt: 1000,
      updatedAt: 2000,
    );
  }

  @override
  Future<void> deleteNote(String id) async {
    if (nextDeleteError != null) throw nextDeleteError!;
    lastDeletedId = id;
  }
}

void main() {
  group('NotesStore', () {
    test('addNote 联网提交实名作者并与实时 note.created 按 id 去重', () async {
      final repo = _FakeNotesRepository();
      final store = NotesStore(
        repositoryProvider: () => repo,
        incidentIdProvider: () => 'inc-1',
        unitIdProvider: () => 'unit-1',
        memberIdProvider: () async => 'member-1',
        realNameProvider: () async => '张三',
      );
      addTearDown(store.dispose);

      final created = await store.addNote('东侧阵地出水控制火势', opId: 'op-1');
      expect(created.id, 'srv-1');
      expect(repo.lastCreateCategory, NoteCategory.water);
      expect(repo.lastCreateAuthor, '张三');
      expect(repo.lastCreateOpId, 'op-1');
      expect(store.notes.length, 1);

      // 实时通道重复推送同一 note.id 时不产生重复项
      final handled = store.applySyncEvent(
        eventType: 'note.created',
        payload: <String, dynamic>{
          'id': 'srv-1',
          'text': '东侧阵地出水控制火势',
          'category': NoteCategory.water,
          'author': '张三',
          'created_at': 1000,
          'updated_at': 1000,
        },
      );
      expect(handled, isTrue);
      expect(store.notes.length, 1);
    });

    test('addNote 断网时入本地离线队列并支持离线投影恢复', () async {
      final repo = _FakeNotesRepository()
        ..nextCreateError = TimeoutException('timeout');
      final enqueued = <Map<String, dynamic>>[];

      final store = NotesStore(
        repositoryProvider: () => repo,
        incidentIdProvider: () => 'inc-offline',
        unitIdProvider: () => 'unit-1',
        memberIdProvider: () async => 'member-1',
        realNameProvider: () async => '李四',
        nowMs: () => 5000,
        nowMicros: () => 5000001,
        offlineEnqueuer: ({
          required String incidentId,
          required String type,
          required int occurredAt,
          required String clientOpId,
          required Map<String, dynamic> payload,
          Map<String, String>? owner,
        }) async {
          enqueued.add(<String, dynamic>{
            'incident_id': incidentId,
            'type': type,
            'occurred_at': occurredAt,
            'client_op_id': clientOpId,
            'payload': jsonEncode(payload),
            'owner': owner,
          });
        },
      );
      addTearDown(store.dispose);

      final offlineNote = await store.addNote('二楼搜救发现被困人员');
      expect(offlineNote.id, 'offline-note-5000001');
      expect(offlineNote.category, NoteCategory.rescue);
      expect(offlineNote.author, '李四');
      expect(enqueued.length, 1);
      expect(store.notes.length, 1);

      final projected = NotesStore.applyOfflineOperationProjection(
        rows: enqueued,
        notes: const <Note>[],
        author: '李四',
      );
      expect(projected.length, 1);
      expect(projected.first.id, 'offline-note-5000001');
      expect(projected.first.text, '二楼搜救发现被困人员');
    });

    test('addNote 遇冲突错误码触发 onSync 并重新抛出', () async {
      final repo = _FakeNotesRepository()
        ..nextCreateError = ApiException(
          'conflict',
          statusCode: 409,
          code: 'VERSION_CONFLICT',
        );
      var syncCalls = 0;
      final store = NotesStore(
        repositoryProvider: () => repo,
        incidentIdProvider: () => 'inc-1',
        realNameProvider: () async => '张三',
        memberIdProvider: () async => 'm1',
        onSync: () async => syncCalls++,
      );
      addTearDown(store.dispose);

      await expectLater(
        () => store.addNote('测试冲突'),
        throwsA(isA<ApiException>()),
      );
      expect(syncCalls, 1);
    });

    test('addActionLog 规范格式化进场/出场文案并对超长 opId 做 SHA-256 摘要', () async {
      final repo = _FakeNotesRepository();
      final store = NotesStore(
        repositoryProvider: () => repo,
        incidentIdProvider: () => 'inc-1',
        realNameProvider: () async => '指挥员',
        memberIdProvider: () async => 'm1',
      );
      addTearDown(store.dispose);

      final longOpId = 'op-${'a' * 80}-entry-note';
      final expectedDigest = sha256.convert(utf8.encode(longOpId)).toString();

      await store.addActionLog(
        names: const <String>['张三', '李四'],
        action: '进场',
        category: NoteCategory.deploy,
        pressuresMpa: const <String, double>{'张三': 28.0, '李四': 26.5},
        opId: longOpId,
      );
      expect(
        repo.lastCreateText,
        '张三进入救援现场，空气呼吸器压力28兆帕、李四进入救援现场，空气呼吸器压力26.5兆帕',
      );
      expect(repo.lastCreateOpId, expectedDigest);
      expect(repo.lastCreateOpId!.length, 64);

      await store.addActionLog(
        names: const <String>['张三'],
        action: '出场',
        category: NoteCategory.withdraw,
        opId: 'short-op-1',
      );
      expect(repo.lastCreateText, '张三撤离救援现场');
      expect(repo.lastCreateOpId, 'short-op-1');
    });

    test('updateNote / deleteNote / 同步快照与事件删除行为正确', () async {
      final repo = _FakeNotesRepository();
      final store = NotesStore(
        repositoryProvider: () => repo,
        realNameProvider: () async => '张三',
        memberIdProvider: () async => 'm1',
      );
      addTearDown(store.dispose);

      store.applySyncSnapshot(<String, dynamic>{
        'incident_snapshot': <String, dynamic>{
          'notes': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'n1',
              'text': '原内容',
              'category': NoteCategory.deploy,
              'author': '张三',
              'created_at': 1000,
              'updated_at': 1000,
            },
            <String, dynamic>{
              'id': 'n2',
              'text': '二号水枪出水',
              'category': NoteCategory.water,
              'author': '李四',
              'created_at': 2000,
              'updated_at': 2000,
            },
          ],
        },
      });
      expect(store.notes.length, 2);

      final updated = await store.updateNote(
        'n1',
        text: '更新后的部署内容',
        category: NoteCategory.abnormal,
      );
      expect(updated.text, '更新后的部署内容');
      expect(store.notes.first.category, NoteCategory.abnormal);

      await store.deleteNote('n1');
      expect(repo.lastDeletedId, 'n1');
      expect(store.notes.map((Note n) => n.id), <String>['n2']);

      final deleted = store.applySyncEvent(
        eventType: 'note.deleted',
        payload: const <String, dynamic>{},
        aggregateId: 'n2',
      );
      expect(deleted, isTrue);
      expect(store.notes, isEmpty);
    });

    test('分类筛选与 recentNotes 数量裁剪正确', () {
      final store = NotesStore(
        initialNotes: <Note>[
          for (var i = 0; i < 7; i++)
            Note(
              id: 'n-$i',
              text: '记录 $i',
              category: i.isEven ? NoteCategory.water : NoteCategory.abnormal,
              createdAt: 1000 + i * 1000,
              updatedAt: 1000 + i * 1000,
            ),
        ],
      );
      addTearDown(store.dispose);

      expect(store.filteredNotes.length, 7);
      expect(store.recentNotes(limit: 4).length, 4);

      store.setCategory(NoteCategory.abnormal);
      expect(store.filteredNotes.length, 3);
      expect(
        store.filteredNotes.every((Note n) => n.category == NoteCategory.abnormal),
        isTrue,
      );

      store.setCategory(NotesStore.allCategory);
      expect(store.filteredNotes.length, 7);
    });
  });
}
