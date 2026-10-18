import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_widgets.dart';

/// 全局字体统一配置：中文优先 PingFang SC，缺失时依次回退
/// Noto Sans CJK SC（Android 常用）、Microsoft YaHei
class AppFonts {
  AppFonts._();
  static const String family = 'PingFang SC';
  static const List<String> fallback = ['Noto Sans CJK SC', 'Microsoft YaHei'];
}

ThemeData? _cachedTheme;
String? _cachedPaletteId;

/// 构建主题。
///
/// 调色板默认取 `AppColors.palette`（由 `ThemeController` 维护），也可显式
/// 传入用于测试/预览。`ThemeData` 与 [AppColors] 必须来自**同一个** palette
/// 实例，否则 `Theme.of(context)` 与直读 token 会出现两套颜色。
///
/// 结果按 palette.id 记忆化：`fromSeed` 与十余个子主题不该在每次重建时重跑。
ThemeData buildAppTheme([AppPalette? palette]) {
  final p = palette ?? AppColors.palette;
  if (_cachedTheme != null && _cachedPaletteId == p.id) return _cachedTheme!;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.actionPrimary,
        brightness: Brightness.light,
        surface: p.surface,
      ).copyWith(
        primary: p.actionPrimary,
        onPrimary: p.onPrimary,
        secondary: p.caution,
        onSecondary: p.textPrimary,
        onSurface: p.textPrimary,
        surface: p.surface,
        surfaceContainerHighest: p.surfaceSubtle,
        outline: p.border,
      );

  final theme = ThemeData(
    useMaterial3: true,
    splashFactory: InkRipple.splashFactory,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    fontFamily: AppFonts.family,
    fontFamilyFallback: AppFonts.fallback,
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.textPrimary,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: p.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w800,
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.textPrimary,
      unselectedLabelColor: p.textTertiary,
      indicatorColor: p.actionPrimary,
      dividerColor: p.border,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: p.textSecondary),
      hintStyle: TextStyle(color: p.textTertiary, fontSize: 13),
      prefixIconColor: p.textTertiary,
      suffixIconColor: p.textTertiary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: p.actionPrimary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.actionPrimary,
        foregroundColor: p.onPrimary,
        minimumSize: const Size(48, 52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(
          fontFamily: AppFonts.family,
          fontFamilyFallback: AppFonts.fallback,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.actionPrimary,
        textStyle: const TextStyle(
          fontFamily: AppFonts.family,
          fontFamilyFallback: AppFonts.fallback,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.actionPrimary,
      contentTextStyle: TextStyle(color: p.onPrimary),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      titleTextStyle: TextStyle(
        color: p.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: TextStyle(
        color: p.textSecondary,
        fontSize: 15,
        height: 1.4,
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.actionPrimary),
  );

  _cachedTheme = theme;
  _cachedPaletteId = p.id;
  return theme;
}
