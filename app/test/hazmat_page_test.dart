import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/hazmat.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/hazmat_page.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_palette.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

class _TestHazmatApi extends ApiClient {
  int syncCalls = 0;
  int aiCardCalls = 0;
  String? lastAiQuery;
  HazmatSyncResult syncResult = const HazmatSyncResult();
  HazmatAiResult Function(String query)? onAiCard;

  _TestHazmatApi() : super(baseUrl: 'http://localhost', incidentId: 'inc-1');

  @override
  Future<HazmatSyncResult> syncHazmats({
    int since = 0,
    int limit = 500,
  }) async {
    syncCalls += 1;
    return syncResult;
  }

  @override
  Future<HazmatAiResult> generateHazmatAiCard(String query) async {
    aiCardCalls += 1;
    lastAiQuery = query;
    if (onAiCard != null) {
      return onAiCard!(query);
    }
    return const HazmatAiResult(found: false, reason: '未查找到已核实危化品记录');
  }
}

class _TestAudio extends AudioService {
  @override
  Future<bool> hasPermission() async => true;
}

class _TestController extends AppController {
  _TestController({ApiClient? apiClient}) : super() {
    api = apiClient;
    currentIncident = const Incident(
      id: 'inc-1',
      number: '2026-01-01-01',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 1,
    );
  }

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AppColors.reset();
  });

  testWidgets('首页现场工具点击危化速查可进入危化品应急速查页', (tester) async {
    final controller = _TestController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: HomePage(controller: controller, audioService: _TestAudio()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tool = find.byKey(const ValueKey('tool-危化速查'));
    await tester.scrollUntilVisible(tool, 200);
    expect(tool, findsOneWidget);

    await tester.tap(tool);
    await tester.pumpAndSettle();

    expect(find.text('危化品应急速查'), findsOneWidget);
    expect(find.byKey(const ValueKey('hazmat-search-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离线输入 4 位 UN 编号直出战术卡、支持复制要点且不含离线语音朗读按钮', (tester) async {
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

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const HazmatPage(),
      ),
    );
    await tester.pumpAndSettle();

    // 输入 1428（金属钠），无需再点击列表行直接渲染战术卡
    await tester.enterText(
      find.byKey(const ValueKey('hazmat-search-input')),
      '1428',
    );
    await tester.pumpAndSettle();

    expect(find.byType(HazmatTacticalCard), findsOneWidget);
    expect(find.text('UN 1428'), findsOneWidget);
    expect(find.textContaining('遇水属性：严禁用水'), findsOneWidget);
    expect(find.text('绝对禁忌 · 严禁动作'), findsOneWidget);

    // 严禁存在语音朗读按钮
    expect(find.byIcon(Icons.volume_up), findsNothing);
    expect(find.byIcon(Icons.volume_up_outlined), findsNothing);
    expect(find.byIcon(Icons.record_voice_over), findsNothing);
    expect(find.textContaining('播报'), findsNothing);
    expect(find.textContaining('朗读'), findsNothing);

    // 点击复制处置要点
    final copyBtn = find.byKey(const ValueKey('hazmat-copy-btn'));
    expect(copyBtn, findsOneWidget);
    await tester.tap(copyBtn);
    await tester.pumpAndSettle();

    expect(copiedText, isNotNull);
    expect(copiedText, contains('UN 1428'));
    expect(copiedText, contains('绝对禁忌：'));
    expect(find.textContaining('已复制电台处置要点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地未命中时不自动调用 AI，点击按钮才调用并展示警示与防编造提示', (tester) async {
    final api = _TestHazmatApi()
      ..onAiCard = (query) {
        if (query == 'UN 9901') {
          return const HazmatAiResult(
            found: true,
            source: 'ai',
            disclaimer: 'AI 辅助提炼，请务必结合随车运单、SDS 与现场侦检仪器核实',
            item: HazmatItem(
              id: 'ai-9901',
              nameCn: '示例特种溶剂',
              unNumber: '9901',
              dangerCategory: '第3类 易燃液体',
              waterReactivity: 'normal',
              forbiddenAgents: '严禁直流水直接冲击液面',
              extinguishingAgents: '抗溶性泡沫、干粉',
              isolationDistance: '初期隔离 50m，下风向疏散 200m',
              source: 'ai',
            ),
          );
        }
        return const HazmatAiResult(
          found: false,
          reason: '未查找到与该编号对应的已核实危化品记录',
        );
      };
    final controller = _TestController(apiClient: api);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HazmatPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // 输入未收录编码时不自动发起 AI 请求
    await tester.enterText(
      find.byKey(const ValueKey('hazmat-search-input')),
      'UN 9901',
    );
    await tester.pumpAndSettle();
    expect(api.aiCardCalls, 0);

    final aiBtn = find.byKey(const ValueKey('hazmat-ai-fallback-btn'));
    expect(aiBtn, findsOneWidget);

    await tester.tap(aiBtn);
    await tester.pumpAndSettle();
    expect(api.aiCardCalls, 1);
    expect(api.lastAiQuery, 'UN 9901');
    expect(find.byType(HazmatTacticalCard), findsOneWidget);
    expect(find.textContaining('AI 辅助提炼'), findsWidgets);

    // 换用不存在的名称并点击 AI 按钮 -> 诚实未核实提示，不造假卡片
    await tester.enterText(
      find.byKey(const ValueKey('hazmat-search-input')),
      '不存在物质XYZ',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hazmat-ai-fallback-btn')));
    await tester.pumpAndSettle();

    expect(api.aiCardCalls, 2);
    expect(find.byType(HazmatTacticalCard), findsNothing);
    expect(
      find.byKey(const ValueKey('hazmat-ai-unverified-banner')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('360dp 窄屏与全部主题调色板下战术卡渲染无溢出', (tester) async {
    tester.view.physicalSize = const Size(360 * 2, 760 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    for (final palette in AppPalette.values) {
      AppColors.use(palette);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(palette),
          home: const HazmatPage(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('hazmat-search-input')),
        '1075',
      );
      await tester.pumpAndSettle();
      expect(find.byType(HazmatTacticalCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
