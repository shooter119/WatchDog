import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/theme/app_palette.dart';
import 'package:watchdog/theme/app_widgets.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ThemeController.instance.resetForTest();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
  });

  test('默认使用昼白方案', () {
    expect(ThemeController.instance.currentId, AppPalette.daylight.id);
    expect(AppColors.palette.id, AppPalette.daylight.id);
    expect(AppColors.background, AppPalette.daylight.background);
  });

  test('load 读回本机偏好', () async {
    SharedPreferences.setMockInitialValues({'app_theme': 'warm-sand'});
    await ThemeController.instance.load();
    expect(ThemeController.instance.currentId, 'warm-sand');
    expect(AppColors.palette.id, 'warm-sand');
    expect(AppColors.background, AppPalette.warmSand.background);
  });

  test('load 把非法值归一化为默认并写回', () async {
    SharedPreferences.setMockInitialValues({'app_theme': 'neon'});
    await ThemeController.instance.load();
    expect(ThemeController.instance.currentId, 'daylight');
    expect(await Settings.appThemeId, 'daylight');
  });

  test('select 立即生效、只通知一次并落库', () async {
    var notifications = 0;
    void listener() => notifications++;
    ThemeController.instance.addListener(listener);
    addTearDown(() => ThemeController.instance.removeListener(listener));

    ThemeController.instance.select(AppPalette.warmSand);
    expect(AppColors.palette.id, 'warm-sand');
    expect(notifications, 1);

    // select 内部不 await 持久化，给事件循环一次机会。
    await Future<void>.delayed(Duration.zero);
    expect(await Settings.appThemeId, 'warm-sand');
  });

  test('重复选择同一方案不通知', () {
    var notifications = 0;
    void listener() => notifications++;
    ThemeController.instance.addListener(listener);
    addTearDown(() => ThemeController.instance.removeListener(listener));

    ThemeController.instance.select(AppPalette.daylight);
    expect(notifications, 0);
  });

  test('数据纪元清空 prefs 后回落默认', () async {
    SharedPreferences.setMockInitialValues({'app_theme': 'warm-sand'});
    await ThemeController.instance.load();
    expect(ThemeController.instance.currentId, 'warm-sand');

    // ensureAppDataEpoch 的重置路径就是 sp.clear()。
    await (await SharedPreferences.getInstance()).clear();
    await ThemeController.instance.load();
    expect(ThemeController.instance.currentId, 'daylight');
    expect(AppColors.palette.id, 'daylight');
  });

  test('主题偏好不进入服务端同步载荷', () async {
    final map = await Settings.toSyncMap();
    expect(map.containsKey('app_theme'), isFalse);
    expect(Settings.syncKeys.contains('app_theme'), isFalse);
  });

  test('resetForTest 复位调色板', () {
    ThemeController.instance.select(AppPalette.warmSand);
    ThemeController.instance.resetForTest();
    expect(ThemeController.instance.currentId, 'daylight');
    expect(AppColors.palette.id, 'daylight');
  });
}
