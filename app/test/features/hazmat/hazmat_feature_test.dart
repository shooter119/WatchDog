import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/hazmat/data/models/hazmat.dart';
import 'package:watchdog/features/hazmat/state/hazmat_store.dart';
import 'package:watchdog/features/hazmat/ui/hazmat_page.dart';
import 'package:watchdog/features/hazmat/ui/hazmat_tactical_card.dart';

class _FakeHazmatGateway {
  int syncCalls = 0;
  int aiCardCalls = 0;
  String? lastAiQuery;
  HazmatSyncResult syncResult = const HazmatSyncResult();
  HazmatAiResult Function(String query)? onAiCard;

  late final HazmatGateway gateway = HazmatGateway(
    syncHazmats: ({int since = 0, int limit = 500}) async {
      syncCalls += 1;
      return syncResult;
    },
    generateHazmatAiCard: (query) async {
      aiCardCalls += 1;
      lastAiQuery = query;
      if (onAiCard != null) return onAiCard!(query);
      return const HazmatAiResult(found: false, reason: '未查找到已核实危化品记录');
    },
  );
}

Widget _wrapDs(
  Widget home, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: home,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('HazmatStore 状态与离线/云端契约', () {
    test('离线检索 UN 编号直出目标，未命中绝不自动调用 AI', () async {
      final fake = _FakeHazmatGateway();
      final store = HazmatStore(gateway: fake.gateway);
      addTearDown(store.dispose);

      await store.initialize();
      expect(store.loadingLocal, isFalse);
      expect(store.totalCount, greaterThan(0));
      expect(fake.syncCalls, 1);
      expect(store.syncedFromServer, isTrue);

      // 输入 4 位 UN 编号直出单条金属钠
      await store.updateQuery('1428');
      expect(store.activeItem, isNotNull);
      expect(store.activeItem!.unNumber, '1428');
      expect(fake.aiCardCalls, 0);

      // 输入不存在的编号：结果为空，但绝不自动调 AI
      await store.updateQuery('UN 9901');
      expect(store.results, isEmpty);
      expect(store.activeItem, isNull);
      expect(fake.aiCardCalls, 0);

      // 仅在显式调用 requestAiCard 时触发
      await store.requestAiCard();
      expect(fake.aiCardCalls, 1);
      expect(fake.lastAiQuery, 'UN 9901');
    });

    test('遇水属性筛选准确生效', () async {
      final store = HazmatStore();
      addTearDown(store.dispose);

      await store.initialize();
      await store.setWaterFilter('forbidden');
      expect(store.results, isNotEmpty);
      expect(store.results.every((item) => item.isWaterForbidden), isTrue);
    });
  });

  group('HazmatPage 与 HazmatTacticalCard 交互回归', () {
    testWidgets('离线输入 4 位 UN 编号直出战术卡、支持复制要点且不含离线语音朗读按钮', (
      tester,
    ) async {
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

      await tester.pumpWidget(_wrapDs(const HazmatPage()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('hazmat-search-input')),
        '1428',
      );
      await tester.pumpAndSettle();

      expect(find.byType(HazmatTacticalCard), findsOneWidget);
      expect(find.text('UN 1428'), findsOneWidget);
      expect(find.textContaining('遇水属性：严禁用水'), findsOneWidget);
      expect(find.text('绝对禁忌 · 严禁动作'), findsOneWidget);

      // 严禁存在任何离线语音朗读按钮
      expect(find.byIcon(Icons.volume_up), findsNothing);
      expect(find.byIcon(Icons.volume_up_outlined), findsNothing);
      expect(find.byIcon(Icons.record_voice_over), findsNothing);
      expect(find.textContaining('播报'), findsNothing);
      expect(find.textContaining('朗读'), findsNothing);

      // 点击复制处置要点
      final copyBtn = find.byKey(const ValueKey<String>('hazmat-copy-btn'));
      expect(copyBtn, findsOneWidget);
      expect(tester.getSize(copyBtn).height, greaterThanOrEqualTo(48));
      await tester.tap(copyBtn);
      await tester.pumpAndSettle();

      expect(copiedText, isNotNull);
      expect(copiedText, contains('UN 1428'));
      expect(copiedText, contains('绝对禁忌：'));
      expect(find.textContaining('已复制电台处置要点'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('本地未命中时不自动调用 AI，点击手动按钮才调用并展示警示与防编造提示', (
      tester,
    ) async {
      final fake = _FakeHazmatGateway()
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

      await tester.pumpWidget(_wrapDs(HazmatPage(gateway: fake.gateway)));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('hazmat-search-input')),
        'UN 9901',
      );
      await tester.pumpAndSettle();
      expect(fake.aiCardCalls, 0);

      final aiBtn = find.byKey(const ValueKey<String>('hazmat-ai-fallback-btn'));
      expect(aiBtn, findsOneWidget);
      expect(tester.getSize(aiBtn).height, greaterThanOrEqualTo(56));

      await tester.tap(aiBtn);
      await tester.pumpAndSettle();
      expect(fake.aiCardCalls, 1);
      expect(fake.lastAiQuery, 'UN 9901');
      expect(find.byType(HazmatTacticalCard), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('hazmat-ai-warning-banner')),
        findsOneWidget,
      );
      expect(find.textContaining('AI 辅助提炼'), findsWidgets);

      // 不存在物质 -> 诚实未核实提示，绝不编造战术卡
      await tester.enterText(
        find.byKey(const ValueKey<String>('hazmat-search-input')),
        '不存在物质XYZ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('hazmat-ai-fallback-btn')));
      await tester.pumpAndSettle();

      expect(fake.aiCardCalls, 2);
      expect(find.byType(HazmatTacticalCard), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('hazmat-ai-unverified-banner')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('离线模式未命中不显示 AI 按钮，仅展示离线指引', (tester) async {
      await tester.pumpWidget(_wrapDs(const HazmatPage()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('hazmat-search-input')),
        'UN 9999',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('hazmat-ai-fallback-btn')), findsNothing);
      expect(find.textContaining('当前处于离线或未登录状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360dp 窄屏 @ 130% 字体缩放昼白与暗曜双主题渲染零溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      for (final brightness in Brightness.values) {
        // 列表态
        await tester.pumpWidget(
          _wrapDs(const HazmatPage(), brightness: brightness, textScale: 1.3),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // 战术卡态（UN 1075 液化石油气）
        await tester.enterText(
          find.byKey(const ValueKey<String>('hazmat-search-input')),
          '1075',
        );
        await tester.pumpAndSettle();
        expect(find.byType(HazmatTacticalCard), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 未命中态
        await tester.enterText(
          find.byKey(const ValueKey<String>('hazmat-search-input')),
          '未知危化品XYZ',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  });
}
