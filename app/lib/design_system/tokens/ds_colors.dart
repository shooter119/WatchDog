import 'package:flutter/material.dart';

/// 现场风险与态势语义等级。
enum DsStatus {
  /// 安全 / 正常余量
  safe,

  /// 注意 / 预警
  caution,

  /// 告警 / 危险
  alarm,

  /// 超时 / 失联 / 极危
  timeout,

  /// 中性 / 未激活 / 待命
  neutral,
}

/// 单个语义状态对应的双通道色彩组（填充通道 + 文字通道 + 读数通道）。
@immutable
class StatusColorPair {
  const StatusColorPair({
    required this.fill,
    required this.onFill,
    required this.text,
    required this.metricText,
    required this.pillBg,
  });

  /// 实心填充色（左色条、实心徽章、图标背景等）
  final Color fill;

  /// 实心填充之上的前景色（满足 ≥ 4.5:1 对比度）
  final Color onFill;

  /// 状态文本与图标色（在表面及 12% 淡底胶囊上 ≥ 4.5:1）
  final Color text;

  /// 高可读数字读数色（在 canvas 与 surface 上 ≥ 7.0:1）
  final Color metricText;

  /// 胶囊背景色（语义状态为 fill 的 12% 透明叠加；neutral 为 surfaceMuted）
  final Color pillBg;

