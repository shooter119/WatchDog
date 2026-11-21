import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/theme_controller.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeController.instance.resetForTest();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
  });

  test('默认使用昼白方案与 ThemeMode.light', () {
    expect(ThemeController.instance.preference, AppThemePreference.daylight);
    expect(ThemeController.instance.currentId, 'daylight');
    expect(ThemeController.instance.themeMode, ThemeMode.light);
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
  });

  test('load 保留已有暗曜存储键 night-tactical 并映射 ThemeMode.dark', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_theme': 'night-tactical',
    });
    await ThemeController.instance.load();

    expect(ThemeController.instance.preference, AppThemePreference.night);
    expect(ThemeController.instance.currentId, 'night-tactical');
    expect(ThemeController.instance.themeMode, ThemeMode.dark);
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
    expect(await Settings.appThemeId, 'night-tactical');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_theme'), 'night-tactical');
  });

  test('load 支持 system 偏好并映射 ThemeMode.system', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_theme': 'system',
    });
    await ThemeController.instance.load();

    expect(ThemeController.instance.preference, AppThemePreference.system);
    expect(ThemeController.instance.currentId, 'system');
    expect(ThemeController.instance.themeMode, ThemeMode.system);
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
    expect(await Settings.appThemeId, 'system');
  });

  test('load 遇到历史 warm-sand 自动持久化为 daylight 并仅首次置位迁移提示', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_theme': 'warm-sand',
    });
    await ThemeController.instance.load();

    expect(ThemeController.instance.preference, AppThemePreference.daylight);
    expect(ThemeController.instance.currentId, 'daylight');
    expect(ThemeController.instance.themeMode, ThemeMode.light);
    expect(ThemeController.instance.warmSandMigratedPending, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_theme'), 'daylight');
    expect(await Settings.warmSandMigratedNoticeShown, isFalse);

    await ThemeController.instance.consumeWarmSandMigrationNotice();
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
    expect(await Settings.warmSandMigratedNoticeShown, isTrue);

    // 即使再次遇到历史值，已展示过提示后也不再复弹。
    await prefs.setString('app_theme', 'warm-sand');
    await ThemeController.instance.load();
    expect(ThemeController.instance.currentId, 'daylight');
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
  });

  test('load 把非法值归一化为昼白且不误弹暖砂迁移提示', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_theme': 'neon',
    });
    await ThemeController.instance.load();

    expect(ThemeController.instance.currentId, 'daylight');
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
    expect(await Settings.appThemeId, 'daylight');
  });

  test('select 与 selectById 立即生效、只通知一次并异步落库', () async {
    var notifications = 0;
    void listener() => notifications++;
    ThemeController.instance.addListener(listener);
    addTearDown(() => ThemeController.instance.removeListener(listener));

    ThemeController.instance.select(AppThemePreference.night);
    expect(ThemeController.instance.currentId, 'night-tactical');
    expect(ThemeController.instance.themeMode, ThemeMode.dark);
    expect(notifications, 1);

    await Future<void>.delayed(Duration.zero);
    expect(await Settings.appThemeId, 'night-tactical');

    ThemeController.instance.selectById('system');
    expect(ThemeController.instance.currentId, 'system');
    expect(ThemeController.instance.themeMode, ThemeMode.system);
    expect(notifications, 2);

    await Future<void>.delayed(Duration.zero);
    expect(await Settings.appThemeId, 'system');
  });

  test('重复选择同一方案不通知', () {
    var notifications = 0;
    void listener() => notifications++;
    ThemeController.instance.addListener(listener);
    addTearDown(() => ThemeController.instance.removeListener(listener));

    ThemeController.instance.select(AppThemePreference.daylight);
    expect(notifications, 0);
  });

  test('数据纪元清空 prefs 后回落默认昼白', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_theme': 'night-tactical',
    });
    await ThemeController.instance.load();
    expect(ThemeController.instance.currentId, 'night-tactical');

    await (await SharedPreferences.getInstance()).clear();
    await ThemeController.instance.load();
    expect(ThemeController.instance.currentId, 'daylight');
    expect(ThemeController.instance.themeMode, ThemeMode.light);
  });

  test('主题与迁移提示键均不进入服务端同步载荷', () async {
    final map = await Settings.toSyncMap();
    expect(map.containsKey('app_theme'), isFalse);
    expect(map.containsKey('app_theme_warm_sand_migrated_v1'), isFalse);
    expect(Settings.syncKeys.contains('app_theme'), isFalse);
    expect(Settings.syncKeys.contains('app_theme_warm_sand_migrated_v1'), isFalse);
  });

  test('resetForTest 复位偏好与迁移提示状态', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_theme': 'warm-sand',
    });
    await ThemeController.instance.load();
    expect(ThemeController.instance.warmSandMigratedPending, isTrue);

    ThemeController.instance.select(AppThemePreference.night);
    ThemeController.instance.resetForTest();
    expect(ThemeController.instance.currentId, 'daylight');
    expect(ThemeController.instance.themeMode, ThemeMode.light);
    expect(ThemeController.instance.warmSandMigratedPending, isFalse);
  });
}
