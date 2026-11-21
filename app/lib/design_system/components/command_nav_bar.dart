import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';

/// 中置语音指令键运行态。
enum DsVoiceState {
  /// 待命状态（空心麦克风图标）
  idle,

  /// 录音中（实心麦克风 + 外圈脉冲环）
  recording,

  /// 识别处理中（品牌蓝背景 + 白色进度环，屏蔽重复触发）
  processing,
}

/// 底部导航栏标签页描述模型。
@immutable
class CommandNavTab {
  const CommandNavTab({
    required this.label,
    required this.icon,
    this.activeIcon,
    this.badgeCount = 0,
    this.hasAlert = false,
  });

  final String label;
  final IconData icon;
  final IconData? activeIcon;
  final int badgeCount;
  final bool hasAlert;
}

/// Design System v3.0 底部导航栏（4 标签页 + 中置 64dp 凸起语音键）。
///
/// 根节点显式计入 [DsSizes.voiceProtrusion]（12dp）+ [DsSizes.navBarHeight]（64dp）
/// + 安全区底距，确保向上凸出的 12dp 圆形热区完全落在自身 `RenderBox` 命中范围内。
class CommandNavBar extends StatelessWidget {
  const CommandNavBar({
    super.key,
    this.tabs = defaultTabs,
    required this.selectedIndex,
    required this.onSelectTab,
    this.voiceState = DsVoiceState.idle,
    this.onVoiceTap,
    this.onVoiceLongPressStart,
    this.onVoiceLongPressEnd,
    this.onVoiceLongPressCancel,
  }) : assert(tabs.length == 4, 'CommandNavBar 必须配置 4 个标签页');

  static const List<CommandNavTab> defaultTabs = <CommandNavTab>[
    CommandNavTab(
      label: '指挥台',
      icon: Icons.space_dashboard_outlined,
      activeIcon: Icons.space_dashboard,
    ),
    CommandNavTab(
      label: '现场监控',
      icon: Icons.monitor_heart_outlined,
      activeIcon: Icons.monitor_heart,
    ),
    CommandNavTab(
      label: '智能辅助',
      icon: Icons.smart_toy_outlined,
      activeIcon: Icons.smart_toy,
    ),
    CommandNavTab(
      label: '我的',
      icon: Icons.person_outline,
      activeIcon: Icons.person,
    ),
  ];

  final List<CommandNavTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelectTab;
  final DsVoiceState voiceState;
  final VoidCallback? onVoiceTap;
  final GestureLongPressStartCallback? onVoiceLongPressStart;
  final GestureLongPressEndCallback? onVoiceLongPressEnd;
  final VoidCallback? onVoiceLongPressCancel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final bool isDark = ds.brightness == Brightness.dark;
    final double safeBottom = MediaQuery.paddingOf(context).bottom;
    final bool disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final bool isProcessing = voiceState == DsVoiceState.processing;

