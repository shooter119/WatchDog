import 'package:flutter/foundation.dart';

/// 全局重构演进特性开关（编译期默认 + 调试态预览覆写）。
///
/// 在 M2 ~ M3g 阶段，`WATCHDOG_NEW_SHELL` 默认为 `false`，确保默认构建
/// 100% 沿用既有外壳与业务链路；开发者与测试可通过
/// `--dart-define=WATCHDOG_NEW_SHELL=true` 或调试态覆写预览 Design System v3.0
/// 新外壳。
abstract final class AppFeatureFlags {
  /// 编译期新外壳默认开关（`--dart-define=WATCHDOG_NEW_SHELL=true` 启用）。
  static const bool newShellDefault = bool.fromEnvironment(
    'WATCHDOG_NEW_SHELL',
    defaultValue: false,
  );

  /// 是否允许在运行期暴露调试预览入口（正式包编译期常量为 `false`）。
  static const bool debugPreviewEnabled = kDebugMode;

  static bool? _debugNewShellOverride;

  /// 当前生效的新外壳开关值（仅 Debug 模式允许运行期覆写）。
  static bool get useNewShell =>
      (kDebugMode && _debugNewShellOverride != null)
          ? _debugNewShellOverride!
          : newShellDefault;

  /// 解析最终是否启用新外壳；显式入参 [override] 优先级最高（便于测试注入）。
  static bool resolveUseNewShell({bool? override}) => override ?? useNewShell;

  /// 仅在 Debug 模式下设置新外壳运行期预览覆写；传 `null` 恢复编译期默认值。
  static void setDebugNewShellOverride(bool? value) {
    if (!kDebugMode) return;
    _debugNewShellOverride = value;
  }

  /// 测试清理：重置全部运行期调试覆写，避免跨用例污染。
  @visibleForTesting
  static void resetForTesting() {
    _debugNewShellOverride = null;
  }
}
