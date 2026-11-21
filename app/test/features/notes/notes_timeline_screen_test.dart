import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/features/notes/state/notes_store.dart';
import 'package:watchdog/features/notes/ui/notes_timeline_screen.dart';
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

  group('NotesTimelineScreen & NotePreviewSection', () {
    testWidgets('空列表展示引导态，且未选警情时点 FAB 触发选择警情回调', (WidgetTester tester) async {
      final store = NotesStore(realNameProvider: () async => '张三');
      addTearDown(store.dispose);
      var incidentRequested = 0;

      await tester.pumpWidget(
        _wrap(
          NotesTimelineScreen(
            store: store,
            requiresIncident: true,
            onRequestIncidentSelection: () => incidentRequested++,
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没有日志记录'), findsOneWidget);
      expect(find.textContaining('请先选择或新建警情'), findsOneWidget);

      await tester.tap(find.byKey(const Key('notes-manual-log-fab')));
      await tester.pump();
      expect(incidentRequested, 1);
    });

    testWidgets('使用 M0 TimelineList 渲染日志并支持分类筛选', (WidgetTester tester) async {
      final store = NotesStore(
        initialNotes: <Note>[
          Note(
            id: 'n1',
            text: '一号水枪出水压制火势',
            category: NoteCategory.water,
            author: '张三',
            createdAt: baseTs,
            updatedAt: baseTs,
          ),
          Note(
            id: 'n2',
            text: '三楼屋顶存在坍塌风险',
            category: NoteCategory.abnormal,
            author: '李四',
            createdAt: baseTs - 120000,
            updatedAt: baseTs - 120000,
          ),
        ],
        realNameProvider: () async => '张三',
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        _wrap(NotesTimelineScreen(store: store, now: fixedNow)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TimelineList), findsNWidgets(2));
      expect(find.text('一号水枪出水压制火势'), findsOneWidget);
      expect(find.text('三楼屋顶存在坍塌风险'), findsOneWidget);

      await tester.tap(find.text(NoteCategory.abnormal).first);
      await tester.pumpAndSettle();

      expect(find.text('三楼屋顶存在坍塌风险'), findsOneWidget);
      expect(find.text('一号水枪出水压制火势'), findsNothing);
    });

    testWidgets('点击 FAB 打开手动记录 CommandSheet 并成功记入日志', (WidgetTester tester) async {
      final store = NotesStore(
        realNameProvider: () async => '王五',
        memberIdProvider: () async => 'm1',
        nowMs: () => baseTs,
        nowMicros: () => baseTs * 1000,
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        _wrap(NotesTimelineScreen(store: store, now: fixedNow)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes-manual-log-fab')));
      await tester.pumpAndSettle();

      expect(find.text('手动记录'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('note-editor-text-field')),
        '东门建立供水干线',
      );
      await tester.tap(find.text(NoteCategory.water).last);
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-editor-save-btn')));
      await tester.pumpAndSettle();

      expect(store.notes.length, 1);
      expect(store.notes.first.text, '东门建立供水干线');
      expect(store.notes.first.category, NoteCategory.water);
      expect(find.text('东门建立供水干线'), findsOneWidget);
    });

    testWidgets('点击日志条目可编辑保存，并支持二次确认删除', (WidgetTester tester) async {
      final store = NotesStore(
        initialNotes: <Note>[
          Note(
            id: 'edit-1',
            text: '初始日志内容',
            category: NoteCategory.deploy,
            author: '张三',
            createdAt: baseTs,
            updatedAt: baseTs,
          ),
        ],
        realNameProvider: () async => '张三',
        nowMs: () => baseTs + 5000,
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        _wrap(NotesTimelineScreen(store: store, now: fixedNow)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('初始日志内容'));
      await tester.pumpAndSettle();
      expect(find.text('编辑日志'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('note-editor-text-field')),
        '修改后的战术记录',
      );
      await tester.tap(find.byKey(const Key('note-editor-save-btn')));
      await tester.pumpAndSettle();
      expect(find.text('修改后的战术记录'), findsOneWidget);

      await tester.tap(find.text('修改后的战术记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-editor-delete-btn')));
      await tester.pumpAndSettle();

      // 二次确认弹窗必须出现
      expect(find.text('删除日志'), findsOneWidget);
      expect(find.text('确认删除'), findsOneWidget);
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      expect(store.notes, isEmpty);
      expect(find.text('修改后的战术记录'), findsNothing);
    });

    testWidgets('含电话号码的日志高亮拨打芯片并通过 PhoneCaller 发起呼叫', (WidgetTester tester) async {
      final dialed = <Uri>[];
      final store = NotesStore(
        initialNotes: <Note>[
          Note(
            id: 'phone-1',
            text: '现场联系人王工 13800138000 已到北门配合断电',
            category: NoteCategory.deploy,
            author: '张三',
            createdAt: baseTs,
            updatedAt: baseTs,
          ),
        ],
        realNameProvider: () async => '张三',
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        _wrap(
          NotesTimelineScreen(
            store: store,
            now: fixedNow,
            phoneLauncher: (Uri uri) async {
              dialed.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final phoneChip = find.byKey(const Key('note-phone-call-13800138000'));
      expect(phoneChip, findsOneWidget);
      await tester.tap(phoneChip);
      await tester.pump();
      expect(dialed, <Uri>[Uri(scheme: 'tel', path: '13800138000')]);
    });

    testWidgets('顶栏警情上报按钮可触发 onOpenTacticalBrief', (WidgetTester tester) async {
      final store = NotesStore();
      addTearDown(store.dispose);
      var opened = 0;

      await tester.pumpWidget(
        _wrap(
          NotesTimelineScreen(
            store: store,
            onOpenTacticalBrief: () => opened++,
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('警情上报'), findsOneWidget);
      await tester.tap(find.byTooltip('警情上报'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('NotePreviewSection 展示最近最多 4 条并触发查看全部与单条回调', (WidgetTester tester) async {
      final notes = <Note>[
        for (var i = 0; i < 6; i++)
          Note(
            id: 'p-$i',
            text: '现场动态 #$i',
            category: NoteCategory.deploy,
            author: '张三',
            createdAt: baseTs - i * 60000,
            updatedAt: baseTs - i * 60000,
          ),
      ];
      var seeAllCount = 0;
      Note? tappedNote;

      await tester.pumpWidget(
        _wrap(
          Scaffold(
            body: SingleChildScrollView(
              child: NotePreviewSection(
                notes: notes,
                maxItems: 4,
                onSeeAll: () => seeAllCount++,
                onNoteTap: (Note n) => tappedNote = n,
                now: fixedNow,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-notes-preview')), findsOneWidget);
      expect(find.byKey(const Key('command-notes-see-all-btn')), findsOneWidget);
      expect(find.text('现场动态 #0'), findsOneWidget);
      expect(find.text('现场动态 #3'), findsOneWidget);
      expect(find.text('现场动态 #4'), findsNothing);

      await tester.tap(find.byKey(const Key('command-notes-see-all-btn')));
      await tester.pump();
      expect(seeAllCount, 1);

      await tester.tap(find.text('现场动态 #0'));
      await tester.pump();
      expect(tappedNote?.id, 'p-0');
    });

    testWidgets('360dp @ 130% 大字号下零溢出且 200 条日志流畅滚动', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = NotesStore(
        initialNotes: <Note>[
          for (var i = 0; i < 200; i++)
            Note(
              id: 'bulk-$i',
              text: '第 $i 条高密度作战火场动态记录，包含阵地与供水信息',
              category: NoteCategory.all[i % NoteCategory.all.length],
              author: '张三',
              createdAt: baseTs - i * 60000,
              updatedAt: baseTs - i * 60000,
            ),
        ],
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        _wrap(
          NotesTimelineScreen(
            store: store,
            onOpenTacticalBrief: () {},
            now: fixedNow,
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('notes-timeline-list')),
        const Offset(0, -1800),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
