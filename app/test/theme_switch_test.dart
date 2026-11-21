import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/app/shell/command_app_shell.dart';
import 'package:watchdog/app/shell/shell_keys.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/settings/ui/profile_hub_page.dart';
import 'package:watchdog/main.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/system_pip.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/state/app_controller.dart';

class _ThemeFakeController extends AppController {
  @override
  bool get needsAuthentication => false;

  @override
  bool get needsIncidentSelection => false;

  @override
  Future<void> init() async {}

  @override
  Future<void> checkUpdateSilently() async {}

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => const <ChatMessage>[];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    ThemeController.instance.resetForTest();
    SystemPip.resetForTesting();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
    SystemPip.resetForTesting();
  });

  testWidgets('「我的」页可切换昼白 / 暗曜 / 跟随系统，同步落库且不触发 Settings.modifiedAt', (
    tester,
  ) async {
    final controller = _ThemeFakeController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(WatchDogApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ShellKeys.tabMine));
    await tester.pumpAndSettle();

    expect(ThemeController.instance.currentId, 'daylight');
    expect(await Settings.modifiedAt, 0);

    final scrollable = find
        .descendant(
          of: find.byType(ProfileHubPage),
          matching: find.byType(Scrollable),
        )
        .first;

    // 切至暗曜
    await tester.scrollUntilVisible(
      find.byKey(const Key('theme-option-night-tactical')),
      240,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-option-night-tactical')));
    await tester.pump();

    expect(ThemeController.instance.currentId, 'night-tactical');
    expect(ThemeController.instance.themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(ProfileHubPage))).brightness,
      Brightness.dark,
    );
    expect(
      tester.element(find.byType(ProfileHubPage)).ds.colors.canvas,
      DsColors.night.canvas,
    );

    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      expect(await Settings.appThemeId, 'night-tactical');
      expect(await Settings.modifiedAt, 0);
    });

    // 切至跟随系统（模拟系统为亮色 -> 应呈现昼白；切为暗色 -> 呈现暗曜）
    await tester.tap(find.byKey(const Key('theme-option-system')));
    await tester.pump();
    expect(ThemeController.instance.currentId, 'system');
    expect(ThemeController.instance.themeMode, ThemeMode.system);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pump();
    expect(
      Theme.of(tester.element(find.byType(ProfileHubPage))).brightness,
      Brightness.dark,
    );

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(
      Theme.of(tester.element(find.byType(ProfileHubPage))).brightness,
      Brightness.light,
    );

    // 切回昼白
    await tester.tap(find.byKey(const Key('theme-option-daylight')));
    await tester.pump();
    expect(ThemeController.instance.currentId, 'daylight');
    expect(
      tester.element(find.byType(ProfileHubPage)).ds.colors.canvas,
      DsColors.daylight.canvas,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('无缝切换主题不销毁页面树：保留输入框草稿与滚动位置，并同步刷新已 push 路由', (
    tester,
  ) async {
    final controller = _ThemeFakeController();
    addTearDown(controller.dispose);
    final textController = TextEditingController();
    final scrollController = ScrollController();
    addTearDown(textController.dispose);
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      CommandAppShell(
        controller: controller,
        enableStartupSideEffects: false,
        commandTabBuilder: (context) => Scaffold(
          body: ListView(
            controller: scrollController,
            children: <Widget>[
              TextField(
                key: const Key('draft-field'),
                controller: textController,
              ),
              TextButton(
                key: const Key('push-btn'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (ctx) => ColoredBox(
                      key: const Key('pushed-surface'),
                      color: ctx.ds.colors.surface,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                child: const Text('push'),
              ),
              const SizedBox(height: 1200),
            ],
          ),
        ),
        monitorTabBuilder: (_) => const SizedBox.shrink(),
        copilotTabBuilder: (_) => const SizedBox.shrink(),
        mineTabBuilder: (_) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('draft-field')), '火场草稿不丢失');
    scrollController.jumpTo(320);
    await tester.pump();

    // 当帧切至暗曜：不重建树，草稿与滚动偏移完整保留
    ThemeController.instance.select(AppThemePreference.night);
    await tester.pump();

    expect(textController.text, '火场草稿不丢失');
    expect(scrollController.offset, 320);
    expect(
      tester.element(find.byType(ListView)).ds.colors.canvas,
      DsColors.night.canvas,
    );

    // 滚回顶部确认输入框草稿可见，push 路由并验证切回昼白后同步刷新
    scrollController.jumpTo(0);
    await tester.pump();
    expect(find.text('火场草稿不丢失'), findsOneWidget);
    await tester.tap(find.byKey(const Key('push-btn')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<ColoredBox>(find.byKey(const Key('pushed-surface'))).color,
      DsColors.night.surface,
    );

    ThemeController.instance.select(AppThemePreference.daylight);
    await tester.pump();
    expect(
      tester.widget<ColoredBox>(find.byKey(const Key('pushed-surface'))).color,
      DsColors.daylight.surface,
    );
  });

  testWidgets('历史 warm-sand 迁移后首次启动弹出一次性提示并消费标记，重启不再复弹', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_theme': 'warm-sand',
    });
    await ThemeController.instance.load();
    expect(ThemeController.instance.warmSandMigratedPending, isTrue);

    final controller = _ThemeFakeController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      CommandAppShell(
        controller: controller,
        enableStartupSideEffects: false,
        commandTabBuilder: (_) => const SizedBox.shrink(),
        monitorTabBuilder: (_) => const SizedBox.shrink(),
        copilotTabBuilder: (_) => const SizedBox.shrink(),
        mineTabBuilder: (_) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('原「暖砂」配色已平滑升级为「昼白」'), findsOneWidget);
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
    await tester.runAsync(() async {
      expect(await Settings.warmSandMigratedNoticeShown, isTrue);
    });

    // 模拟重启再次加载：不再弹出提示
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await ThemeController.instance.load();
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);

    await tester.pumpWidget(
      CommandAppShell(
        controller: controller,
        enableStartupSideEffects: false,
        commandTabBuilder: (_) => const SizedBox.shrink(),
        monitorTabBuilder: (_) => const SizedBox.shrink(),
        copilotTabBuilder: (_) => const SizedBox.shrink(),
        mineTabBuilder: (_) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('原「暖砂」配色已平滑升级为「昼白」'), findsNothing);
  });
}
