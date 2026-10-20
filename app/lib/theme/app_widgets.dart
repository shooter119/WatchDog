import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'nav_icons.dart';

/// ============================================================
/// 颜色门面 —— 界面只从这里取色
///
/// 具体色值由 [AppPalette] 提供；切换主题时整个调色板实例替换，
/// 因此页面代码无需感知主题，只需保证取色发生在 `build` 期间。
/// `AppColors.use` 只允许 `ThemeController` 调用；测试用 `reset()`。
/// ============================================================

class AppColors {
  AppColors._();

  static AppPalette _palette = AppPalette.daylight;

  static AppPalette get palette => _palette;

  static void use(AppPalette palette) => _palette = palette;

  /// 测试复位：静态状态不能跨用例泄漏。
  static void reset() => _palette = AppPalette.daylight;

  // 背景与表面
  static Color get background => _palette.background;
  static Color get surface => _palette.surface;
  static Color get surfaceSubtle => _palette.surfaceSubtle;
  static Color get avatarBackdrop => _palette.avatarBackdrop;
  static Color get border => _palette.border;

  // 文字
  static Color get textPrimary => _palette.textPrimary;
  static Color get textSecondary => _palette.textSecondary;
  static Color get textTertiary => _palette.textTertiary;

  // 状态（只承担状态语义，不做普通装饰）
  static Color get safe => _palette.safe;
  static Color get caution => _palette.caution;
  static Color get alarm => _palette.alarm;
  static Color get timeout => _palette.timeout;

  // 动作
  /// 语音入口（麦克风按钮、录音态），图形专用。
  static Color get voice => _palette.voice;
  static Color get actionPrimary => _palette.actionPrimary;

  /// 深色底（actionPrimary/voice/alarm）上的文字与图标。
  static Color get onPrimary => _palette.onPrimary;

  /// 整块状态色卡片上的倒计时与按钮文字。
  static Color get onStatus => _palette.onStatus;

  // 连接
  static Color get online => _palette.online;

  // 页面语义色：页面只引用这些 token，不自行散落颜色字面量
  static Color get noteInfo => _palette.noteInfo;
  static Color get noteWater => _palette.caution;
  static Color get noteNeutral => _palette.textTertiary;
  static Color get rankGold => _palette.rankGold;
  static Color get rankSilver => _palette.rankSilver;
  static Color get rankBronze => _palette.rankBronze;

  // 设置页深色大卡
  /// 深色大卡背景，与 actionPrimary 解耦：主色变陶土红时整卡不跟着变红。
  static Color get heroBackground => _palette.heroBackground;
  static Color get heroMuted => _palette.heroMuted;
  static Color get heroActive => _palette.heroActive;
  static Color get heroInactive => _palette.heroInactive;
  static Color get heroLabel => _palette.heroLabel;
  static Color get heroOnDark => _palette.heroOnDark;
  static Color get heroOnDarkBorder => _palette.heroOnDarkBorder;
  static Color get heroOnDarkRing => _palette.heroOnDarkRing;
  static Color get heroOnDarkRingFaint => _palette.heroOnDarkRingFaint;
}

/// 8px 基础间距系统（space.1~space.10）
class AppSpacing {
  AppSpacing._();
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s5 = 20.0;
  static const s6 = 24.0;
  static const s8 = 32.0;
  static const s10 = 40.0;
}

/// 圆角（radius.sm ~ radius.pill）
class AppRadius {
  AppRadius._();
  static const sm = 8.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 28.0;
  static const pill = 999.0;
}

/// 克制阴影（随主题走：暖砂用暖褐投影，避免冷黑压在暖纸上发脏）
class AppShadow {
  AppShadow._();
  static List<BoxShadow> get card => AppColors.palette.cardShadow;
  static List<BoxShadow> get float => AppColors.palette.floatShadow;
}

