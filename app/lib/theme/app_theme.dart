import 'package:flutter/material.dart';

import 'app_widgets.dart';

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.actionPrimary,
    brightness: Brightness.light,
    surface: AppColors.surface,
  ).copyWith(
    primary: AppColors.actionPrimary,
    onPrimary: Colors.white,
    secondary: AppColors.caution,
    onSecondary: AppColors.textPrimary,
    onSurface: AppColors.textPrimary,
    surface: AppColors.surface,
    surfaceContainerHighest: AppColors.surfaceSubtle,
    outline: AppColors.border,
  );

  return ThemeData(
    useMaterial3: true,
    splashFactory: InkRipple.splashFactory,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'PingFang SC',
    fontFamilyFallback: const ['Noto Sans CJK SC', 'Microsoft YaHei'],
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w800),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AppColors.textPrimary,
      unselectedLabelColor: AppColors.textTertiary,
      indicatorColor: AppColors.actionPrimary,
      dividerColor: AppColors.border,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      unselectedLabelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      hintStyle: TextStyle(color: AppColors.textTertiary, fontSize: 13),
      prefixIconColor: AppColors.textTertiary,
      suffixIconColor: AppColors.textTertiary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.actionPrimary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.actionPrimary,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.actionPrimary,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.actionPrimary,
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surface,
      titleTextStyle: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
      contentTextStyle: TextStyle(color: AppColors.textSecondary, fontSize: 15, height: 1.4),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.actionPrimary),
  );
}
