import 'package:flutter/widgets.dart';

/// Design System v3.0 动效时长与缓动曲线。
abstract final class DsMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve standard = Curves.easeInOutCubic;

  /// 尊重系统减弱动效设置，必要时返回 [Duration.zero]。
  static Duration resolve(BuildContext context, Duration duration) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
          ? Duration.zero
          : duration;
}
