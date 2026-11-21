import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';
import 'command_button.dart';

enum _PlaceholderMode { loading, empty, error }

/// Design System v3.0 状态占位组件（加载骨架 / 空状态 / 错误重试）。
///
/// `.loading()` 脉冲动画受 `MediaQuery.maybeDisableAnimationsOf(context)` 控制，
/// 关闭动画时不启动 Ticker，确保无障碍兼容与测试 `pumpAndSettle()` 安全完成。
class StatePlaceholder extends StatelessWidget {
  const StatePlaceholder.loading({
    super.key,
    String? message,
    this.barCount = 3,
    this.padding,
  })  : _mode = _PlaceholderMode.loading,
        _message = message,
        icon = null,
        title = null,
        detail = null,
        actionLabel = null,
        onAction = null;

  const StatePlaceholder.empty({
    super.key,
    this.icon = Icons.inbox_outlined,
    required String message,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.padding,
  })  : _mode = _PlaceholderMode.empty,
        _message = message,
        title = null,
        barCount = 0;

  const StatePlaceholder.error({
    super.key,
    this.icon = Icons.error_outline_rounded,
    this.title = '加载失败',
    required String reason,
    String retryLabel = '重试',
    VoidCallback? onRetry,
    this.padding,
  })  : _mode = _PlaceholderMode.error,
        _message = reason,
        detail = null,
        actionLabel = retryLabel,
        onAction = onRetry,
        barCount = 0;

  final _PlaceholderMode _mode;
  final IconData? icon;
  final String? title;
  final String? _message;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final int barCount;
  final EdgeInsetsGeometry? padding;

  String? get message => _message;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    final Widget inner = switch (_mode) {
      _PlaceholderMode.loading => _SkeletonBars(
          barCount: barCount,
          message: message,
        ),
      _PlaceholderMode.empty => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                shape: BoxShape.circle,
                border: Border.all(color: colors.border, width: 1),
              ),
              child: Icon(
                icon ?? Icons.inbox_outlined,
                size: DsSizes.iconLg,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: DsSpacing.md),
            Text(
              message ?? '',
              textAlign: TextAlign.center,
              style: typo.title.copyWith(color: colors.textPrimary),
            ),
            if (detail != null && detail!.isNotEmpty) ...<Widget>[
              const SizedBox(height: DsSpacing.xs),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: typo.body.copyWith(color: colors.textSecondary),
              ),
            ],
            if (actionLabel != null &&
                actionLabel!.isNotEmpty &&
                onAction != null) ...<Widget>[
              const SizedBox(height: DsSpacing.lg),
              CommandButton(
                label: actionLabel!,
                onPressed: onAction,
                variant: CommandButtonVariant.secondary,
                size: CommandButtonSize.standard,
              ),
            ],
          ],
        ),
      _PlaceholderMode.error => Builder(
          builder: (BuildContext context) {
            final alarmPair = colors.statusColors(DsStatus.alarm);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: alarmPair.pillBg,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: alarmPair.fill.withValues(alpha: 0.28),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    icon ?? Icons.error_outline_rounded,
                    size: DsSizes.iconLg,
                    color: alarmPair.text,
                  ),
                ),
                if (title != null && title!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: DsSpacing.md),
                  Text(
                    title!,
                    textAlign: TextAlign.center,
                    style: typo.title.copyWith(color: colors.textPrimary),
                  ),
                ],
                const SizedBox(height: DsSpacing.xs),
                Text(
                  message ?? '',
                  textAlign: TextAlign.center,
                  style: typo.body.copyWith(color: colors.textSecondary),
                ),
                if (actionLabel != null &&
                    actionLabel!.isNotEmpty &&
                    onAction != null) ...<Widget>[
                  const SizedBox(height: DsSpacing.lg),
                  CommandButton(
                    label: actionLabel!,
                    onPressed: onAction,
                    variant: CommandButtonVariant.primary,
                    size: CommandButtonSize.standard,
                  ),
                ],
              ],
            );
          },
        ),
    };

    return Center(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(DsSpacing.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: inner,
        ),
      ),
    );
  }
}

class _SkeletonBars extends StatefulWidget {
  const _SkeletonBars({
    required this.barCount,
    this.message,
  });

  final int barCount;
  final String? message;

  @override
  State<_SkeletonBars> createState() => _SkeletonBarsState();
}

class _SkeletonBarsState extends State<_SkeletonBars>
    with SingleTickerProviderStateMixin {
  static const List<double> _widthFactors = <double>[0.52, 0.92, 0.74];

  late final AnimationController _controller;
  bool _animationsDisabled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimationState();
  }

  @override
  void didUpdateWidget(covariant _SkeletonBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimationState();
  }

  void _syncAnimationState() {
    final disabled = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _animationsDisabled = disabled;
    if (disabled) {
      if (_controller.isAnimating) {
        _controller.stop();
      }
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final count = widget.barCount < 0 ? 0 : widget.barCount;
    final Color highlight =
        Color.lerp(colors.surfaceMuted, colors.border, 0.6) ?? colors.border;

    return Semantics(
      label: widget.message ?? '正在加载',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final Color barColor = _animationsDisabled
              ? colors.surfaceMuted
              : (Color.lerp(colors.surfaceMuted, highlight, _controller.value) ??
                  colors.surfaceMuted);

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < count; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: DsSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: _widthFactors[i % _widthFactors.length],
                    child: Container(
                      height: i == 0 ? 18 : 14,
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: DsRadius.borderSm,
                      ),
                    ),
                  ),
                ),
              ],
              if (widget.message != null &&
                  widget.message!.isNotEmpty) ...<Widget>[
                if (count > 0) const SizedBox(height: DsSpacing.md),
                Text(
                  widget.message!,
                  textAlign: TextAlign.center,
                  style: ds.typography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
