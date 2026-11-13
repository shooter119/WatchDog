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
    this.brightness = Brightness.light,
    required this.id,
    required this.label,
    required this.background,
    required this.surface,
    required this.surfaceSubtle,
    required this.cautionSurface,
    required this.avatarBackdrop,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.safe,
    required this.caution,
    required this.alarm,
    required this.timeout,
    required this.safeText,
    required this.cautionText,
    required this.alarmText,
    required this.timeoutText,
    required this.destructive,
    required this.voice,
    required this.voicePressed,
    required this.noticeWarningBg,
    required this.noticeWarningFg,
    required this.actionPrimary,
    required this.onPrimary,
    required this.onStatus,
    required this.online,
    required this.noteInfo,
    required this.incidentFire,
    required this.incidentFireText,
    required this.incidentFireSurface,
    required this.incidentRescue,
    required this.incidentRescueText,
    required this.incidentRescueSurface,
    required this.incidentAid,
    required this.incidentAidText,
    required this.incidentAidSurface,
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

  /// 明暗：决定 ThemeData.brightness（系统控件、状态栏图标等随之切换）
  final Brightness brightness;

  /// 持久化标识：写入 SharedPreferences 的 `app_theme`
  final String id;

  /// 设置页展示名
  final String label;

  // 背景与表面
  final Color background;
  final Color surface;
  final Color surfaceSubtle;
  final Color cautionSurface;

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

  // 双通道状态文字（用于浅色底上的文字/数字，确保达到 WCAG AA 对比度）
  final Color safeText;
  final Color cautionText;
  final Color alarmText;
  final Color timeoutText;

  /// 破坏性操作确认按钮专用色（仅限模态确认弹窗的确认按钮）
  final Color destructive;

  /// 语音入口（麦克风按钮、录音态），图形专用
  final Color voice;

  /// 语音按钮按下态加深色
  final Color voicePressed;

  /// L5 通告条 warning 底色与文字色
  final Color noticeWarningBg;
  final Color noticeWarningFg;

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
  final Color incidentFire;
  final Color incidentFireText;
  final Color incidentFireSurface;
  final Color incidentRescue;
  final Color incidentRescueText;
  final Color incidentRescueSurface;
  final Color incidentAid;
  final Color incidentAidText;
  final Color incidentAidSurface;
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
  ///
  /// 预计算 WCAG 对比度：
  /// daylight 在 background #F2F4F7 上：safeText 4.55, cautionText 4.56, alarmText 5.87, timeoutText 9.09;
  /// white 在 alarm #DC2626 上 4.83, 在 timeout #7F1D1D 上 10.02, 在 destructive #B91C1C 上 6.47, 在 voice #F95700 上 3.29。
  /// warmSand 在 background #F7F5EF 上：safeText 5.85, cautionText 5.43, alarmText 6.19, timeoutText 12.17;
  /// alarm/timeout 亮度对比度 1.97 (daylight 2.07)。
  static const AppPalette daylight = AppPalette(
    id: 'daylight',
    label: '昼白',
    background: Color(0xFFF2F4F7),
    surface: Color(0xFFFFFFFF),
    surfaceSubtle: Color(0xFFE8ECF1),
    cautionSurface: Color(0xFFFEFCE8),
    avatarBackdrop: Color(0xFFDDF3F5),
    border: Color(0xFFD7DDE5),
    textPrimary: Color(0xFF111111),
    textSecondary: Color(0xFF4B5563),
    textTertiary: Color(0xFF6B7280),
    safe: Color(0xFF32C943),
    caution: Color(0xFFFFB000),
    alarm: Color(0xFFDC2626),
    timeout: Color(0xFF7F1D1D),
    safeText: Color(0xFF15803D),
    cautionText: Color(0xFFB45309),
    alarmText: Color(0xFFB91C1C),
    timeoutText: Color(0xFF7F1D1D),
    destructive: Color(0xFFB91C1C),
    voice: Color(0xFFF95700),
    voicePressed: Color(0xFFD44000),
    noticeWarningBg: Color(0xFFFEF3C7),
    noticeWarningFg: Color(0xFF92400E),
    actionPrimary: Color(0xFF111111),
    onPrimary: Color(0xFFFFFFFF),
    onStatus: Color(0xFFFFFFFF),
    online: Color(0xFF20A83A),
    noteInfo: Color(0xFF2F6FED),
    incidentFire: Color(0xFFDC2626),
    incidentFireText: Color(0xFFB91C1C),
    incidentFireSurface: Color(0xFFFEF2F2),
    incidentRescue: Color(0xFFD97706),
    incidentRescueText: Color(0xFFB45309),
    incidentRescueSurface: Color(0xFFFFFBEB),
    incidentAid: Color(0xFF0284C7),
    incidentAidText: Color(0xFF0369A1),
    incidentAidSurface: Color(0xFFF0F9FF),
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
      BoxShadow(
        color: Color(0x0F000000),
        blurRadius: 6,
        offset: Offset(0, 2),
      ),
    ],
    floatShadow: [
      BoxShadow(
        color: Color(0x1F000000),
        blurRadius: 12,
        offset: Offset(0, 4),
      ),
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
    cautionSurface: Color(0xFFFAF1D6),
    avatarBackdrop: Color(0xFFEDE6DA),
    border: Color(0xFFDCD6C8),
    textPrimary: Color(0xFF1F1E1D),
    textSecondary: Color(0xFF57544C),
    textTertiary: Color(0xFF6A665B),
    safe: Color(0xFF47975F),
    caution: Color(0xFFB37B1E),
    alarm: Color(0xFFB0241B),
    timeout: Color(0xFF5E140F),
    safeText: Color(0xFF2E6B3F),
    cautionText: Color(0xFF8A5A0E),
    alarmText: Color(0xFFB0241B),
    timeoutText: Color(0xFF5E140F),
    destructive: Color(0xFFB91C1C),
    voice: Color(0xFFC06242),
    voicePressed: Color(0xFFA04E33),
    noticeWarningBg: Color(0xFFF5E9CF),
    noticeWarningFg: Color(0xFF7A4708),
    actionPrimary: Color(0xFFB0543A),
    onPrimary: Color(0xFFFBF9F4),
    onStatus: Color(0xFFFBF9F4),
    online: Color(0xFF3A7A47),
    noteInfo: Color(0xFF3F6E8F),
    incidentFire: Color(0xFFB0241B),
    incidentFireText: Color(0xFF991B1B),
    incidentFireSurface: Color(0xFFFCF1EE),
    incidentRescue: Color(0xFFB4690E),
    incidentRescueText: Color(0xFF8A5A0E),
    incidentRescueSurface: Color(0xFFFAF1D6),
    incidentAid: Color(0xFF2B6CB0),
    incidentAidText: Color(0xFF1E4E8C),
    incidentAidSurface: Color(0xFFEEF4F8),
    rankGold: Color(0xFFB8860B),
    rankSilver: Color(0xFF8C8A82),
    rankBronze: Color(0xFF9A6B45),
    heroBackground: Color(0xFF111111),
    heroMuted: Color(0xFF9A958A),
    heroActive: Color(0xFFC5F4CC),
    heroInactive: Color(0xFFB8B4A8),
    heroLabel: Color(0xFF9A958A),
    heroOnDark: Color(0xFFFBF7F0),
    heroOnDarkBorder: Color(0x3DFBF7F0),
    heroOnDarkRing: Color(0x0AFBF7F0),
    heroOnDarkRingFaint: Color(0x08FBF7F0),
    cardShadow: [
      BoxShadow(
        color: Color(0x0E3D2E24),
        blurRadius: 6,
        offset: Offset(0, 2),
      ),
    ],
    floatShadow: [
      BoxShadow(
        color: Color(0x1A3D2E24),
        blurRadius: 12,
        offset: Offset(0, 4),
      ),
    ],
  );
}
