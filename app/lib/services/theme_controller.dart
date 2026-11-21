import 'dart:async';

import 'package:flutter/material.dart';

import '../core/diagnostics/app_logger.dart';
import 'settings.dart';

/// 应用外观偏好（Design System v3.0：昼白 / 暗曜 / 跟随系统）。
///
/// 保留 `'night-tactical'` 持久化存储键，确保既有暗曜用户升级后无损继承。
enum AppThemePreference {
  daylight('daylight', ThemeMode.light),
  night('night-tactical', ThemeMode.dark),
  system('system', ThemeMode.system);

  const AppThemePreference(this.id, this.themeMode);

  /// 写入本地 SharedPreferences 的稳定存储键。
  final String id;

  /// 对应的 Flutter [ThemeMode]。
  final ThemeMode themeMode;

  /// 按存储 ID 解析偏好；未知或历史废弃 ID 回落至 [daylight]。
  static AppThemePreference fromId(String? id) => switch (id) {
    'night-tactical' => AppThemePreference.night,
    'system' => AppThemePreference.system,
    _ => AppThemePreference.daylight,
  };
}

/// 主题控制器：外观偏好切换、本机持久化及「暖砂 → 昼白」一次性平滑迁移。
///
/// 约定：
/// 1. 零旧版 `AppPalette`/`AppColors` 依赖，仅通过 [themeMode] 驱动 `MaterialApp`
///    双主题无缝切换，不销毁页面树、不丢失滚动位置与草稿。
/// 2. `select` 先更新内存态并通知监听者，再异步落盘；写盘失败不回退界面。
/// 3. `load` 永不抛异常：启动链路上失败仅降级为昼白并记录脱敏日志，不阻断首帧。
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const Duration loadTimeout = Duration(milliseconds: 800);

  /// 历史已退役的暖砂主题存储 ID，启动加载时自动迁移至昼白。
  static const String legacyWarmSandId = 'warm-sand';

  AppThemePreference _preference = AppThemePreference.daylight;
  bool _warmSandMigratedPending = false;

  AppThemePreference get preference => _preference;

  String get currentId => _preference.id;

  ThemeMode get themeMode => _preference.themeMode;

  /// 是否需要向用户展示一次性「暖砂 → 昼白」平滑迁移提示。
  bool get warmSandMigratedPending => _warmSandMigratedPending;

  /// 启动时读取本机偏好；若命中历史 `'warm-sand'` 则自动改写为 `'daylight'`，
  /// 且在未展示过迁移提示时将 [warmSandMigratedPending] 置为 `true`。
  Future<void> load() async {
    try {
      final raw = await Settings.rawAppThemeId.timeout(loadTimeout);
      if (raw == legacyWarmSandId) {
        _preference = AppThemePreference.daylight;
        await Settings.setAppThemeId(
          AppThemePreference.daylight.id,
        ).timeout(loadTimeout);
        final shown = await Settings.warmSandMigratedNoticeShown.timeout(
          loadTimeout,
        );
        _warmSandMigratedPending = !shown;
      } else {
        final next = AppThemePreference.fromId(raw);
        _preference = next;
        _warmSandMigratedPending = false;
        if (raw != next.id) {
          await Settings.setAppThemeId(next.id).timeout(loadTimeout);
        }
      }
    } catch (error) {
      AppLogger.error('ThemeController.load failed', tag: 'theme', error: error);
      _preference = AppThemePreference.daylight;
      _warmSandMigratedPending = false;
    }
    notifyListeners();
  }

  /// 用户显式切换偏好：立即生效并异步落库。
  void select(AppThemePreference preference) {
    if (preference == _preference) return;
    _preference = preference;
    notifyListeners();
    unawaited(_persist(preference.id));
  }

  /// 按存储 ID 切换偏好（供设置页回调直接绑定）。
  void selectById(String id) => select(AppThemePreference.fromId(id));

  /// 消费「暖砂 → 昼白」一次性迁移提示，并持久化已展示标记。
  Future<void> consumeWarmSandMigrationNotice() async {
    if (!_warmSandMigratedPending) return;
    _warmSandMigratedPending = false;
    notifyListeners();
    try {
      await Settings.setWarmSandMigratedNoticeShown(true);
    } catch (error) {
      AppLogger.error(
        'ThemeController.consumeWarmSandMigrationNotice failed',
        tag: 'theme',
        error: error,
      );
    }
  }

  /// 测试复位：防止跨用例泄漏状态。
  @visibleForTesting
  void resetForTest() {
    _preference = AppThemePreference.daylight;
    _warmSandMigratedPending = false;
  }

  Future<void> _persist(String id) async {
    try {
      await Settings.setAppThemeId(id);
    } catch (error) {
      // 配色偏好属于本机体验项，写失败只影响下次启动的默认值。
      AppLogger.error(
        'ThemeController.persist failed',
        tag: 'theme',
        error: error,
      );
    }
  }
}
