import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/pages/notes_page.dart';
import 'package:watchdog/pages/tactical_brief_sheet.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

class _TestAudio extends AudioService {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {}

  @override
  Stream<double> amplitudeStream() => const Stream.empty();

  @override
  Future<Uint8List> stop() async => Uint8List(0);

  @override
  Future<void> dispose() async {}
}

class _TestBriefController extends AppController {
  _TestBriefController({
    Incident? incident,
    List<IncidentForce> forces = const [],
    List<Note> notes = const [],
  }) : super() {
    currentIncident = incident;
    this.forces = forces;
    this.notes = notes;
    asrCloudEnabled = true;
    parseCloudEnabled = true;
  }

  @override
  bool get needsAuthentication => false;

  @override
  bool get canReadKeySites => false;

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<void> refreshNow() async {}
}

Incident _sampleIncident() => const Incident(
  id: 'inc-brief-actions',
  number: '2026-11-16-01',
  title: '示例商业广场火灾',
  info: {
    'original_category': '一级火灾扑救',
    'location': '示例路88号',
  },
  status: 'active',
  createdAt: 1,
  lastActivityAt: 1,
);

List<IncidentForce> _sampleForces() => const [
  IncidentForce(
    id: 'f1',
    incidentId: 'inc-brief-actions',
    stationName: '示例路站',
    vehicleCount: 2,
    personnelCount: 10,
    createdAt: 1,
    updatedAt: 1,
    version: 1,
  ),
];