  static StatusColorPair lerp(
    StatusColorPair a,
    StatusColorPair b,
    double t,
  ) {
    if (identical(a, b) || t <= 0.0) return a;
    if (t >= 1.0) return b;
    return StatusColorPair(
      fill: Color.lerp(a.fill, b.fill, t)!,
      onFill: Color.lerp(a.onFill, b.onFill, t)!,
      text: Color.lerp(a.text, b.text, t)!,
      metricText: Color.lerp(a.metricText, b.metricText, t)!,
      pillBg: Color.lerp(a.pillBg, b.pillBg, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StatusColorPair &&
        other.fill == fill &&
        other.onFill == onFill &&
        other.text == text &&
        other.metricText == metricText &&
        other.pillBg == pillBg;
  }

  @override
  int get hashCode => Object.hash(fill, onFill, text, metricText, pillBg);
}

/// Design System v3.0 语义色板（昼白 / 暗曜双主题）。
///
/// 所有色值均通过 WCAG 2.1 对比度校验：
/// - 文本与状态文字对所有表面及 12% 胶囊底色 ≥ 4.5:1
/// - 关键数字读数 (`metric*`) 对 `canvas` 与 `surface` ≥ 7.0:1 (AAA)
@immutable
class DsColors {
  const DsColors({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.brand,
    required this.brandText,
    required this.onBrand,
    required this.safeFill,
    required this.onSafe,
    required this.safeText,
    required this.metricSafe,
    required this.cautionFill,
    required this.onCaution,
    required this.cautionText,
    required this.metricCaution,
    required this.alarmFill,
    required this.onAlarm,
    required this.alarmText,
    required this.metricAlarm,
    required this.timeoutFill,
    required this.onTimeout,
    required this.timeoutText,
    required this.metricTimeout,
    required this.neutralFill,
    required this.neutralOnFill,
    required this.neutralText,
    required this.neutralPillBg,
  });

  final Brightness brightness;

  // 表面层级
  final Color canvas;
  final Color surface;
  final Color surfaceMuted;
  final Color border;

  // 文字层级
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  // 品牌与主操作
  final Color brand;
  final Color brandText;
  final Color onBrand;

  // 安全态
  final Color safeFill;
  final Color onSafe;
  final Color safeText;
  final Color metricSafe;

  // 注意/预警态
  final Color cautionFill;
  final Color onCaution;
  final Color cautionText;
  final Color metricCaution;

  // 告警态
  final Color alarmFill;
  final Color onAlarm;
  final Color alarmText;
  final Color metricAlarm;

  // 超时/极危态
  final Color timeoutFill;
  final Color onTimeout;
  final Color timeoutText;
  final Color metricTimeout;

  // 中性态
  final Color neutralFill;
  final Color neutralOnFill;
  final Color neutralText;
  final Color neutralPillBg;

  /// 昼白主题（强日光高对比环境）
  static const DsColors daylight = DsColors(
    brightness: Brightness.light,
    canvas: Color(0xFFF4F6F9),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFEEF2F6),
    border: Color(0xFFDCE3EC),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    textTertiary: Color(0xFF5C708B),
    brand: Color(0xFF1D4ED8),
    brandText: Color(0xFF1D4ED8),
    onBrand: Color(0xFFFFFFFF),
    safeFill: Color(0xFF16A34A),
    onSafe: Color(0xFF0F172A),
    safeText: Color(0xFF136D34),
    metricSafe: Color(0xFF10602E),
    cautionFill: Color(0xFFF97316),
    onCaution: Color(0xFF0F172A),
    cautionText: Color(0xFFB83B0A),
    metricCaution: Color(0xFF8F2D08),
    alarmFill: Color(0xFFDC2626),
    onAlarm: Color(0xFFFFFFFF),
    alarmText: Color(0xFFB91C1C),
    metricAlarm: Color(0xFFA51919),
    timeoutFill: Color(0xFF7F1D1D),
    onTimeout: Color(0xFFFFFFFF),
    timeoutText: Color(0xFF7F1D1D),
    metricTimeout: Color(0xFF7F1D1D),
    neutralFill: Color(0xFFDCE3EC),
    neutralOnFill: Color(0xFF0F172A),
    neutralText: Color(0xFF475569),
    neutralPillBg: Color(0xFFEEF2F6),
  );

  /// 暗曜主题（夜间/浓烟低光防眩目环境）
  static const DsColors night = DsColors(
    brightness: Brightness.dark,
    canvas: Color(0xFF0B0F14),
    surface: Color(0xFF131A22),
    surfaceMuted: Color(0xFF1C2633),
    border: Color(0xFF263344),
    textPrimary: Color(0xFFE6EDF5),
    textSecondary: Color(0xFF9AA8B8),
    textTertiary: Color(0xFF7E8DA2),
    brand: Color(0xFF3366FF),
    brandText: Color(0xFF5B8CFF),
    onBrand: Color(0xFFFFFFFF),
    safeFill: Color(0xFF22C55E),
    onSafe: Color(0xFF0B0F14),
    safeText: Color(0xFF4ADE80),
    metricSafe: Color(0xFF4ADE80),
    cautionFill: Color(0xFFF97316),
    onCaution: Color(0xFF0B0F14),
    cautionText: Color(0xFFFB923C),
    metricCaution: Color(0xFFFDBA74),
    alarmFill: Color(0xFFDC2626),
    onAlarm: Color(0xFFFFFFFF),
    alarmText: Color(0xFFF87171),
    metricAlarm: Color(0xFFF98080),
    timeoutFill: Color(0xFF881616),
    onTimeout: Color(0xFFFFFFFF),
    timeoutText: Color(0xFFFCA5A5),
    metricTimeout: Color(0xFFFCA5A5),
    neutralFill: Color(0xFF263344),
    neutralOnFill: Color(0xFFE6EDF5),
    neutralText: Color(0xFF9AA8B8),
    neutralPillBg: Color(0xFF1C2633),
  );

  /// 按系统/预览亮度解析对应语义色板。
  static DsColors of(Brightness brightness) =>
      brightness == Brightness.dark ? night : daylight;

  /// 按语义等级获取双通道配色组。
  StatusColorPair statusColors(DsStatus status) {
    switch (status) {
      case DsStatus.safe:
        return StatusColorPair(
          fill: safeFill,
          onFill: onSafe,
          text: safeText,
          metricText: metricSafe,
          pillBg: safeFill.withValues(alpha: 0.12),
        );
      case DsStatus.caution:
        return StatusColorPair(
          fill: cautionFill,
          onFill: onCaution,
          text: cautionText,
          metricText: metricCaution,
          pillBg: cautionFill.withValues(alpha: 0.12),
        );
      case DsStatus.alarm:
        return StatusColorPair(
          fill: alarmFill,
          onFill: onAlarm,
          text: alarmText,
          metricText: metricAlarm,
          pillBg: alarmFill.withValues(alpha: 0.12),
        );
      case DsStatus.timeout:
        return StatusColorPair(
          fill: timeoutFill,
          onFill: onTimeout,
          text: timeoutText,
          metricText: metricTimeout,
          pillBg: timeoutFill.withValues(alpha: 0.12),
        );
      case DsStatus.neutral:
        return StatusColorPair(
          fill: neutralFill,
          onFill: neutralOnFill,
          text: neutralText,
          metricText: textPrimary,
          pillBg: neutralPillBg,
        );
    }
  }

  /// 主题切换插值（用于 ThemeExtension.lerp）。
  static DsColors lerp(DsColors a, DsColors b, double t) {
    if (identical(a, b) || t <= 0.0) return a;
    if (t >= 1.0) return b;
    return DsColors(
      brightness: t < 0.5 ? a.brightness : b.brightness,
      canvas: Color.lerp(a.canvas, b.canvas, t)!,
      surface: Color.lerp(a.surface, b.surface, t)!,
      surfaceMuted: Color.lerp(a.surfaceMuted, b.surfaceMuted, t)!,
      border: Color.lerp(a.border, b.border, t)!,
      textPrimary: Color.lerp(a.textPrimary, b.textPrimary, t)!,
      textSecondary: Color.lerp(a.textSecondary, b.textSecondary, t)!,
      textTertiary: Color.lerp(a.textTertiary, b.textTertiary, t)!,
      brand: Color.lerp(a.brand, b.brand, t)!,
      brandText: Color.lerp(a.brandText, b.brandText, t)!,
      onBrand: Color.lerp(a.onBrand, b.onBrand, t)!,
      safeFill: Color.lerp(a.safeFill, b.safeFill, t)!,
      onSafe: Color.lerp(a.onSafe, b.onSafe, t)!,
      safeText: Color.lerp(a.safeText, b.safeText, t)!,
      metricSafe: Color.lerp(a.metricSafe, b.metricSafe, t)!,
      cautionFill: Color.lerp(a.cautionFill, b.cautionFill, t)!,
      onCaution: Color.lerp(a.onCaution, b.onCaution, t)!,
      cautionText: Color.lerp(a.cautionText, b.cautionText, t)!,
      metricCaution: Color.lerp(a.metricCaution, b.metricCaution, t)!,
      alarmFill: Color.lerp(a.alarmFill, b.alarmFill, t)!,
      onAlarm: Color.lerp(a.onAlarm, b.onAlarm, t)!,
      alarmText: Color.lerp(a.alarmText, b.alarmText, t)!,
      metricAlarm: Color.lerp(a.metricAlarm, b.metricAlarm, t)!,
      timeoutFill: Color.lerp(a.timeoutFill, b.timeoutFill, t)!,
      onTimeout: Color.lerp(a.onTimeout, b.onTimeout, t)!,
      timeoutText: Color.lerp(a.timeoutText, b.timeoutText, t)!,
      metricTimeout: Color.lerp(a.metricTimeout, b.metricTimeout, t)!,
      neutralFill: Color.lerp(a.neutralFill, b.neutralFill, t)!,
      neutralOnFill: Color.lerp(a.neutralOnFill, b.neutralOnFill, t)!,
      neutralText: Color.lerp(a.neutralText, b.neutralText, t)!,
      neutralPillBg: Color.lerp(a.neutralPillBg, b.neutralPillBg, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DsColors &&
        other.brightness == brightness &&
        other.canvas == canvas &&
        other.surface == surface &&
        other.surfaceMuted == surfaceMuted &&
        other.border == border &&
        other.textPrimary == textPrimary &&
        other.textSecondary == textSecondary &&
        other.textTertiary == textTertiary &&
        other.brand == brand &&
        other.brandText == brandText &&
        other.onBrand == onBrand &&
        other.safeFill == safeFill &&
        other.onSafe == onSafe &&
        other.safeText == safeText &&
        other.metricSafe == metricSafe &&
        other.cautionFill == cautionFill &&
        other.onCaution == onCaution &&
        other.cautionText == cautionText &&
        other.metricCaution == metricCaution &&
        other.alarmFill == alarmFill &&
        other.onAlarm == onAlarm &&
        other.alarmText == alarmText &&
        other.metricAlarm == metricAlarm &&
        other.timeoutFill == timeoutFill &&
        other.onTimeout == onTimeout &&
        other.timeoutText == timeoutText &&
        other.metricTimeout == metricTimeout &&
        other.neutralFill == neutralFill &&
        other.neutralOnFill == neutralOnFill &&
        other.neutralText == neutralText &&
        other.neutralPillBg == neutralPillBg;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
        brightness,
        canvas,
        surface,
        surfaceMuted,
        border,
        textPrimary,
        textSecondary,
        textTertiary,
        brand,
        brandText,
        onBrand,
        safeFill,
        onSafe,
        safeText,
        metricSafe,
        cautionFill,
        onCaution,
        cautionText,
        metricCaution,
        alarmFill,
        onAlarm,
        alarmText,
        metricAlarm,
        timeoutFill,
        onTimeout,
        timeoutText,
        metricTimeout,
        neutralFill,
        neutralOnFill,
        neutralText,
        neutralPillBg,
      ]);
}
