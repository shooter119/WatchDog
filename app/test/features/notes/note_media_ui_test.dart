import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/features/notes/data/models/note_media.dart';
import 'package:watchdog/features/notes/state/notes_store.dart';
import 'package:watchdog/features/notes/ui/note_media_viewer_page.dart';
import 'package:watchdog/features/notes/ui/notes_timeline_screen.dart';
import 'package:watchdog/features/notes/ui/widgets/note_media_strip.dart';
import 'package:watchdog/features/notes/ui/widgets/note_preview_section.dart';

Widget _wrap(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: w!,
    ),
    home: child,
  );
}

void main() {
  final fixedNow = DateTime(2026, 5, 14, 14, 30, 0);
  final baseTs = fixedNow.millisecondsSinceEpoch;

  group('Note Media 模型与火场日志媒体 UI', () {
    test('Note.fromJson 兼容无 media 旧数据并正确反序列化附件列表', () {
      final legacy = Note.fromJson(<String, dynamic>{
        'id': 'n-old',
        'text': '旧日志',
        'category': '其他',
        'author': '张三',
        'created_at': 1000,
        'updated_at': 1000,
      });
      expect(legacy.media, isEmpty);
      expect(legacy.hasMedia, isFalse);

      final modern = Note.fromJson(<String, dynamic>{
        'id': 'n-media',
        'text': '现场南门浓烟蔓延',
        'category': '异常',
        'author': '李四',
        'created_at': 2000,
        'updated_at': 2000,
        'media': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'nm-1',
            'kind': 'video',
            'mime': 'video/mp4',
            'size_bytes': 102400,
            'duration_ms': 12500,
            'available': true,
            'file_url': '/api/note-media/nm-1/file',
            'thumb_url': '/api/note-media/nm-1/thumb',
          },
        ],
      });
      expect(modern.hasMedia, isTrue);
      expect(modern.media.single.isVideo, isTrue);
      expect(modern.media.single.formattedDuration, '00:13');
      expect(modern.media.single.uploadStatus, NoteMediaUploadStatus.synced);
    });

    testWidgets('NoteMediaStrip 呈现等待/上传中/失败/已归档清理状态并触发重试与取消', (
      WidgetTester tester,
    ) async {
      String? retried;
      String? discarded;
      NoteMediaAttachment? opened;

      await tester.pumpWidget(
        _wrap(
          Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: NoteMediaStrip(
                attachments: const <NoteMediaAttachment>[
                  NoteMediaAttachment(
                    id: 'p-q',
                    kind: 'photo',
                    uploadStatus: NoteMediaUploadStatus.queued,
                    queueTaskId: 'task-q',
                  ),
                  NoteMediaAttachment(
                    id: 'v-u',
                    kind: 'video',
                    durationMs: 14000,
                    uploadStatus: NoteMediaUploadStatus.uploading,
                    queueTaskId: 'task-u',
                  ),
                  NoteMediaAttachment(
                    id: 'p-f',
                    kind: 'photo',
                    uploadStatus: NoteMediaUploadStatus.failed,
                    uploadError: '文件过大',
                    queueTaskId: 'task-f',
                  ),
                  NoteMediaAttachment(
                    id: 'p-purged',
                    kind: 'photo',
                    available: false,
                  ),
                ],
                onOpenMedia: (NoteMediaAttachment item) => opened = item,
                onRetryUpload: (String id) => retried = id,
                onDiscardUpload: (String id) => discarded = id,
              ),
            ),
          ),
        ),
      );

      expect(find.text('等待上传'), findsOneWidget);
      expect(find.text('上传中…'), findsOneWidget);
      expect(find.text('上传失败'), findsOneWidget);
      expect(find.text('00:14'), findsOneWidget);
      expect(find.byKey(const Key('note-media-purged-p-purged')), findsOneWidget);

      await tester.tap(find.byKey(const Key('note-media-card-p-q')));
      await tester.pump();
      expect(opened?.id, 'p-q');

      await tester.tap(find.byKey(const Key('note-media-retry-task-f')));
      await tester.pump();
      expect(retried, 'task-f');

      await tester.tap(find.byKey(const Key('note-media-discard-task-f')));
      await tester.pump();
      expect(discarded, 'task-f');
    });

    testWidgets('NotesTimelineScreen 拦截待上传条目编辑并在点击照片时打开大图预览', (
      WidgetTester tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('watchdog-nm-ui-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final photoFile = File('${tempDir.path}/sample.png')
        ..writeAsBytesSync(const <int>[
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
          0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
          0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
          0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
          0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
          0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
          0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
          0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
          0x42, 0x60, 0x82,
        ]);

      final pendingNote = Note(
        id: 'pending-media-t1',
        text: '现场拍照 · 示例路1号',
        category: NoteCategory.other,
        author: '张三',
        createdAt: baseTs,
        updatedAt: baseTs,
        media: <NoteMediaAttachment>[
          NoteMediaAttachment(
            id: 'pending-t1',
            kind: 'photo',
            localPath: photoFile.path,
            address: '示例路1号',
            weather: '多云 20℃',
            uploadStatus: NoteMediaUploadStatus.queued,
            queueTaskId: 't1',
          ),
        ],
      );
      final syncedNote = Note(
        id: 'srv-n1',
        text: '二楼火点照片',
        category: NoteCategory.abnormal,
        author: '李四',
        createdAt: baseTs - 60000,
        updatedAt: baseTs - 60000,
        media: <NoteMediaAttachment>[
          NoteMediaAttachment(
            id: 'nm-synced',
            kind: 'photo',
            localPath: photoFile.path,
            address: '示例路2号',
            weather: '晴 23℃',
          ),
        ],
      );

      final store = NotesStore(initialNotes: <Note>[pendingNote, syncedNote]);
      addTearDown(store.dispose);

      await tester.pumpWidget(
        _wrap(NotesTimelineScreen(store: store, now: fixedNow)),
      );
      await tester.pumpAndSettle();

      // 点击待上传日志卡本身应提示不可编辑
      await tester.tap(find.text('现场拍照 · 示例路1号'));
      await tester.pump();
      expect(find.text('该条媒体日志同步完成后可编辑'), findsOneWidget);

      // 点击已同步照片缩略图打开 NoteMediaViewerPage
      await tester.drag(find.byKey(const Key('notes-timeline-list')), const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-media-card-nm-synced')));
      await tester.pumpAndSettle();

      expect(find.byType(NoteMediaViewerPage), findsOneWidget);
      expect(find.text('现场照片'), findsOneWidget);
      expect(find.text('示例路2号 · 晴 23℃'), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets('360dp @ 130% 字号下首页预览与时间线失败操作保持零溢出且触控 >= 48dp (${brightness.name})', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final failedNote = Note(
          id: 'pending-media-tf',
          text: '水泵接合器加压完成 13800138000',
          category: NoteCategory.water,
          author: '张三',
          createdAt: baseTs,
          updatedAt: baseTs,
          media: const <NoteMediaAttachment>[
            NoteMediaAttachment(
              id: 'nm-fail',
              kind: 'video',
              durationMs: 25000,
              uploadStatus: NoteMediaUploadStatus.failed,
              uploadError: '上传超时',
              queueTaskId: 'tf',
            ),
          ],
        );

        await tester.pumpWidget(
          _wrap(
            Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: NotePreviewSection(
                  notes: <Note>[failedNote],
                  onSeeAll: () {},
                  onRetryMediaUpload: (_) {},
                  onDiscardMediaUpload: (_) {},
                  now: fixedNow,
                ),
              ),
            ),
            brightness: brightness,
            textScale: 1.3,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const Key('note-media-retry-tf'))).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byKey(const Key('note-media-discard-tf'))).height,
          greaterThanOrEqualTo(48),
        );
      });
    }

    testWidgets('NotePreviewSection 内带视频附件的卡片在 IntrinsicHeight 下底部不留多余空白', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final videoNote = Note(
        id: 'n-video-height',
        text: '现场人员已被救出。',
        category: NoteCategory.water,
        author: '张三',
        createdAt: baseTs,
        updatedAt: baseTs + 5000,
        media: const <NoteMediaAttachment>[
          NoteMediaAttachment(
            id: 'nm-video-1',
            kind: 'video',
            durationMs: 4000,
            available: true,
          ),
        ],
      );

      await tester.pumpWidget(
        _wrap(
          Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: NotePreviewSection(
                notes: <Note>[videoNote],
                onSeeAll: () {},
                onOpenMedia: (_) {},
                now: fixedNow,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mediaRect = tester.getRect(
        find.byKey(const Key('note-media-card-nm-video-1')),
      );
      expect(mediaRect.width, closeTo(168.0, 1.0));
      expect(mediaRect.height, closeTo(168.0 * 9 / 16, 1.0));

      final cardRect = tester.getRect(find.byType(SurfaceCard).first);
      final subtitleRect = tester.getRect(find.textContaining('张三'));
      // 卡片底部到最后一行元信息底部应仅为卡片内边距（12dp），不应被 IntrinsicHeight 拉出大段空白
      expect(cardRect.bottom - subtitleRect.bottom, lessThanOrEqualTo(16.0));
    });
  });
}
