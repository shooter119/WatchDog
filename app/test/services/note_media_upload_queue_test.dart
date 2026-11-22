import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:watchdog/core/network/api_exceptions.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/features/notes/data/models/note_media.dart';
import 'package:watchdog/services/note_media_upload_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tempDir;
  late String dbPath;
  late String stagingPath;
  late NoteMediaUploadQueue queue;

  NoteMediaUploadQueue openIsolatedQueue() => NoteMediaUploadQueue.forTesting(
    databasePath: dbPath,
    stagingDirPath: stagingPath,
    databaseFactory: databaseFactoryFfi,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('watchdog-note-media-q-');
    dbPath = '${tempDir.path}/note_media_queue.db';
    stagingPath = '${tempDir.path}/staging';
    queue = openIsolatedQueue();
  });

  tearDown(() async {
    await queue.closeForTesting();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  File writeSampleFile(String name, List<int> bytes) {
    final file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(bytes, flush: true);
    return file;
  }

  test('入队立即隔离拷贝至暂存区，原工作副本清理后仍可渲染待传日志与上传', () async {
    final sourcePhoto = writeSampleFile('SRC_PHOTO.jpg', <int>[0xFF, 0xD8, 0xFF]);
    final task = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'media-1',
      kind: 'photo',
      sourceFilePath: sourcePhoto.path,
      address: '示例市示例路12号',
      weather: '晴 22℃',
      author: '张三',
      capturedAt: 1715660000000,
    );

    // 模拟核对页返回后立即清理本地工作副本
    sourcePhoto.deleteSync();

    expect(task.filePath, isNot(sourcePhoto.path));
    expect(File(task.filePath).existsSync(), isTrue);
    expect(task.text, '现场拍照 · 示例市示例路12号');
    expect(task.category, NoteCategory.other);

    final pending = queue.pendingNotesForIncident(
      incidentId: 'inc-1',
      unitId: 'unit-1',
      memberId: 'member-a',
    );
    expect(pending, hasLength(1));
    expect(pending.single.hasPendingMediaUpload, isTrue);
    expect(pending.single.media.single.uploadStatus, NoteMediaUploadStatus.queued);
    expect(pending.single.media.single.localPath, task.filePath);
    expect(
      queue.pendingNotesForIncident(
        incidentId: 'inc-other',
        unitId: 'unit-1',
        memberId: 'member-a',
      ),
      isEmpty,
    );
  });

  test('串行补传成功后清理暂存目录与队列记录并透传任务归属', () async {
    final photoFile = writeSampleFile('p1.jpg', <int>[1, 2, 3, 4]);
    final videoFile = writeSampleFile('v1.mp4', <int>[5, 6, 7, 8]);
    final thumbFile = writeSampleFile('t1.jpg', <int>[9, 10]);

    final t1 = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'm1',
      kind: 'photo',
      sourceFilePath: photoFile.path,
      text: '一号水枪到场出水',
      author: '张三',
    );
    final t2 = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'm2',
      kind: 'video',
      sourceFilePath: videoFile.path,
      sourceThumbPath: thumbFile.path,
      text: '三楼屋顶存在坍塌风险',
      durationMs: 9000,
      author: '张三',
      syncObservation: true,
    );

    final uploadedIds = <String>[];
    final syncedCallbacks = <(String, String)>[];

    await queue.drain(
      (NoteMediaUploadTask task) async {
        uploadedIds.add(task.id);
        expect(File(task.filePath).existsSync(), isTrue);
        if (task.kind == 'video') {
          expect(File(task.thumbPath).existsSync(), isTrue);
          expect(task.syncObservation, isTrue);
          expect(task.category, NoteCategory.abnormal);
        } else {
          expect(task.category, NoteCategory.water);
        }
        return Note(
          id: 'srv-${task.id}',
          text: task.text,
          category: task.category,
          author: task.author,
          createdAt: task.createdAt,
          updatedAt: task.updatedAt,
        );
      },
      unitId: 'unit-1',
      memberId: 'member-a',
      onUploaded: (Note syncedNote, NoteMediaUploadTask task) {
        syncedCallbacks.add((syncedNote.id, task.incidentId));
      },
    );

    expect(uploadedIds, <String>[t1.id, t2.id]);
    expect(syncedCallbacks, <(String, String)>[
      ('srv-${t1.id}', 'inc-1'),
      ('srv-${t2.id}', 'inc-1'),
    ]);
    expect(queue.tasks, isEmpty);
    expect(File(t1.filePath).existsSync(), isFalse);
    expect(File(t2.filePath).existsSync(), isFalse);
    expect(File(t2.thumbPath).existsSync(), isFalse);
  });

  test('网络瞬断保留重试次数与排队；永久错误立即置失败并支持重试或取消', () async {
    final f1 = writeSampleFile('net.jpg', <int>[1, 2, 3]);
    final f2 = writeSampleFile('too_big.jpg', <int>[4, 5, 6]);
    final f3 = writeSampleFile('cancel.jpg', <int>[7, 8, 9]);

    final tNet = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'm-net',
      kind: 'photo',
      sourceFilePath: f1.path,
    );
    final tPerm = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'm-perm',
      kind: 'photo',
      sourceFilePath: f2.path,
    );
    final tDiscard = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'm-discard',
      kind: 'photo',
      sourceFilePath: f3.path,
    );

    // 第一轮：tNet 触发网络异常，应保留 queued 且暂停后续 drain
    await queue.drain(
      (_) async => throw Exception('socket timeout'),
      unitId: 'unit-1',
      memberId: 'member-a',
    );
    final afterNet = queue.tasks.firstWhere((t) => t.id == tNet.id);
    expect(afterNet.uploadStatus, NoteMediaUploadStatus.queued);
    expect(afterNet.attempts, 1);
    expect(afterNet.lastError, contains('socket timeout'));

    // 第二轮：tNet 成功，tPerm 返回 413 永久失败，tDiscard 成功
    final seen = <String>[];
    await queue.drain(
      (NoteMediaUploadTask task) async {
        seen.add(task.id);
        if (task.id == tPerm.id) {
          throw ApiException('文件超过限制', statusCode: 413, code: 'FILE_TOO_LARGE');
        }
        return Note(
          id: 'srv-${task.id}',
          text: task.text,
          category: task.category,
          author: task.author,
          createdAt: task.createdAt,
          updatedAt: task.updatedAt,
        );
      },
      unitId: 'unit-1',
      memberId: 'member-a',
      allowedIncidentIds: const <String>{'inc-1'},
    );
    expect(seen, <String>[tNet.id, tPerm.id, tDiscard.id]);
    expect(queue.tasks, hasLength(1));
    expect(queue.tasks.single.id, tPerm.id);
    expect(queue.tasks.single.uploadStatus, NoteMediaUploadStatus.failed);

    // 重试 tPerm 并入队另一条用于验证 discardTask
    await queue.retryTask(tPerm.id);
    expect(queue.tasks.single.uploadStatus, NoteMediaUploadStatus.queued);
    expect(queue.tasks.single.attempts, 0);

    await queue.drain(
      (NoteMediaUploadTask task) async => Note(
        id: 'srv-${task.id}',
        text: task.text,
        category: task.category,
        author: task.author,
        createdAt: task.createdAt,
        updatedAt: task.updatedAt,
      ),
      unitId: 'unit-1',
      memberId: 'member-a',
    );
    expect(queue.tasks, isEmpty);

    // 取消待传任务同时清理暂存文件
    final fCancel = writeSampleFile('discard2.jpg', <int>[11, 12]);
    final created = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'm-d2',
      kind: 'photo',
      sourceFilePath: fCancel.path,
    );
    expect(File(created.filePath).existsSync(), isTrue);
    await queue.discardTask(created.id);
    expect(queue.tasks, isEmpty);
    expect(File(created.filePath).existsSync(), isFalse);
  });

  test('应用重启重新加载缓存时把残余 uploading 状态重置为 queued', () async {
    final file = writeSampleFile('crash.jpg', <int>[1, 2]);
    final created = await queue.enqueue(
      unitId: 'unit-1',
      memberId: 'member-a',
      incidentId: 'inc-1',
      localMediaId: 'm-crash',
      kind: 'photo',
      sourceFilePath: file.path,
    );
    await queue.closeForTesting();

    // 直接模拟进程崩在 uploading
    final rawDb = await databaseFactoryFfi.openDatabase(dbPath);
    await rawDb.update(
      'note_media_upload_tasks',
      <String, Object?>{'status': 'uploading'},
      where: 'id = ?',
      whereArgs: <Object?>[created.id],
    );
    await rawDb.close();

    final restarted = openIsolatedQueue();
    addTearDown(restarted.closeForTesting);
    await restarted.loadCache();
    expect(restarted.tasks, hasLength(1));
    expect(restarted.tasks.single.uploadStatus, NoteMediaUploadStatus.queued);
  });
}
