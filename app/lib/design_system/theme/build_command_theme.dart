import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/ds_colors.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_typography.dart';
import 'ds_theme.dart';

ThemeData? _cachedLightTheme;
ThemeData? _cachedDarkTheme;

/// 构建 Design System v3.0 指挥台/现场监控主题（Material 3 + [DsTheme]）。
ThemeData buildCommandTheme(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return _cachedDarkTheme ??= _createCommandTheme(Brightness.dark);
  }
  return _cachedLightTheme ??= _createCommandTheme(Brightness.light);
}

ThemeData _createCommandTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colors = DsColors.of(brightness);
  const typography = DsTypography.standard;
  final dsTheme = DsTheme.fromBrightness(brightness);

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: colors.brand,
    onPrimary: colors.onBrand,
    primaryContainer: Color.alphaBlend(
      colors.brand.withValues(alpha: 0.12),
      colors.surface,
    ),
    onPrimaryContainer: colors.brandText,
    secondary: colors.brand,
    onSecondary: colors.onBrand,
    secondaryContainer: colors.surfaceMuted,
    onSecondaryContainer: colors.textPrimary,
    tertiary: colors.cautionFill,
    onTertiary: colors.onCaution,
    tertiaryContainer: Color.alphaBlend(
      colors.cautionFill.withValues(alpha: 0.12),
      colors.surface,
    ),
    onTertiaryContainer: colors.cautionText,
    error: colors.alarmFill,
    onError: colors.onAlarm,
    errorContainer: Color.alphaBlend(
      colors.alarmFill.withValues(alpha: 0.12),
      colors.surface,
    ),
    onErrorContainer: colors.alarmText,
    surface: colors.surface,
    onSurface: colors.textPrimary,
    onSurfaceVariant: colors.textSecondary,
    surfaceContainerLowest: colors.surface,
    surfaceContainerLow: colors.canvas,
    surfaceContainer: colors.canvas,
    surfaceContainerHigh: colors.surfaceMuted,
    surfaceContainerHighest: colors.surfaceMuted,
    outline: colors.border,
    outlineVariant: colors.border,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    surfaceTint: Colors.transparent,
    inverseSurface: isDark ? DsColors.daylight.surface : DsColors.night.surface,
    onInverseSurface:
        isDark ? DsColors.daylight.textPrimary : DsColors.night.textPrimary,
    inversePrimary: isDark ? DsColors.daylight.brand : DsColors.night.brandText,
  );

  final textTheme = TextTheme(
    displayLarge: typography.display.copyWith(color: colors.textPrimary),
    headlineMedium: typography.headline.copyWith(color: colors.textPrimary),
    headlineSmall: typography.headline.copyWith(color: colors.textPrimary),
    titleLarge: typography.title.copyWith(color: colors.textPrimary),
    titleMedium: typography.title.copyWith(color: colors.textPrimary),
    titleSmall: typography.body.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: typography.body.copyWith(color: colors.textPrimary),
    bodyMedium: typography.body.copyWith(color: colors.textPrimary),
    bodySmall: typography.caption.copyWith(color: colors.textSecondary),
    labelLarge: typography.title.copyWith(color: colors.textPrimary),
    labelMedium: typography.caption.copyWith(
      color: colors.textSecondary,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: typography.micro.copyWith(color: colors.textSecondary),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    fontFamily: DsTypography.fontFamily,
    fontFamilyFallback: DsTypography.fontFamilyFallback,
    textTheme: textTheme,
    scaffoldBackgroundColor: colors.canvas,
    canvasColor: colors.surface,
    dividerColor: colors.border,
    dividerTheme: DividerThemeData(
      color: colors.border,
      thickness: 1,
      space: 1,
    ),
    iconTheme: IconThemeData(color: colors.textPrimary),
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: colors.brandText,
      selectionColor: colors.brand.withValues(alpha: 0.24),
      selectionHandleColor: colors.brandText,
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: colors.surface,
      foregroundColor: colors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: typography.headline.copyWith(color: colors.textPrimary),
      systemOverlayStyle:
          isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      modalBackgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      dragHandleColor: colors.border,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(DsRadius.xl)),
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[dsTheme],
  );
}
