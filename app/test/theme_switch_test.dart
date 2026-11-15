import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/main.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/settings_page.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_palette.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

/// 最小控制器：不启动轮询、不发网络请求，只提供设置页需要的只读状态。
class _FakeController extends AppController {
  @override
  bool get needsAuthentication => false;

  @override
  bool get needsIncidentSelection => false;

  @override
  Future<void> init() async {}

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}
}

class _FakeChatController extends _FakeController {
  _FakeChatController(this.history);

  final List<ChatMessage> history;

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => history;
}

Iterable<Color?> _collectSpanColors(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span.style?.color;
    final children = span.children;
    if (children != null) {
      for (final child in children) {
        yield* _collectSpanColors(child);
      }
    }
  }
}

/// 与 main.dart 一致的接线：ListenableBuilder 包住 MaterialApp，
/// 且 MaterialApp 写在 builder 内部（写成 child 会让切换失效）。
Widget _app(Widget home) {
  return ListenableBuilder(
    listenable: ThemeController.instance,
    builder: (context, _) => MaterialApp(
      theme: buildAppTheme(),
      themeAnimationDuration: Duration.zero,
      // 与 main.dart 一致：按 palette 换 key 强制重建，避免 const 子树残留旧色。
      home: KeyedSubtree(
        key: ValueKey(ThemeController.instance.currentId),
        child: home,
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController.instance.resetForTest();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
  });

  testWidgets('设置页切换配色后 AppColors、Theme 与偏好同步变化', (tester) async {
    final controller = _FakeController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Scaffold(body: SettingsPage(controller: controller))),
    );
    await tester.pumpAndSettle();

    expect(AppColors.palette.id, 'daylight');
    expect(await Settings.modifiedAt, 0);

    await tester.scrollUntilVisible(
      find.text('暖砂'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('暖砂'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暖砂'));
    await tester.pumpAndSettle();

    expect(AppColors.palette.id, 'warm-sand');
    expect(AppColors.background, AppPalette.warmSand.background);

    final context = tester.element(find.byType(SettingsPage));
    expect(
      Theme.of(context).scaffoldBackgroundColor,
      AppPalette.warmSand.background,
    );

    // 偏好已落库，且没有触发设置同步时间戳（避免覆盖其它设备的设置）。
    await tester.runAsync(() async {
      expect(await Settings.appThemeId, 'warm-sand');
      expect(await Settings.modifiedAt, 0);
    });

    // const 子树（SectionTitle 的色条在 build 里读 AppColors）必须同步刷新。
    Color? sectionBarColor() {
      final finder = find
          .descendant(
            of: find.byType(SectionTitle).first,
            matching: find.byType(Container),
          )
          .first;
      final container = tester.widget<Container>(finder);
      return (container.decoration as BoxDecoration).color;
    }

    expect(sectionBarColor(), AppPalette.warmSand.actionPrimary);

    // 切到暗曜
    await tester.scrollUntilVisible(
      find.text('暗曜'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('暗曜'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暗曜'));
    await tester.pumpAndSettle();
    expect(AppColors.palette.id, 'night-tactical');
    expect(
      Theme.of(tester.element(find.byType(SettingsPage))).brightness,
      Brightness.dark,
    );

    // 切回昼白（换 key 会重建页面，滚动位置回到顶部，需要重新滚到该分区）
    await tester.scrollUntilVisible(
      find.text('昼白'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('昼白'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('昼白'));
    await tester.pumpAndSettle();
    expect(AppColors.palette.id, 'daylight');
    expect(
      Theme.of(
        tester.element(find.byType(SettingsPage)),
      ).scaffoldBackgroundColor,
      AppPalette.daylight.background,
    );
  });

  testWidgets('已 push 的路由在切换主题后同步换色', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ColoredBox(
                      key: const Key('pushed-surface'),
                      color: AppColors.surface,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                child: const Text('push'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();

    ColoredBox pushed() =>
        tester.widget<ColoredBox>(find.byKey(const Key('pushed-surface')));
    expect(pushed().color, AppPalette.daylight.surface);

    ThemeController.instance.select(AppPalette.warmSand);
    await tester.pumpAndSettle();
    expect(pushed().color, AppPalette.warmSand.surface);
  });

  testWidgets('切换当帧即生效（无 Theme 过渡混色）', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: Text(
              'bg',
              style: TextStyle(
                color: Theme.of(context).scaffoldBackgroundColor,
              ),
            ),
          ),
        ),
      ),
    );

    ThemeController.instance.select(AppPalette.warmSand);
    await tester.pump();

    final text = tester.widget<Text>(find.text('bg'));
    expect(text.style?.color, AppPalette.warmSand.background);
    expect(
      Theme.of(tester.element(find.text('bg'))).scaffoldBackgroundColor,
      AppPalette.warmSand.background,
    );
  });

  testWidgets('完整 WatchDogApp 切换至暗曜后，GlobalKey 保留的处置页与辅助页欢迎态 const 子树均同步变色', (
    tester,
  ) async {
    final controller = _FakeController();

    await tester.pumpWidget(WatchDogApp(controller: controller));
    await tester.pumpAndSettle();

    // 先在日间配色访问处置页与辅助页，使 _homeKey 与 _chatKey 各自挂出子树。
    expect(
      tester.widget<Text>(find.text('警情处置')).style?.color,
      AppPalette.daylight.textPrimary,
    );
    await tester.tap(find.text('辅助'));
    await tester.pumpAndSettle();
    const sample = '气瓶压力下降太快怎么办？';
    expect(
      tester.widget<Text>(find.text(sample)).style?.color,
      AppPalette.daylight.textPrimary,
    );
    expect(
      tester.widget<Text>(find.text('你好，我是水元素')).style?.color,
      AppPalette.daylight.textPrimary,
    );

    // 切到设置页选择「暗曜」。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    final darkLabel = find.text('暗曜');
    await tester.scrollUntilVisible(
      darkLabel,
      400,
      scrollable: find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(darkLabel);
    await tester.pumpAndSettle();
    await tester.tap(darkLabel);
    await tester.pumpAndSettle();
    expect(AppColors.palette.id, AppPalette.nightTactical.id);

    // 切回辅助页：确认原 const _SampleQuestion、标题、免责文字全部同步使用暗曜亮色。
    await tester.tap(find.text('辅助'));
    await tester.pumpAndSettle();
    final darkSampleColor = tester.widget<Text>(find.text(sample)).style?.color;
    expect(darkSampleColor, AppPalette.nightTactical.textPrimary);
    expect(darkSampleColor, isNot(AppPalette.daylight.textPrimary));
    expect(
      tester.widget<Text>(find.text('你好，我是水元素')).style?.color,
      AppPalette.nightTactical.textPrimary,
    );
    expect(
      tester.widget<Text>(find.text('辅助问答')).style?.color,
      AppPalette.nightTactical.textPrimary,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('chat-disclaimer-footnote'))).style?.color,
      AppPalette.nightTactical.textTertiary,
    );

    // 切回处置页：确认 _homeKey 同样随主题完整重建。
    await tester.tap(find.text('处置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('警情处置')).style?.color,
      AppPalette.nightTactical.textPrimary,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('辅助页保留消息列表与文字输入态切换至暗曜时，Markdown 气泡与输入框同步高对比度刷新且不丢状态', (
    tester,
  ) async {
    final controller = _FakeChatController(const [
      ChatMessage(
        id: 'u1',
        role: 'user',
        content: '请说明空呼报警阈值处置原则',
        createdAt: 1700000000000,
      ),
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        content:
            '### 核心步骤\n- 立即检查**余气压力**，*保持通信*，参考[操作指引](https://example.com)和~~旧规范~~\n\n| 参数 | 阈值 |\n| --- | --- |\n| 报警压力 | 5.5 MPa |',
        createdAt: 1700000005000,
      ),
    ]);

    await tester.pumpWidget(WatchDogApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('辅助'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);

    // 打开临时文字输入框并输入草稿，确保切主题后草稿仍在且输入文字变亮。
    await tester.tap(find.byKey(const Key('chat-mode-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-text-field')), '草稿保留测试');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(const Key('chat-text-field'))).style?.color,
      AppPalette.daylight.textPrimary,
    );

    // 在辅助页停留状态下直接切至暗曜。
    ThemeController.instance.select(AppPalette.nightTactical);
    await tester.pumpAndSettle();

    expect(find.text('草稿保留测试'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('chat-text-field'))).style?.color,
      AppPalette.nightTactical.textPrimary,
    );
    expect(
      tester.widget<Text>(find.text('请说明空呼报警阈值处置原则')).style?.color,
      AppPalette.nightTactical.onPrimary,
    );

    // 验证 MarkdownBody 内部实际渲染出的 RichText 文字颜色已更新为暗曜色，没有残留 0xFF111111。
    final richTexts = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(MarkdownBody),
        matching: find.byType(RichText),
      ),
    );
    expect(richTexts, isNotEmpty);
    final colors = richTexts
        .expand((rt) => _collectSpanColors(rt.text))
        .whereType<Color>()
        .toList();
    expect(colors, isNotEmpty);
    expect(colors, isNot(contains(AppPalette.daylight.textPrimary)));
    expect(colors, contains(AppPalette.nightTactical.textPrimary));
    expect(colors, contains(AppPalette.nightTactical.noteInfo));
    expect(tester.takeException(), isNull);
  });
}
