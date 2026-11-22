import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/entry.dart';
import '../state/alert_clock_store.dart';
import '../state/monitor_store.dart';
import 'widgets/monitor_risk_bar.dart';

/// 在场人员详情页：实时 32dp 等宽倒计时 + 气瓶参数网格 + 语音转写 + 二次确认出场。
class EntryDetailScreen extends StatefulWidget {
  const EntryDetailScreen({
    super.key,
    required this.monitorStore,
    required this.alertClockStore,
    required this.entryId,
    this.nowMs,
  });

  final MonitorStore monitorStore;
  final AlertClockStore alertClockStore;
  final String entryId;
  final int Function()? nowMs;

  @override
  State<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<EntryDetailScreen> {
  bool _exiting = false;

  int _currentNowMs() =>
      widget.nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  String _formatClockTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<void> _executeExit(Entry entry) async {
    if (_exiting) return;
    setState(() => _exiting = true);
    try {
      await widget.monitorStore.markExited(entry.id, expectedVersion: entry.version);
    } catch (error) {
      if (mounted) {
        setState(() => _exiting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('出场登记失败：$error')),
        );
      }
      return;
    }

    try {
      await widget.monitorStore.recordExitActionLog(entry);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已登记出场，但火场日志写入失败：$error')),
        );
      }
    }

    widget.alertClockStore.speak('${entry.name} 已登记出火场');
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.monitorStore,
        widget.alertClockStore.clockTick,
      ]),
      builder: (BuildContext context, Widget? _) {
        final entry = widget.monitorStore.findById(widget.entryId);
        final exited = entry == null || !entry.isActive;
        return Scaffold(
          backgroundColor: colors.canvas,
          appBar: AppBar(
            title: const Text('人员详情'),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: DsSpacing.md),
                child: Icon(
                  exited ? DsIcons.logout : DsIcons.user,
                  color: exited ? colors.textTertiary : colors.brandText,
                  size: DsSizes.iconLg,
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: exited
                      ? StatePlaceholder.empty(
                          icon: DsIcons.logout,
                          message: entry?.name == null
                              ? '该记录已不存在'
                              : '「${entry!.name}」已出火场',
                          actionLabel: '返回看板',
                          onAction: () => Navigator.of(context).pop(),
                        )
                      : _buildActiveBody(context, entry),
                ),
                if (!exited) _buildExitBar(context, entry),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActiveBody(BuildContext context, Entry entry) {
    final now = _currentNowMs();
    final dsStatus = dsStatusForMonitor(
      MonitorStore.statusOf(entry, widget.monitorStore.calcConfig, nowMs: now),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.sm,
        DsSpacing.pageMargin,
        DsSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildStatusBanner(context, entry, dsStatus),
          const SizedBox(height: DsSpacing.cardGap),
          _buildCountdownCard(context, entry, dsStatus, now),
          const SizedBox(height: DsSpacing.lg),
          Text(
            '气瓶与记录',
            style: context.ds.typography.title.copyWith(
              color: context.ds.colors.textPrimary,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          _buildInfoGrid(context, entry),
          if (entry.rawText != null && entry.rawText!.isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.cardGap),
            _buildTranscriptCard(context, entry.rawText!),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusBanner(BuildContext context, Entry entry, DsStatus dsStatus) {
    final ds = context.ds;
    final colors = ds.colors;
    final pair = colors.statusColors(dsStatus);
    final isTimeout = dsStatus == DsStatus.timeout;

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      accentStatus: dsStatus,
      borderColor: dsStatus == DsStatus.safe ? null : pair.fill,
      child: Row(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isTimeout ? pair.fill : pair.pillBg,
              border: Border.all(color: pair.fill.withValues(alpha: 0.35)),
            ),
            child: Text(
              entry.name.isNotEmpty ? entry.name.characters.first : '?',
              style: ds.typography.headline.copyWith(
                color: isTimeout ? pair.onFill : pair.text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typography.headline.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: DsSpacing.xs),
                StatusPill(status: dsStatus, solid: isTimeout),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownCard(
    BuildContext context,
    Entry entry,
    DsStatus dsStatus,
    int now,
  ) {
    final ds = context.ds;
    final colors = ds.colors;
    final pair = colors.statusColors(dsStatus);
    final remainingMs = entry.exitAt - now;
    final isTimeout = remainingMs <= 0;
    final totalMs = entry.durationMin * 60000;
    final progress = totalMs > 0 ? (remainingMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: MetricReadout(
              label: isTimeout
                  ? '已超时（${formatMonitorCountdown(remainingMs, showOvertime: true)}）'
                  : '剩余时间',
              value: formatMonitorCountdown(remainingMs),
              status: dsStatus,
              colorByStatus: dsStatus != DsStatus.safe,
              large: true,
              crossAxisAlignment: CrossAxisAlignment.center,
            ),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            '预计 ${_formatClockTime(entry.exitAt)} 到期',
            textAlign: TextAlign.center,
            style: DsTypography.tabular(
              ds.typography.caption.copyWith(
                color: dsStatus == DsStatus.safe ? colors.textSecondary : pair.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          ClipRRect(
            borderRadius: DsRadius.borderPill,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: colors.surfaceMuted,
              color: pair.fill,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: DsSpacing.lg,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              _metaChip(context, DsIcons.time, pair.text, '${entry.durationMin} 分钟上限'),
              if (entry.pressureMpa != null)
                _metaChip(context, DsIcons.gasMeter, pair.text, '${entry.pressureMpa} MPa'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaChip(BuildContext context, IconData icon, Color iconColor, String text) {
    final ds = context.ds;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: DsSizes.iconSm, color: iconColor),
        const SizedBox(width: DsSpacing.xs),
        Text(
          text,
          style: DsTypography.tabular(
            ds.typography.caption.copyWith(
              color: ds.colors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoGrid(BuildContext context, Entry entry) {
    final cfg = widget.monitorStore.calcConfig;
    final volume = entry.cylinderVolL ?? cfg.cylinderVolL;
    final consumption = entry.consumptionLpm ?? cfg.consumptionLpm;
    final tiles = <Widget>[
      _buildInfoTile(context, DsIcons.login, '进场时间', _formatClockTime(entry.entryAt)),
      _buildInfoTile(context, DsIcons.logout, '预计出场', _formatClockTime(entry.exitAt)),
      _buildInfoTile(
        context,
        DsIcons.gasMeter,
        '气瓶压力',
        entry.pressureMpa != null ? '${entry.pressureMpa} MPa' : '--',
      ),
      _buildInfoTile(context, DsIcons.categoryFireLine, '气瓶容量', '$volume L'),
      _buildInfoTile(context, DsIcons.toolWaterSources, '消耗率', '$consumption L/min'),
      _buildInfoTile(
        context,
        DsIcons.stats,
        '实测消耗率',
        entry.consumptionActualLpm != null
            ? '${entry.consumptionActualLpm!.toStringAsFixed(1)} L/min'
            : '--',
      ),
      _buildInfoTile(context, DsIcons.time, '分钟上限', '${entry.durationMin} 分钟'),
      _buildInfoTile(
        context,
        DsIcons.voiceLine,
        '来源',
        entry.source == 'voice' ? '语音录入' : '手动',
      ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final singleColumn =
            constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += 2) {
          if (singleColumn) {
            rows.add(tiles[i]);
            if (i + 1 < tiles.length) {
              rows.add(const SizedBox(height: DsSpacing.md));
              rows.add(tiles[i + 1]);
            }
          } else {
            rows.add(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: tiles[i]),
                  const SizedBox(width: DsSpacing.md),
                  Expanded(child: tiles[i + 1]),
                ],
              ),
            );
          }
          if (i < tiles.length - 2) rows.add(const SizedBox(height: DsSpacing.md));
        }
        return SurfaceCard(
          level: DsSurfaceLevel.outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        );
      },
    );
  }

  Widget _buildInfoTile(BuildContext context, IconData icon, String label, String value) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: DsSizes.iconSm, color: colors.textTertiary),
            const SizedBox(width: DsSpacing.xs),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ds.typography.caption.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          value,
          softWrap: true,
          style: DsTypography.tabular(
            ds.typography.title.copyWith(color: colors.textPrimary),
          ),
        ),
      ],
    );
  }

  Widget _buildTranscriptCard(BuildContext context, String rawText) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(DsIcons.soundWave, size: DsSizes.iconSm, color: colors.brandText),
              const SizedBox(width: DsSpacing.xs),
              Text(
                '原始语音转写',
                style: ds.typography.caption.copyWith(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          Text(
            rawText,
            style: ds.typography.body.copyWith(color: colors.textPrimary, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _buildExitBar(BuildContext context, Entry entry) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.sm,
        DsSpacing.pageMargin,
        DsSpacing.md,
      ),
      child: CommandButton(
        key: const Key('entry-detail-exit-btn'),
        label: '确认「${entry.name}」已出火场',
        icon: DsIcons.logout,
        variant: CommandButtonVariant.danger,
        size: CommandButtonSize.large,
        expanded: true,
        isLoading: _exiting,
        requireConfirmation: true,
        confirmTitle: '确认「${entry.name}」已出火场？',
        confirmMessage: '登记后将停止倒计时并取消提醒',
        confirmActionLabel: '确认出火场',
        cancelActionLabel: '取消',
        onPressed: () => _executeExit(entry),
      ),
    );
  }
}
