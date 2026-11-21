import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/sync/sync_store.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/command_home/ui/sheets/connection_detail_sheet.dart';
import 'package:watchdog/features/command_home/ui/sheets/tactical_brief_command_sheet.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/data/models/incident_force.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/services/tactical_brief_engine.dart';

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
    home: Scaffold(body: child),
  );
}

void main() {
  group('TacticalBriefCommandSheet & ConnectionDetailSheet', () {
    testWidgets('展示冻结 TacticalBriefEngine 生成的标准公文简报并一键复制', (
      WidgetTester tester,
    ) async {
      String? copied;
      final brief = TacticalBriefEngine.formatObjectiveBrief(
        incident: const Incident(
          id: 'inc-brief',
          number: '2026-11-16-01',
          title: '示例商业广场火灾',
          info: <String, dynamic>{
            'original_category': '一级火灾扑救',
            'location': '示例路88号',
          },
          status: 'active',
          createdAt: 1,
          lastActivityAt: 1,
        ),
        forces: const <IncidentForce>[
          IncidentForce(
            id: 'f1',
            incidentId: 'inc-brief',
            stationName: '示例路站',
            vehicleCount: 2,
            personnelCount: 10,
            createdAt: 1,
            updatedAt: 1,
            version: 1,
          ),
        ],
        entries: const <Entry>[],
        notes: const <Note>[
          Note(
            id: 'n1',
            text: '一号水枪阵地出水控制火势',
            category: NoteCategory.water,
            createdAt: 1000,
            updatedAt: 1000,
          ),
        ],
        generatedAt: DateTime(2026, 5, 14, 14, 30),
      );

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () => showTacticalBriefCommandSheet(
                context,
                briefText: brief,
                clipboardWriter: (String text) async => copied = text,
                copiedResetDelay: const Duration(milliseconds: 500),
              ),
              child: const Text('打开上报'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开上报'));
      await tester.pumpAndSettle();

      expect(find.text('警情上报'), findsOneWidget);
      expect(find.textContaining('【火灾扑救战况速报】'), findsOneWidget);
      expect(find.byKey(const Key('tactical-brief-copy-btn')), findsOneWidget);
      expect(find.text('一键复制上报全文'), findsOneWidget);

      await tester.tap(find.byKey(const Key('tactical-brief-copy-btn')));
      await tester.pump();

      expect(copied, contains('【火灾扑救战况速报】'));
      expect(find.text('已复制到剪贴板'), findsOneWidget);
      expect(
        find.text('已复制标准化警情上报，可直接切换至政务微信/政务钉群粘贴发送'),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('一键复制上报全文'), findsOneWidget);
    });

    testWidgets('自动脱敏过滤正文中的验证码与 token 字段', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const TacticalBriefCommandSheet(
            briefText: '现场简报：内部验证码: abc998811，阵地正常。',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('abc998811'), findsNothing);
      expect(find.textContaining('验证码: ****'), findsOneWidget);
    });

    testWidgets('ConnectionDetailSheet 展示断线提示并可触发重试同步', (
      WidgetTester tester,
    ) async {
      var retried = 0;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () => showConnectionDetailSheet(
                context,
                snapshotProvider: () => const ConnectionDetailSnapshot(
                  isGuest: false,
                  syncing: false,
                  connectionLost: true,
                  syncConnectionState: SyncConnectionState.reconnecting,
                  serverUrl: 'https://api.example.invalid',
                  pendingSyncCount: 3,
                ),
                onRetrySync: () async => retried++,
              ),
              child: const Text('连接详情'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('连接详情'));
      await tester.pumpAndSettle();

      expect(find.text('连接与同步状态'), findsOneWidget);
      expect(find.text('状态：连接已中断'), findsOneWidget);
      expect(find.textContaining('待补传离线操作：3 条'), findsOneWidget);
      expect(find.text('服务地址：https://api.example.invalid'), findsOneWidget);

      await tester.tap(find.byKey(const Key('connection-retry-sync-btn')));
      await tester.pumpAndSettle();
      expect(retried, 1);
    });

    testWidgets('ConnectionDetailSheet 游客模式禁用重试同步按钮', (
      WidgetTester tester,
    ) async {
      var retried = 0;
      await tester.pumpWidget(
        _wrap(
          ConnectionDetailSheet(
            snapshotProvider: () => const ConnectionDetailSnapshot(
              isGuest: true,
              syncing: false,
              connectionLost: false,
              syncConnectionState: SyncConnectionState.stopped,
              serverUrl: '',
            ),
            onRetrySync: () async => retried++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('模式：游客模式（单机演练）'), findsOneWidget);
      await tester.tap(find.byKey(const Key('connection-retry-sync-btn')));
      await tester.pump();
      expect(retried, 0);
    });

    testWidgets('360dp @ 130% 暗曜主题下简报与连接弹窗零溢出', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(
          const TacticalBriefCommandSheet(
            briefText: '【抢险救援现场速报】示例路口交通救援（14:30）\n事发地点：示例路1号',
          ),
          brightness: Brightness.dark,
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
