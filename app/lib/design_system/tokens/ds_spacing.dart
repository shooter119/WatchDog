import 'package:flutter/widgets.dart';

/// Design System v3.0 4pt 空间栅格常量。
abstract final class DsSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;

  /// 页面左右外边距 (16dp)
  static const double pageMargin = lg;

  /// 卡片内边距 (16dp)
  static const double cardPadding = lg;

  /// 卡片纵向间距 (12dp)
  static const double cardGap = md;

  /// 常用页面水平留白
  static const EdgeInsets pageHorizontal = EdgeInsets.symmetric(
    horizontal: pageMargin,
  );

  /// 常用卡片四边留白
  static const EdgeInsets cardAll = EdgeInsets.all(cardPadding);
}
