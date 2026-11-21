import 'dart:async';

import 'package:flutter/material.dart';

import '../components/command_button.dart';
import '../components/command_nav_bar.dart';
import '../components/command_scaffold.dart';
import '../components/command_sheet.dart';
import '../components/metric_readout.dart';
import '../components/status_pill.dart';
import '../components/surface_card.dart';
import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_spacing.dart';
import 'preview_fixtures.dart';

/// Design System v3.0 现场监控（人员空呼安全看板）视觉原型。
class MonitorPreview extends StatefulWidget {
  const MonitorPreview({
    super.key,
    this.voiceState = DsVoiceState.idle,
    this.onSelectTab,
    this.onVoiceTap,
    this.liveTick = true,
  });

  final DsVoiceState voiceState;
  final ValueChanged<int>? onSelectTab;
  final VoidCallback? onVoiceTap;

  /// 为 `true` 时每秒本地递减倒计时；黄金截图或静态验证可传入 `false` 保持确定性。
  final bool liveTick;

  @override
  State<MonitorPreview> createState() => _MonitorPreviewState();
}

class _MonitorPreviewState extends State<MonitorPreview> {
  Timer? _timer;
  int _elapsedTickSeconds = 0;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(MonitorPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.liveTick != widget.liveTick) {
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _syncTicker() {
    if (!widget.liveTick) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedTickSeconds++;
      });
    });
  }

  void _showDemoNotice(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _openReportPressureSheet(
    BuildContext context,
    PreviewPersonMonitor person,
  ) {
    return showCommandSheet<void>(
      context: context,
      title: '${person.name} · 快速报压（演示）',
      subtitle: '${person.station} · ${person.group}',
      builder: (BuildContext sheetContext) {
        final sheetDs = sheetContext.ds;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MetricReadout(
              label: '当前记录压力',
              value: person.pressureMpa.toStringAsFixed(1),
              unit: 'MPa',
              status: person.status,
              colorByStatus: true,
              large: true,
            ),
            const SizedBox(height: DsSpacing.md),
            Text(
              '原型演示窗口：仅用于校验 56dp 触控区、弹窗主题继承及 130% 字体缩放，不会向真实服务提交报压数据。',
              style: sheetDs.typography.body.copyWith(
                color: sheetDs.colors.textSecondary,
              ),
            ),
          ],
        );
      },
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(),
        ),
        CommandButton(
          label: '确认演示',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () {
            Navigator.of(sheetContext).pop();
            _showDemoNotice(context, '已演示「${person.name}」报压确认');
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typography = ds.typography;
    final personnel = PreviewFixtures.personnel;
    final counts = PreviewFixtures.countByStatus(personnel);

    return CommandScaffold(
      bottomNavigationBar: CommandNavBar(
        selectedIndex: 1,
        voiceState: widget.voiceState,
        onSelectTab: widget.onSelectTab ?? (_) {},
        onVoiceTap: widget.onVoiceTap ??
            () => _showDemoNotice(context, '语音键已触发（原型演示）'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(DsSpacing.pageMargin),
        children: <Widget>[
          SurfaceCard(
            level: DsSurfaceLevel.outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      '在场 ${personnel.length} 人 · 风险分布',
                      style: typography.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      PreviewFixtures.incident.forceSummary,
                      style: typography.caption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.sm),
                Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.xs,
                  children: <Widget>[
                    StatusPill(
                      status: DsStatus.timeout,
                      label: '超时 ${counts[DsStatus.timeout] ?? 0}',
                    ),
                    StatusPill(
                      status: DsStatus.alarm,
                      label: '告警 ${counts[DsStatus.alarm] ?? 0}',
                    ),
                    StatusPill(
                      status: DsStatus.caution,
                      label: '注意 ${counts[DsStatus.caution] ?? 0}',
                    ),
                    StatusPill(
                      status: DsStatus.safe,
                      label: '安全 ${counts[DsStatus.safe] ?? 0}',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.cardGap),
          for (final person in personnel) ...<Widget>[
            _buildPersonCard(context, person),
            const SizedBox(height: DsSpacing.cardGap),
          ],
          const SizedBox(height: DsSpacing.xs),
          CommandButton(
            label: '全员撤离',
            variant: CommandButtonVariant.danger,
            size: CommandButtonSize.large,
            expanded: true,
            icon: Icons.campaign_rounded,
            confirmTitle: '确认下达全员撤离指令？',
            confirmMessage:
                '当前在场 ${personnel.length} 名内攻人员将收到最高级别撤离提示（M0 原型演示，无实际副作用）。',
            confirmActionLabel: '确认全员撤离',
            onPressed: () =>
                _showDemoNotice(context, '全员撤离二次确认演示完成（安全空操作）'),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonCard(BuildContext context, PreviewPersonMonitor person) {
    final ds = context.ds;
    final colors = ds.colors;
    final typography = ds.typography;
    final effectiveRemaining = person.remainingSeconds - _elapsedTickSeconds;
    final isOverdue = effectiveRemaining < 0;

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      accentStatus: person.status,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      person.name,
                      style: typography.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${person.station} · ${person.group} · ${person.entryTimeText} 入场',
                      style: typography.caption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              StatusPill(status: person.status),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: MetricReadout(
                  label: '当前压力',
                  value: person.pressureMpa.toStringAsFixed(1),
                  unit: 'MPa',
                  status: person.status,
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: MetricReadout(
                  label: isOverdue ? '已超时' : '预计剩余',
                  value: PreviewFixtures.formatCountdown(effectiveRemaining),
                  status: person.status,
                  colorByStatus: true,
                  large: true,
                  crossAxisAlignment: CrossAxisAlignment.end,
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: CommandButton(
                  label: '报压',
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.large,
                  icon: Icons.speed_rounded,
                  onPressed: () => _openReportPressureSheet(context, person),
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: CommandButton(
                  label: '出场',
                  variant: CommandButtonVariant.primary,
                  size: CommandButtonSize.large,
                  icon: Icons.logout_rounded,
                  onPressed: () => _showDemoNotice(
                    context,
                    '${person.name} 出场演示（仅预览，未修改状态）',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
