import 'package:flutter/foundation.dart';

/// 全局应用运行特性开关。
///
/// M4 已完成 Design System v3.0 新外壳全量切换，旧版 5-Tab 外壳已彻底清退；
/// 仅保留调试组件库预览的编译期门控（正式包为 `false`）。
abstract final class AppFeatureFlags {
  /// 是否允许在运行期暴露调试预览入口（正式包编译期常量为 `false`）。
  static const bool debugPreviewEnabled = kDebugMode;

  /// 测试清理占位（保持测试清理接口兼容）。
  @visibleForTesting
  static void resetForTesting() {}
}
