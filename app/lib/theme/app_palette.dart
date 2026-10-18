import 'package:flutter/material.dart';

/// ============================================================
/// 调色板 —— 一套配色的全部颜色与阴影
///
/// 界面只引用 `AppColors` 门面，不直接引用本文件；`AppPalette` 是
/// 不可变值对象，切换主题时整个实例替换，避免逐字段修改留下半新半旧。
///
/// 两套方案：
/// - `daylight` 昼白：现行高可视亮色，冷灰底 + 高饱和状态色
/// - `warmSand` 暖砂：暖纸底 + 陶土红，低饱和但保留状态语义
///
/// 纪律：
/// 1. `daylight` 是默认值，色值必须与历史 `AppColors` 常量逐字相等，
///    并由此保证默认外观零变化（`app_palette_test.dart` 会锁死）。
/// 2. 状态色（safe/caution/alarm/timeout）只允许"同色相、调亮度"，
///    不允许在暖砂方案里改变红=报警、黄=提醒、绿=安全的语义。
/// 3. 图形专用色（voice/onStatus/avatarBackdrop/heroBackground）单独注释，
///    调麦克风颜色时不要顺手改状态色。
/// ============================================================
class AppPalette {
  const AppPalette({
    required this.id,
    required this.label,
    required this.background,
    required this.surface,
    required this.surfaceSubtle,
    required this.avatarBackdrop,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.safe,
    required this.caution,
    required this.alarm,
    required this.timeout,
    required this.voice,
    required this.actionPrimary,
    required this.onPrimary,
    required this.onStatus,
    required this.online,
    required this.noteInfo,
    required this.rankGold,
    required this.rankSilver,
    required this.rankBronze,
    required this.heroMuted,
    required this.heroActive,
    required this.heroInactive,
    required this.heroLabel,
    required this.heroOnDark,
    required this.heroOnDarkBorder,
    required this.heroOnDarkRing,
    required this.heroOnDarkRingFaint,
    required this.heroBackground,
    required this.cardShadow,
    required this.floatShadow,
  });

  /// 持久化标识：写入 SharedPreferences 的 `app_theme`
  final String id;

  /// 设置页展示名
  final String label;

  // 背景与表面
  final Color background;
  final Color surface;
  final Color surfaceSubtle;

  /// 水元素头像的承载底色（头像位图本身不随主题变化）
  final Color avatarBackdrop;

  final Color border;

  // 文字
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  // 状态（只承担状态语义，不做普通装饰）
  final Color safe;
  final Color caution;
  final Color alarm;
  final Color timeout;

  /// 语音入口（麦克风按钮、录音态），图形专用
  final Color voice;

  // 动作
  final Color actionPrimary;

  /// 深色底（actionPrimary/voice/alarm）上的文字与图标
  final Color onPrimary;

  /// 整块状态色卡片上的前景色
  final Color onStatus;

  // 连接
  final Color online;

  // 页面语义色
  final Color noteInfo;
  final Color rankGold;
  final Color rankSilver;
  final Color rankBronze;

  // 设置页深色大卡
  /// 深色大卡的背景（与 actionPrimary 解耦，避免主色变红时整卡变红）
  final Color heroBackground;
  final Color heroMuted;
  final Color heroActive;
  final Color heroInactive;
  final Color heroLabel;
  final Color heroOnDark;
  final Color heroOnDarkBorder;
  final Color heroOnDarkRing;
  final Color heroOnDarkRingFaint;

  // 阴影
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> floatShadow;

  /// 未知或空 id 一律回落默认方案，避免脏数据导致无主题。
  static AppPalette byId(String? id) {
    for (final palette in values) {
      if (palette.id == id) return palette;
    }
    return daylight;
  }

  static const List<AppPalette> values = [daylight, warmSand];

