import 'package:flutter/widgets.dart';

/// Design System v3.0 圆角体系。
abstract final class DsRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;
  static const double pill = 999;

  /// 兼容别名，等同于 [pill]
  static const double full = pill;

  static const BorderRadius borderSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius borderMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius borderLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius borderXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius borderPill =
      BorderRadius.all(Radius.circular(pill));
}
