import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'nav_icons.dart';

/// ============================================================
/// 设计 Token —— 高可视亮色 High-Vis Light（UI 规范 V0.1）
/// ============================================================

class AppColors {
  AppColors._();

  // 背景与表面
  static const background = Color(0xFFF2F4F7); // color.background.primary
  static const surface = Color(0xFFFFFFFF); // color.surface.primary
  static const surfaceSubtle = Color(0xFFE8ECF1); // color.surface.subtle
  static const border = Color(0xFFD7DDE5); // color.border.default

  // 文字
  static const textPrimary = Color(0xFF111111); // color.text.primary
  static const textSecondary = Color(0xFF4B5563); // color.text.secondary
  static const textTertiary = Color(0xFF6B7280); // color.text.tertiary

  // 状态（只承担状态语义，不做普通装饰）
  static const safe = Color(0xFF32C943); // color.status.safe
  static const caution = Color(0xFFFFB000); // color.status.caution
  static const alarm = Color(0xFFF5222D); // color.status.alarm
  static const timeout = Color(0xFFC90016); // color.status.timeout

  // 动作
  static const voice = Color(0xFFFF9500); // color.action.voice
  static const actionPrimary = Color(0xFF111111); // color.action.primary
  static const onStatus = Color(0xFFFFFFFF); // 红色卡片上的倒计时与按钮文字

  // 连接
  static const online = Color(0xFF20A83A); // color.connection.online
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

/// 克制阴影
class AppShadow {
  AppShadow._();
  static const card = [
    BoxShadow(color: Color(0x14111111), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const float = [
    BoxShadow(color: Color(0x29111111), blurRadius: 16, offset: Offset(0, 6)),
  ];
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
    'normal' => const EntryStatus(
      AppColors.safe,
      '安全',
      Icons.check_circle,
      false,
      AppColors.textPrimary,
    ),
    'warn' => const EntryStatus(
      AppColors.caution,
      '注意',
      Icons.warning_amber_rounded,
      false,
      AppColors.textPrimary,
    ),
    'alarm' => const EntryStatus(
      AppColors.alarm,
      '报警',
      Icons.notifications_active,
      true,
      AppColors.onStatus,
    ),
    _ => const EntryStatus(
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
          side: side ?? const BorderSide(color: AppColors.border, width: 1),
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
    return Container(
      height: height,
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
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: AppColors.actionPrimary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          if (inline != null) ...[const SizedBox(width: 4), inline!],
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 大号等宽倒计时数字（MM:SS，超时后按需显示文案）
class CountdownText extends StatelessWidget {
  final int ms;
  final Color color;
  final double size;
  final String? timeoutText; // 超时后显示的替代文案

  const CountdownText({
    super.key,
    required this.ms,
    this.color = AppColors.textPrimary,
    this.size = 56,
    this.timeoutText,
  });

  @override
  Widget build(BuildContext context) {
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
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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

/// 连接状态：同步中显示橙色云图标 + 「连接中」；正常显示绿色云图标 + 「已连接」；断线显示红色云图标 + 「已中断」，点击可重试
class ConnectionStatus extends StatelessWidget {
  final bool syncing;
  final bool offline;
  final VoidCallback? onRetry;

  const ConnectionStatus({
    super.key,
    required this.syncing,
    required this.offline,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final Widget inner;
    if (syncing) {
      inner = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_sync_outlined, size: 16, color: AppColors.voice),
          SizedBox(width: 6),
          Text(
            '连接中',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    } else if (offline) {
      inner = const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 16, color: AppColors.alarm),
              SizedBox(width: 6),
              Text(
                '已中断',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Text(
            '当前使用本地数据 · 点击重试',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
        ],
      );
    } else {
      inner = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_done_outlined, size: 16, color: AppColors.online),
          SizedBox(width: 6),
          Text(
            '已连接',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }
    return GestureDetector(
      onTap: offline ? onRetry : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: inner,
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
    if (widget.recording) _wave.repeat();
  }

  @override
  void didUpdateWidget(VoiceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.recording && !oldWidget.recording) _wave.repeat();
    if (!widget.recording && oldWidget.recording) _wave.stop();
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
        : AppColors.voice.withValues(alpha: widget.recording ? 0.5 : 0.35);
    final hint = widget.processing
        ? '识别处理中，请稍候'
        : widget.recording
        ? '松开结束录音'
        : '长按开始录音，点击进入语音页';
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
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  key: const Key('voice-button-surface'),
                  duration: const Duration(milliseconds: 140),
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
