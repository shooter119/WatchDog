import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/ui/sheets/same_name_conflict_sheet.dart';

Entry _existing(String name) => Entry(
  id: 'e-$name',
  name: name,
  pressureMpa: 20,
  durationMin: 34,
  entryAt: DateTime(2026, 5, 1, 14, 30).millisecondsSinceEpoch,
  exitAt: DateTime(2026, 5, 1, 15, 4).millisecondsSinceEpoch,
  source: 'voice',
);

void main() {
  group('SameNameConflictSheet 同名已在场确认弹窗', () {
    testWidgets('展示已有入场说明并支持选择合并（SameNameChoice.merge）', (tester) async {
      final existing = _existing('张伟');
      SameNameChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showSameNameConflictSheet(
                      ctx,
                      existing: existing,
                      pressureMpa: 15,
                      durationMin: 26,
                    );
                  },
                  child: const Text('触发'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();

      expect(find.byType(CommandSheet), findsOneWidget);
      expect(find.text('该人员已在火场内'), findsOneWidget);
      expect(find.textContaining('尚未出场'), findsWidgets);
      expect(find.textContaining('15.0 兆帕'), findsOneWidget);

      await tester.tap(find.byKey(const Key('same-name-merge-btn')));
      await tester.pumpAndSettle();
      expect(result, SameNameChoice.merge);
      expect(find.text('该人员已在火场内'), findsNothing);
    });

    testWidgets('支持选择同名不同人（SameNameChoice.force）与取消（null）', (tester) async {
      final existing = _existing('李娜');
      SameNameChoice? result;
      final ctxKey = GlobalKey();
      Future<void> open() async {
        result = await showSameNameConflictSheet(
          ctxKey.currentContext!,
          existing: existing,
          pressureMpa: 20,
          durationMin: 34,
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              key: ctxKey,
              builder: (ctx) => Center(
                child: ElevatedButton(onPressed: open, child: const Text('触发')),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('same-name-force-btn')));
      await tester.pumpAndSettle();
      expect(result, SameNameChoice.force);

      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('360dp @ 130% 字体缩放下无溢出且主选项按钮高度 ≥ 56dp', (tester) async {
      const surfaceSize = Size(360, 780);
      tester.view.physicalSize = surfaceSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final existing = _existing('消防救援一号班长');
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: surfaceSize,
            devicePixelRatio: 1.0,
            textScaler: TextScaler.linear(1.3),
            disableAnimations: true,
          ),
          child: MaterialApp(
            theme: buildCommandTheme(Brightness.dark),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () => showSameNameConflictSheet(
                      ctx,
                      existing: existing,
                      pressureMpa: 18,
                      durationMin: 25,
                    ),
                    child: const Text('触发'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('same-name-merge-btn'))).height,
        greaterThanOrEqualTo(56.0),
      );
      expect(
        tester.getSize(find.byKey(const Key('same-name-force-btn'))).height,
        greaterThanOrEqualTo(56.0),
      );
    });
  });
}
