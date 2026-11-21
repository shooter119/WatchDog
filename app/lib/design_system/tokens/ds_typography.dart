import 'package:flutter/widgets.dart';

/// Design System v3.0 字体排版体系（系统字体 + 等宽数字）。
///
/// 全部基础样式均不写死 `color`（保持 `null`），以便组件内继承
/// `DefaultTextStyle` 的前景色，并在需要时由调用方显式着色。
@immutable
class DsTypography {
  const DsTypography({
    this.display = _defaultDisplay,
    this.headline = _defaultHeadline,
    this.title = _defaultTitle,
    this.body = _defaultBody,
    this.caption = _defaultCaption,
    this.micro = _defaultMicro,
    this.metric = _defaultMetric,
    this.metricLarge = _defaultMetricLarge,
  });

  /// 系统优先中文字体族（不额外打包字体文件）
  static const String fontFamily = 'PingFang SC';

  /// 跨平台系统汉字回退链
  static const List<String> fontFamilyFallback = <String>[
    'Noto Sans CJK SC',
    'Microsoft YaHei',
  ];

  /// 默认字阶实例
  static const DsTypography standard = DsTypography();

  static const TextStyle _defaultDisplay = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 28,
    height: 34 / 28,
    fontWeight: FontWeight.w700,
  );

  static const TextStyle _defaultHeadline = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 20,
    height: 26 / 20,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle _defaultTitle = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 16,
    height: 22 / 16,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle _defaultBody = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle _defaultCaption = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle _defaultMicro = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle _defaultMetric = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w600,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  static const TextStyle _defaultMetricLarge = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 32,
    height: 38 / 32,
    fontWeight: FontWeight.w600,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 28 / 34 / 700 — 页面核心主标题
  final TextStyle display;

  /// 20 / 26 / 600 — 顶栏与分区标题
  final TextStyle headline;

  /// 16 / 22 / 600 — 卡片标题与操作按钮文字
  final TextStyle title;

  /// 14 / 20 / 400 — 常规正文
  final TextStyle body;

  /// 12 / 16 / 400 — 辅助说明与时间戳
  final TextStyle caption;

  /// 11 / 14 / 500 — 微型标签与角标
  final TextStyle micro;

  /// 22 / 28 / 600 + tabularFigures — 压力与计时关键读数
  final TextStyle metric;

  /// 32 / 38 / 600 + tabularFigures — 焦点倒计时与大号关键读数
  final TextStyle metricLarge;

  /// 为任意文本样式附加等宽数字 (`tabularFigures`) 特性。
  static TextStyle tabular(TextStyle style) {
    const tabularFeature = FontFeature.tabularFigures();
    final existing = style.fontFeatures;
    if (existing != null && existing.contains(tabularFeature)) {
      return style;
    }
    return style.copyWith(
      fontFeatures: <FontFeature>[...?existing, tabularFeature],
    );
  }

  /// 等宽数字正文（适合表格式计数与对齐时间）
  TextStyle get bodyTabular => tabular(body);

  /// 等宽数字说明文字（适合时间轴分钟与状态持续时间）
  TextStyle get captionTabular => tabular(caption);

  static DsTypography lerp(DsTypography a, DsTypography b, double t) {
    if (identical(a, b) || t <= 0.0) return a;
    if (t >= 1.0) return b;
    return DsTypography(
      display: TextStyle.lerp(a.display, b.display, t)!,
      headline: TextStyle.lerp(a.headline, b.headline, t)!,
      title: TextStyle.lerp(a.title, b.title, t)!,
      body: TextStyle.lerp(a.body, b.body, t)!,
      caption: TextStyle.lerp(a.caption, b.caption, t)!,
      micro: TextStyle.lerp(a.micro, b.micro, t)!,
      metric: TextStyle.lerp(a.metric, b.metric, t)!,
      metricLarge: TextStyle.lerp(a.metricLarge, b.metricLarge, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DsTypography &&
        other.display == display &&
        other.headline == headline &&
        other.title == title &&
        other.body == body &&
        other.caption == caption &&
        other.micro == micro &&
        other.metric == metric &&
        other.metricLarge == metricLarge;
  }

  @override
  int get hashCode => Object.hash(
        display,
        headline,
        title,
        body,
        caption,
        micro,
        metric,
        metricLarge,
      );
}