  /// 昼白：现行高可视亮色（默认）
  static const AppPalette daylight = AppPalette(
    id: 'daylight',
    label: '昼白',
    background: Color(0xFFF2F4F7),
    surface: Color(0xFFFFFFFF),
    surfaceSubtle: Color(0xFFE8ECF1),
    avatarBackdrop: Color(0xFFDDF3F5),
    border: Color(0xFFD7DDE5),
    textPrimary: Color(0xFF111111),
    textSecondary: Color(0xFF4B5563),
    textTertiary: Color(0xFF6B7280),
    safe: Color(0xFF32C943),
    caution: Color(0xFFFFB000),
    alarm: Color(0xFFF5222D),
    timeout: Color(0xFFC90016),
    voice: Color(0xFFFF9500),
    actionPrimary: Color(0xFF111111),
    onPrimary: Color(0xFFFFFFFF),
    onStatus: Color(0xFFFFFFFF),
    online: Color(0xFF20A83A),
    noteInfo: Color(0xFF2F6FED),
    rankGold: Color(0xFFF5B301),
    rankSilver: Color(0xFF9AA5B1),
    rankBronze: Color(0xFFB77B4A),
    heroBackground: Color(0xFF111111),
    heroMuted: Color(0xFFA9B1BD),
    heroActive: Color(0xFFC5F4CC),
    heroInactive: Color(0xFFBFC7D2),
    heroLabel: Color(0xFF9BA5B2),
    heroOnDark: Color(0xFFFFFFFF),
    heroOnDarkBorder: Color(0x3DFFFFFF),
    heroOnDarkRing: Color(0x0AFFFFFF),
    heroOnDarkRingFaint: Color(0x08FFFFFF),
    cardShadow: [
      BoxShadow(color: Color(0x14111111), blurRadius: 8, offset: Offset(0, 2)),
    ],
    floatShadow: [
      BoxShadow(color: Color(0x29111111), blurRadius: 16, offset: Offset(0, 6)),
    ],
  );

  /// 暖砂：暖纸底 + 陶土红
  ///
  /// 状态色取值窗口：卡片前景 `textPrimary` 需 ≥4.5:1，同时自身作为
  /// 图标/文字落在 surface 上需 ≥3:1。safe/caution 因此比"深绿/深棕"
  /// 亮一档，避免重蹈"安全卡倒计时看不清"。
  static const AppPalette warmSand = AppPalette(
    id: 'warm-sand',
    label: '暖砂',
    background: Color(0xFFF7F5EF),
    surface: Color(0xFFFFFFFF),
    surfaceSubtle: Color(0xFFEFECE3),
    avatarBackdrop: Color(0xFFEDE6DA),
    border: Color(0xFFDCD6C8),
    textPrimary: Color(0xFF1F1E1D),
    textSecondary: Color(0xFF57544C),
    textTertiary: Color(0xFF6A665B),
    safe: Color(0xFF47975F),
    caution: Color(0xFFB37B1E),
    alarm: Color(0xFFB0241B),
    timeout: Color(0xFF8E1F17),
    voice: Color(0xFFC06242),
    actionPrimary: Color(0xFFB0543A),
    onPrimary: Color(0xFFFBF9F4),
    onStatus: Color(0xFFFBF9F4),
    online: Color(0xFF3A7A47),
    noteInfo: Color(0xFF3F6E8F),
    rankGold: Color(0xFFB8860B),
    rankSilver: Color(0xFF8C8A82),
    rankBronze: Color(0xFF9A6B45),
    heroBackground: Color(0xFF262624),
    heroMuted: Color(0xFF9A958A),
    heroActive: Color(0xFFC5F4CC),
    heroInactive: Color(0xFFB8B4A8),
    heroLabel: Color(0xFF9A958A),
    heroOnDark: Color(0xFFFBF7F0),
    heroOnDarkBorder: Color(0x3DFBF7F0),
    heroOnDarkRing: Color(0x0AFBF7F0),
    heroOnDarkRingFaint: Color(0x08FBF7F0),
    cardShadow: [
      BoxShadow(color: Color(0x0F3D2E24), blurRadius: 8, offset: Offset(0, 2)),
    ],
    floatShadow: [
      BoxShadow(color: Color(0x243D2E24), blurRadius: 16, offset: Offset(0, 6)),
    ],
  );
}
