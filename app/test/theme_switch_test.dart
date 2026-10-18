import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  void startSync() {}

  @override
  Future<void> sync() async {}
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

    // 切回昼白（换 key 会重建页面，滚动位置回到顶部，需要重新滚到该分区）
    await tester.scrollUntilVisible(
      find.text('昼白'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
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
}
