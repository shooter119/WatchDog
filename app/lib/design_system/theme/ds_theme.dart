import 'package:flutter/material.dart';

import '../tokens/ds_colors.dart';
import '../tokens/ds_typography.dart';

/// 挂载于 [ThemeData.extensions] 的 Design System v3.0 主题扩展。
@immutable
class DsTheme extends ThemeExtension<DsTheme> {
  const DsTheme({
    required this.brightness,
    required this.colors,
    this.typography = DsTypography.standard,
  });

  final Brightness brightness;
  final DsColors colors;
  final DsTypography typography;

  /// 昼白主题扩展实例
  static const DsTheme daylight = DsTheme(
    brightness: Brightness.light,
    colors: DsColors.daylight,
  );

  /// 暗曜主题扩展实例
  static const DsTheme night = DsTheme(
    brightness: Brightness.dark,
    colors: DsColors.night,
  );

  /// 根据亮度返回对应主题扩展实例。
  factory DsTheme.fromBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? night : daylight;

  /// 若当前子树未注入 [DsTheme]，返回 `null`。
  static DsTheme? maybeOf(BuildContext context) =>
      Theme.of(context).extension<DsTheme>();

  /// 从最近的 [Theme] 中读取 [DsTheme]；若未注入则立即抛出带排查指引的 [FlutterError]。
  static DsTheme of(BuildContext context) {
    final theme = maybeOf(context);
    if (theme != null) return theme;
    throw FlutterError.fromParts(<DiagnosticsNode>[
      ErrorSummary('当前 BuildContext 所在的 Theme 未注入 DsTheme 扩展。'),
      ErrorDescription(
        '请确保祖先 MaterialApp 或局部 Theme 使用了 buildCommandTheme(brightness)，'
        '或在弹窗/路由中显式透传了包含 DsTheme 的 ThemeData。',
      ),
      ErrorHint('若调用方允许缺失主题扩展，请改用 DsTheme.maybeOf(context)。'),
    ]);
  }

  @override
  DsTheme copyWith({
    Brightness? brightness,
    DsColors? colors,
    DsTypography? typography,
  }) {
    return DsTheme(
      brightness: brightness ?? this.brightness,
      colors: colors ?? this.colors,
      typography: typography ?? this.typography,
    );
  }

  @override
  DsTheme lerp(covariant ThemeExtension<DsTheme>? other, double t) {
    if (other is! DsTheme) return this;
    if (identical(this, other) || t <= 0.0) return this;
    if (t >= 1.0) return other;
    return DsTheme(
      brightness: t < 0.5 ? brightness : other.brightness,
      colors: DsColors.lerp(colors, other.colors, t),
      typography: DsTypography.lerp(typography, other.typography, t),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DsTheme &&
        other.brightness == brightness &&
        other.colors == colors &&
        other.typography == typography;
  }

  @override
  int get hashCode => Object.hash(brightness, colors, typography);
}

/// 便捷访问扩展：`context.ds`。
extension DsThemeBuildContext on BuildContext {
  DsTheme get ds => DsTheme.of(this);
}