    final Widget voiceInner = switch (voiceState) {
      DsVoiceState.idle => Icon(
          Icons.mic_none_rounded,
          color: colors.onBrand,
          size: 28,
        ),
      DsVoiceState.recording => Icon(
          Icons.mic_rounded,
          color: colors.onBrand,
          size: 28,
        ),
      DsVoiceState.processing => SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            value: disableAnimations ? 0.72 : null,
            strokeWidth: 2.5,
            color: colors.onBrand,
          ),
        ),
    };

    final String voiceSemanticLabel = switch (voiceState) {
      DsVoiceState.idle => '语音指令，点击或长按说话',
      DsVoiceState.recording => '正在录音，松开结束',
      DsVoiceState.processing => '正在识别语音指令',
    };

    return SizedBox(
      height: DsSizes.voiceProtrusion + DsSizes.navBarHeight + safeBottom,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            right: 0,
            top: DsSizes.voiceProtrusion,
            bottom: 0,
            child: DecoratedBox(
              key: const Key('ds-nav-bar-surface'),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(color: colors.border, width: 1),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: safeBottom),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _NavTabCell(
                      tab: tabs[0],
                      index: 0,
                      selected: selectedIndex == 0,
                      onSelect: onSelectTab,
                    ),
                    _NavTabCell(
                      tab: tabs[1],
                      index: 1,
                      selected: selectedIndex == 1,
                      onSelect: onSelectTab,
                    ),
                    const SizedBox(width: DsSizes.voiceButton + DsSpacing.sm),
                    _NavTabCell(
                      tab: tabs[2],
                      index: 2,
                      selected: selectedIndex == 2,
                      onSelect: onSelectTab,
                    ),
                    _NavTabCell(
                      tab: tabs[3],
                      index: 3,
                      selected: selectedIndex == 3,
                      onSelect: onSelectTab,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: <Widget>[
                if (voiceState == DsVoiceState.recording)
                  IgnorePointer(
                    child: _VoicePulseRing(
                      color: colors.brand,
                      baseSize: DsSizes.voiceButton,
                    ),
                  ),
                Semantics(
                  button: true,
                  enabled: !isProcessing,
                  label: voiceSemanticLabel,
                  child: GestureDetector(
                    key: const Key('ds-nav-voice-button'),
                    behavior: HitTestBehavior.opaque,
                    onTap: isProcessing
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            onVoiceTap?.call();
                          },
                    onLongPressStart: isProcessing
                        ? null
                        : (LongPressStartDetails details) {
                            HapticFeedback.mediumImpact();
                            onVoiceLongPressStart?.call(details);
                          },
                    onLongPressEnd: isProcessing ? null : onVoiceLongPressEnd,
                    onLongPressCancel:
                        isProcessing ? null : onVoiceLongPressCancel,
                    child: Container(
                      width: DsSizes.voiceButton,
                      height: DsSizes.voiceButton,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.brand,
                        border: Border.all(
                          color: colors.surface,
                          width: 2.5,
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: colors.brand
                                .withValues(alpha: isDark ? 0.36 : 0.24),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(child: voiceInner),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTabCell extends StatelessWidget {
  const _NavTabCell({
    required this.tab,
    required this.index,
    required this.selected,
    required this.onSelect,
  });

  final CommandNavTab tab;
  final int index;
  final bool selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final Color fg = selected ? colors.brandText : colors.textSecondary;
    final IconData effectiveIcon =
        selected ? (tab.activeIcon ?? tab.icon) : tab.icon;

    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: tab.label,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: Key('ds-nav-tab-$index'),
            onTap: () {
              HapticFeedback.selectionClick();
              onSelect(index);
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Icon(
                      effectiveIcon,
                      size: DsSizes.iconLg,
                      color: fg,
                    ),
                    if (tab.badgeCount > 0)
                      Positioned(
                        top: -4,
                        right: -10,
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: colors.alarmFill,
                            borderRadius: DsRadius.borderPill,
                          ),
                          child: Center(
                            child: Text(
                              tab.badgeCount > 99
                                  ? '99+'
                                  : '${tab.badgeCount}',
                              style: typo.micro.copyWith(
                                fontSize: 10,
                                height: 1.1,
                                color: colors.onAlarm,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      )
                    else if (tab.hasAlert)
                      Positioned(
                        top: -2,
                        right: -4,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: colors.alarmFill,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: DsSpacing.xs),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      softWrap: false,
                      style: typo.micro.copyWith(
                        color: fg,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VoicePulseRing extends StatefulWidget {
  const _VoicePulseRing({
    required this.color,
    required this.baseSize,
  });

  final Color color;
  final double baseSize;

  @override
  State<_VoicePulseRing> createState() => _VoicePulseRingState();
}

class _VoicePulseRingState extends State<_VoicePulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _animationsDisabled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimationState();
  }

  @override
  void didUpdateWidget(covariant _VoicePulseRing oldWidget) {
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
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double maxExtent = widget.baseSize + 20;

    return SizedBox(
      width: widget.baseSize,
      height: widget.baseSize,
      child: OverflowBox(
        maxWidth: maxExtent,
        maxHeight: maxExtent,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            if (_animationsDisabled) {
              return Container(
                width: widget.baseSize + 12,
                height: widget.baseSize + 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.color.withValues(alpha: 0.32),
                    width: 2.5,
                  ),
                ),
              );
            }

            final double t = Curves.easeOut.transform(_controller.value);
            final double size = widget.baseSize + (20 * t);
            final double alpha = 0.40 * (1.0 - t);

            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: alpha),
              ),
            );
          },
        ),
      ),
    );
  }
}