/// 字级层级（type.display.xl ~ type.caption）
class AppTextStyles {
  AppTextStyles._();
  static const displayXl = TextStyle(
    fontSize: 56,
    height: 1.0,
    fontWeight: FontWeight.w800,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const displayLg = TextStyle(
    fontSize: 44,
    height: 1.05,
    fontWeight: FontWeight.w800,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const h1 = TextStyle(
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w800,
  );
  static const h2 = TextStyle(
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w700,
  );
  static const bodyLg = TextStyle(
    fontSize: 17,
    height: 1.4,
    fontWeight: FontWeight.w600,
  );
  static const bodyMd = TextStyle(
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w500,
  );
  static const label = TextStyle(
    fontSize: 13,
    height: 1.35,
    fontWeight: FontWeight.w600,
  );
  static const caption = TextStyle(
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
  );
}

/// 状态 → 颜色/标签/图标 映射（normal=安全, warn=注意, alarm=报警, 其他=超时）
class EntryStatus {
  final Color color;
  final String label;
  final IconData icon;
  final bool danger;
  final Color fg; // 整块状态卡片上的前景色

  const EntryStatus(this.color, this.label, this.icon, this.danger, this.fg);

  static EntryStatus of(String status) => switch (status) {
    'normal' => EntryStatus(
      AppColors.safe,
      '安全',
      Icons.check_circle,
      false,
      AppColors.textPrimary,
    ),
    'warn' => EntryStatus(
      AppColors.caution,
      '注意',
      Icons.warning_amber_rounded,
      false,
      AppColors.textPrimary,
    ),
    'alarm' => EntryStatus(
      AppColors.alarm,
      '报警',
      Icons.notifications_active,
      true,
      AppColors.onStatus,
    ),
    _ => EntryStatus(
      AppColors.timeout,
      '超时',
      Icons.timer_off_outlined,
      true,
      AppColors.onStatus,
    ),
  };
}

/// 统一卡片容器（白色大圆角，克制阴影，少装饰）
class AppCard extends StatelessWidget {
  final Widget child;
  final Color? color;
  final BorderSide? side;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.color,
    this.side,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppRadius.md,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: AppShadow.card,
      ),
      child: Material(
        color: color ?? AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: side ?? BorderSide(color: AppColors.border, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 状态胶囊徽章（图标 + 文字，颜色与文字同时表意）
class StatusBadge extends StatelessWidget {
  final String status;
  final bool onColorCard; // 是否位于整块状态色卡片上（浅色底/深色底自适应）
  final double fontSize;
  final double? height; // 与同行控件对齐时指定固定高度（内容居中）

  const StatusBadge({
    super.key,
    required this.status,
    this.onColorCard = false,
    this.fontSize = 12,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final s = EntryStatus.of(status);
    final fg = onColorCard ? s.fg : s.color;
    final bg = onColorCard
        ? s.fg.withValues(alpha: 0.22)
        : s.color.withValues(alpha: 0.14);
    // 保留同行布局高度，缩小实际色块一点，避免状态胶囊视觉上显得臃肿。
    final visualHeight = height == null
        ? null
        : height! > 4
        ? height! - 4
        : height;
    return SizedBox(
      height: height,
      child: Center(
        child: Container(
          height: visualHeight,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(s.icon, size: 14, color: fg),
              const SizedBox(width: 4),
              Text(
                s.label,
                style: TextStyle(
                  color: fg,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分区小标题
class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  final Widget? inline; // 紧跟标题文字后的符号（如折叠指示箭头）

  const SectionTitle({
    super.key,
    required this.text,
    this.trailing,
    this.inline,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: AppColors.actionPrimary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                if (inline != null) ...[const SizedBox(width: 4), inline!],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 大号等宽倒计时数字（MM:SS，超时后按需显示文案）
class CountdownText extends StatelessWidget {
  final int ms;
  final Color? color;
  final double size;
  final String? timeoutText; // 超时后显示的替代文案

  const CountdownText({
    super.key,
    required this.ms,
    this.color,
    this.size = 56,
    this.timeoutText,
  });

  @override
  Widget build(BuildContext context) {
    // 默认色在 build 期解析，否则 const 默认参数会把主题色固化在编译期。
    final color = this.color ?? AppColors.textPrimary;
    if (ms <= 0 && timeoutText != null) {
      return Text(
        timeoutText!,
        style: TextStyle(
          fontSize: size,
          height: 1.0,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      );
    }
    final totalSec = (ms.clamp(0, 1 << 62)) ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    final text = h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return Text(
      text,
      style: TextStyle(
        fontSize: size,
        height: 1.0,
        fontWeight: FontWeight.w800,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color,
      ),
    );
  }
}

/// 扩散脉冲圆环（录音中、报警条目呼吸提示）
class PulseRing extends StatefulWidget {
  final Color color;
  final double ringSize;

  const PulseRing({super.key, required this.color, required this.ringSize});

  @override
  State<PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  bool _disableAnimations = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.of(context).disableAnimations;
    if (_disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_disableAnimations) {
      return Container(
        width: widget.ringSize * 0.925,
        height: widget.ringSize * 0.925,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: widget.color.withValues(alpha: 0.3),
            width: 2,
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        return Container(
          width: widget.ringSize * (0.85 + t * 0.15),
          height: widget.ringSize * (0.85 + t * 0.15),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.color.withValues(alpha: (1 - t) * 0.6),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}

/// 呼吸脉冲边框（危险条目低频闪烁，静态底色仍清晰可读）
class PulseGlow extends StatefulWidget {
  final Color color;
  final Widget child;
  final double radius;

  const PulseGlow({
    super.key,
    required this.color,
    required this.child,
    this.radius = AppRadius.lg,
  });

  @override
  State<PulseGlow> createState() => _PulseGlowState();
}

class _PulseGlowState extends State<PulseGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _disableAnimations = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.of(context).disableAnimations;
    if (_disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_disableAnimations) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
            color: widget.color.withValues(alpha: 0.7),
            width: 2,
          ),
        ),
        child: widget.child,
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
            color: widget.color.withValues(alpha: 0.35 + _c.value * 0.6),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.08 + _c.value * 0.2),
              blurRadius: 12 + _c.value * 14,
              spreadRadius: 1 + _c.value * 2,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// 连接状态：将连接质量与本轮同步状态分开表达，避免“尚未成功”被误解为实时在线。
/// 红/绿切换仍由 AppController.connectionLost 平滑判定（30 秒无成功才转红）。
class ConnectionStatus extends StatelessWidget {
  final bool connected;
  final bool localOnly;
  final bool syncing;
  final String? syncError;
  final VoidCallback? onRetry;

  const ConnectionStatus({
    super.key,
    required this.connected,
    this.localOnly = false,
    this.syncing = false,
    this.syncError,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isFailed = !localOnly && syncError != null && !syncing;
    final canRetry =
        !localOnly && !syncing && onRetry != null && (!connected || isFailed);
    final pillHeight = (MediaQuery.textScalerOf(context).scale(11) * 1.4 + 8)
        .clamp(24.0, 64.0)
        .toDouble();
    final (label, icon, color) = localOnly
        ? ('单机模式', Icons.phone_android_outlined, AppColors.textSecondary)
        : syncing
        ? ('同步中', Icons.cloud_sync_outlined, AppColors.textSecondary)
        : isFailed
        ? ('同步失败', Icons.cloud_off_outlined, AppColors.caution)
        : !connected
        ? ('已中断', Icons.cloud_off_outlined, AppColors.alarm)
        : ('已连接', Icons.cloud_done_outlined, AppColors.online);
    final inner = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    return Semantics(
      container: true,
      button: canRetry,
      enabled: canRetry,
      label: localOnly || syncError == null ? label : '$label：$syncError',
      hint: canRetry ? '点击重试同步' : null,
      child: Tooltip(
        message: canRetry ? '重试同步' : label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canRetry ? onRetry : null,
          child: ConstrainedBox(
            // 重试按钮保留48dp热区，胶囊固定顶部对齐，避免标题随点击区域错位。
            constraints: BoxConstraints(
              minWidth: 48,
              minHeight: canRetry ? 48 : pillHeight,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              widthFactor: 1,
              heightFactor: 1,
              child: Transform.translate(
                // 标题字面顶部有字体内置留白，视觉胶囊下移后与字面边缘对齐。
                offset: const Offset(0, 1),
                child: Container(
                  height: pillHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Center(child: inner),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 中央语音按钮：橙色圆形 + 白色麦克风（CustomPainter 绘制，DPR 无关）
/// - 默认：橙色圆 + 白麦克风
/// - 按下：轻微缩放(0.94) + 颜色加深（Transform 缩放，不引起布局跳动）
/// - 录音中：更深橙色 + 白麦克风 + 按钮内部短波形（不外扩、不越界）
/// - 处理中：中性灰圆 + 白色转圈（独立视觉态，禁用触发避免重复识别）
class VoiceButton extends StatefulWidget {
  final double size; // 视觉直径（默认 64，命中区域 size+8 ≥ 44）
  final bool recording;
  final bool processing; // 识别/确认中：独立视觉状态 + 禁止重复触发
  final bool enabled; // 额外禁用开关（保留原语义）
  final VoidCallback? onTap;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressEndCallback? onLongPressEnd;

  const VoiceButton({
    super.key,
    this.size = 64,
    this.recording = false,
    this.processing = false,
    this.enabled = true,
    this.onTap,
    this.onLongPressStart,
    this.onLongPressEnd,
  });

  @override
  State<VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends State<VoiceButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  bool _disableAnimations = false;

  // 录音态内部短波形动画（只影响绘制，不改变布局）；initState 中创建，
  // 避免懒加载在 dispose 阶段新建 Ticker 导致树停用后查询祖先崩溃
  late final AnimationController _wave;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.of(context).disableAnimations;
    _syncWave();
  }

  void _syncWave() {
    if (!mounted) return;
    if (widget.recording && !_disableAnimations) {
      if (!_wave.isAnimating) _wave.repeat();
    } else {
      _wave.stop();
    }
  }

  @override
  void didUpdateWidget(VoiceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.recording != oldWidget.recording) _syncWave();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  bool get _disabled => !widget.enabled || widget.processing;

  /// 按下/录音用更深橙色（由现有 voice 色派生，不新增设计系统颜色）
  Color get _fill {
    if (widget.processing) return AppColors.textTertiary;
    if (widget.recording) {
      return Color.lerp(AppColors.voice, Colors.black, 0.22)!;
    }
    if (_pressed) return Color.lerp(AppColors.voice, Colors.black, 0.16)!;
    return AppColors.voice;
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final hitSize = math.max(size + 8, 44.0);
    final glowColor = widget.processing
        ? AppColors.textTertiary.withValues(alpha: 0.2)
        : AppColors.voice.withValues(alpha: widget.recording ? 0 : 0.35);
    final hint = widget.processing
        ? '识别处理中，请稍候'
        : widget.recording
        ? '松开结束录音'
        : '长按开始录音，点击进入警情处置';
    return Semantics(
      label: widget.processing
          ? '识别处理中'
          : widget.recording
          ? '停止录音'
          : '语音录入',
      button: true,
      enabled: !_disabled,
      hint: hint,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _disabled ? null : widget.onTap,
        onLongPressStart: _disabled ? null : widget.onLongPressStart,
        onLongPressEnd: _disabled ? null : widget.onLongPressEnd,
        onTapDown: _disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: _disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: _disabled ? null : () => setState(() => _pressed = false),
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Center(
            child: SizedBox(
              width: size,
              height: size,
              child: AnimatedScale(
                scale: _pressed && !_disabled ? 0.94 : 1,
                duration: _disableAnimations
                    ? Duration.zero
                    : const Duration(milliseconds: 110),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  key: const Key('voice-button-surface'),
                  duration: _disableAnimations
                      ? Duration.zero
                      : const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _fill,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.55),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: glowColor,
                        blurRadius: widget.processing
                            ? 10
                            : widget.recording
                            ? 22
                            : 16,
                        spreadRadius: widget.processing
                            ? 1
                            : widget.recording
                            ? 4
                            : 2,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: widget.processing
                        ? const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            ),
                          )
                        : Stack(
                            alignment: Alignment.center,
                            children: [
                              if (widget.recording)
                                Positioned(
                                  top: size * 0.15,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: NavIcon(
                                      glyph: NavGlyph.voice,
                                      color: Colors.white,
                                      size: size * 0.32,
                                    ),
                                  ),
                                )
                              else
                                NavIcon(
                                  glyph: NavGlyph.voice,
                                  color: Colors.white,
                                  size: size * 0.46,
                                ),
                              if (widget.recording)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: size * 0.13,
                                  height: size * 0.26,
                                  child: AnimatedBuilder(
                                    animation: _wave,
                                    builder: (context, _) => CustomPaint(
                                      painter: _WavePainter(
                                        t: _wave.value,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 录音态按钮内部短波形：三根圆头竖条，高度随相位起伏，始终限制在按钮内
class _WavePainter extends CustomPainter {
  final double t; // 0..1 循环相位
  final Color color;

  const _WavePainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0; // 用圆角矩形绘制，strokeWidth 置 0
    const bars = 3;
    final barW = size.width * 0.07;
    final gap = size.width * 0.05;
    final totalW = bars * barW + (bars - 1) * gap;
    final maxH = size.height * 0.78;
    final bottomY = size.height * 0.9;
    var x = (size.width - totalW) / 2;
    for (var i = 0; i < bars; i++) {
      final phase = math.sin(2 * math.pi * t - i * 1.9);
      final h = maxH * (0.38 + 0.62 * (0.5 + 0.5 * phase));
      final bar = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, bottomY - h, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(bar, paint);
      x += barW + gap;
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}