Future<void> _pumpHome(
  WidgetTester tester,
  _TestBriefController controller, {
  Size size = const Size(430, 932),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => HomePage(
            controller: controller,
            audioService: _TestAudio(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void _expectSingleLineText(WidgetTester tester, String label) {
  final textFinder = find.text(label);
  expect(textFinder, findsOneWidget);
  final richTextFinder = find.descendant(
    of: textFinder,
    matching: find.byType(RichText),
  );
  expect(richTextFinder, findsOneWidget);

  final paragraph = tester.renderObject<RenderParagraph>(richTextFinder);
  expect(paragraph.didExceedMaxLines, isFalse);

  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    locale: paragraph.locale,
    maxLines: paragraph.maxLines,
  )..layout(
      minWidth: paragraph.constraints.minWidth,
      maxWidth: paragraph.constraints.maxWidth,
    );
  final lineCount = painter.computeLineMetrics().length;
  painter.dispose();

  expect(lineCount, 1, reason: '$label 必须保持单行显示');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController.instance.resetForTest();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
  });

  group('警情上报入口与弹窗文案', () {
    testWidgets('首页展示警情上报入口且弹窗保留标准公文抬头', (tester) async {
      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<dynamic, dynamic>;
              copiedText = args['text'] as String?;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final controller = _TestBriefController(
        incident: _sampleIncident(),
        forces: _sampleForces(),
        notes: const [
          Note(
            id: 'n1',
            text: '一号水枪阵地出水控制火势',
            category: NoteCategory.water,
            createdAt: 1000,
            updatedAt: 1000,
          ),
        ],
      );

      await _pumpHome(tester, controller);

      final toolFinder = find.byKey(const Key('tool-警情上报'));
      expect(toolFinder, findsOneWidget);
      expect(find.text('警情上报'), findsOneWidget);
      expect(find.byKey(const Key('tool-战况速报')), findsNothing);
      expect(find.text('战况速报'), findsNothing);

      await tester.ensureVisible(toolFinder);
      await tester.pumpAndSettle();
      await tester.tap(toolFinder);
      await tester.pumpAndSettle();

      expect(find.byType(TacticalBriefSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TacticalBriefSheet),
          matching: find.text('警情上报'),
        ),
        findsOneWidget,
      );
      expect(find.text('现场战况速报'), findsNothing);
      expect(find.text('一键复制上报全文'), findsOneWidget);
      expect(find.text('一键复制速报全文'), findsNothing);
      expect(find.textContaining('【火灾扑救战况速报】'), findsOneWidget);

      await tester.tap(find.text('一键复制上报全文'));
      await tester.pump();

      expect(copiedText, contains('【火灾扑救战况速报】'));
      expect(
        find.text('已复制标准化警情上报，可直接切换至政务微信/政务钉群粘贴发送'),
        findsOneWidget,
      );
      expect(find.textContaining('已复制标准化战况'), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('NotesPage 顶栏按钮 tooltip 为警情上报并可打开上报弹窗', (tester) async {
      final controller = _TestBriefController(
        incident: _sampleIncident(),
        forces: _sampleForces(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: NotesPage(controller: controller)),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('警情上报'), findsOneWidget);
      expect(find.byTooltip('战况速报'), findsNothing);

      await tester.tap(find.byTooltip('警情上报'));
      await tester.pumpAndSettle();

      expect(find.byType(TacticalBriefSheet), findsOneWidget);
      expect(find.text('警情上报'), findsOneWidget);
      expect(find.text('一键复制上报全文'), findsOneWidget);
      expect(find.textContaining('【火灾扑救战况速报】'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('警情展开区三联操作栏响应式排版', () {
    testWidgets('Size(430, 932) + 1.0x 下三按钮图标与文字呈横排且单行无溢出', (
      tester,
    ) async {
      final controller = _TestBriefController(
        incident: _sampleIncident(),
        forces: _sampleForces(),
      );

      await _pumpHome(
        tester,
        controller,
        size: const Size(430, 932),
        textScale: 1.0,
      );

      await tester.tap(find.byKey(const Key('toggle-incident-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident-card-details')), findsOneWidget);

      for (final label in const ['登记力量', '信息导入', '警情调整']) {
        _expectSingleLineText(tester, label);

        final textFinder = find.text(label);
        final buttonFinder = find.ancestor(
          of: textFinder,
          matching: find.byType(TextButton),
        );
        expect(buttonFinder, findsOneWidget);
        final iconFinder = find.descendant(
          of: buttonFinder,
          matching: find.byType(Icon),
        );
        expect(iconFinder, findsOneWidget);

        final iconRect = tester.getRect(iconFinder);
        final textRect = tester.getRect(textFinder);
        final buttonRect = tester.getRect(buttonFinder);

        expect(buttonRect.height, greaterThanOrEqualTo(48));
        expect((iconRect.center.dy - textRect.center.dy).abs(), lessThanOrEqualTo(4.0));
        expect(iconRect.center.dx, lessThan(textRect.left));
        expect(textRect.left, greaterThanOrEqualTo(buttonRect.left - 0.5));
        expect(textRect.right, lessThanOrEqualTo(buttonRect.right + 0.5));
        expect(textRect.height, lessThan(34));
      }

      expect(tester.takeException(), isNull);
    });

    for (final scenario in const [
      (name: 'Size(320, 720) + 1.0x', size: Size(320, 720), scale: 1.0),
      (name: 'Size(320, 720) + 1.5x', size: Size(320, 720), scale: 1.5),
      (name: 'Size(360, 780) + 1.25x', size: Size(360, 780), scale: 1.25),
    ]) {
      testWidgets('${scenario.name} 下三按钮切换为上图标下文字且单行不折行', (
        tester,
      ) async {
        final controller = _TestBriefController(
          incident: _sampleIncident(),
          forces: _sampleForces(),
        );

        await _pumpHome(
          tester,
          controller,
          size: scenario.size,
          textScale: scenario.scale,
        );

        await tester.tap(find.byKey(const Key('toggle-incident-card')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('incident-card-details')), findsOneWidget);

        for (final label in const ['登记力量', '信息导入', '警情调整']) {
          _expectSingleLineText(tester, label);

          final textFinder = find.text(label);
          final buttonFinder = find.ancestor(
            of: textFinder,
            matching: find.byType(TextButton),
          );
          expect(buttonFinder, findsOneWidget);
          final iconFinder = find.descendant(
            of: buttonFinder,
            matching: find.byType(Icon),
          );
          expect(iconFinder, findsOneWidget);

          final iconRect = tester.getRect(iconFinder);
          final textRect = tester.getRect(textFinder);
          final buttonRect = tester.getRect(buttonFinder);

          expect(buttonRect.height, greaterThanOrEqualTo(56));
          expect(iconRect.bottom, lessThan(textRect.top));
          expect(iconRect.center.dy, lessThan(textRect.top));
          expect(textRect.left, greaterThanOrEqualTo(buttonRect.left - 0.5));
          expect(textRect.right, lessThanOrEqualTo(buttonRect.right + 0.5));
          expect(textRect.height, lessThan(34));
        }

        expect(tester.takeException(), isNull);
      });
    }
  });
}
