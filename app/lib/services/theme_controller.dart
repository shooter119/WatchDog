import 'package:flutter/foundation.dart';

import '../theme/app_palette.dart';
import '../theme/app_widgets.dart';
import 'settings.dart';

/// 主题控制器：调色板切换、持久化与重建通知。
///
/// 约定：
/// 1. `AppColors.use` 只允许本类调用，保证 `AppColors` 与 `buildAppTheme()`
///    永远来自同一个 palette 实例。
/// 2. `select` 的顺序固定为 `use → notify → 持久化`：先让界面在同一帧读到
///    新色，写 prefs 失败时也不回退颜色（偏好丢失可接受，闪回不可接受）。
/// 3. `load` 永不抛异常：启动链路上它失败只应表现为"用默认配色"，不能
///    阻断 App 启动，也不能被误记成数据纪元重置错误。
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const Duration loadTimeout = Duration(milliseconds: 800);

  AppPalette _current = AppPalette.daylight;

  AppPalette get current => _current;

  String get currentId => _current.id;

  /// 启动时读取本机偏好；任何异常都回落默认方案。
  /// 在 `runApp` 之前调用，避免首帧用默认色再闪一次。
  Future<void> load() async {
    try {
      final id = await Settings.appThemeId.timeout(loadTimeout);
      _apply(AppPalette.byId(id));
    } catch (error) {
      debugPrint('ThemeController.load failed: $error');
      _apply(AppPalette.daylight);
    }
  }

  /// 用户显式切换：立即生效并异步落库。
  void select(AppPalette palette) {
    if (palette.id == _current.id) return;
    _apply(palette);
    notifyListeners();
    _persist(palette.id);
  }

  /// 测试复位：静态调色板不能跨用例泄漏。
  @visibleForTesting
  void resetForTest() {
    _current = AppPalette.daylight;
    AppColors.reset();
  }

  void _apply(AppPalette palette) {
    _current = palette;
    AppColors.use(palette);
  }

  Future<void> _persist(String id) async {
    try {
      await Settings.setAppThemeId(id);
    } catch (error) {
      // 配色偏好属于本机体验项，写失败只影响下次启动的默认值。
      debugPrint('ThemeController.persist failed: $error');
    }
  }
}
