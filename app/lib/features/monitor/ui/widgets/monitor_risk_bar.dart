import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../state/monitor_store.dart';

/// 将业务状态字符串映射为 Design System v3.0 语义状态（D6 色板严格一致）。
DsStatus dsStatusForMonitor(String rawStatus) => switch (rawStatus) {
  'timeout' => DsStatus.timeout,
  'alarm' => DsStatus.alarm,
  'warn' => DsStatus.caution,
  _ => DsStatus.safe,
};

/// 格式化剩余或超时倒计时（`MM:SS` / `H:MM:SS` / `已超时` / `+MM:SS`）。
String formatMonitorCountdown(
  int ms, {
  bool showOvertime = false,
  String overtimePrefix = '+',
  String timeoutText = '已超时',
}) {
  if (ms <= 0) {
    if (!showOvertime) return timeoutText;
    final totalSec = ms.abs() ~/ 1000;
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$overtimePrefix${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  final totalSec = ms ~/ 1000;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 格式化已持续在场时长（`MM:SS` / `H:MM:SS`）。
String formatMonitorElapsed(int entryAtMs, int nowMs) {
  final diff = nowMs - entryAtMs;
  final totalSec = (diff < 0 ? 0 : diff) ~/ 1000;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 现场监控顶部风险概览卡（在场总数 / 需关注 / 最早到期 + D6 风险分级胶囊）。
class MonitorRiskBar extends StatelessWidget {
  const MonitorRiskBar({
    super.key,
    required this.summary,
    required this.nowMs,
  });

  final MonitorRiskSummary summary;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final earliest = summary.earliestEntry;
    final earliestRemainingMs = earliest == null ? null : earliest.exitAt - nowMs;
    final earliestDsStatus = earliest == null
        ? null
        : dsStatusForMonitor(summary.worstStatus);

    return SurfaceCard(
      key: const Key('monitor-risk-bar'),
      level: DsSurfaceLevel.outlined,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: MetricReadout(
                  label: '在场人员',
                  value: '${summary.totalActive}',
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
              ),
              Container(width: 1, height: 42, color: colors.border),
              Expanded(
                child: MetricReadout(
                  label: '需关注',
                  value: '${summary.dangerCount}',
                  status: summary.dangerCount > 0 ? earliestDsStatus : null,
                  colorByStatus: summary.dangerCount > 0,
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
              ),
              Container(width: 1, height: 42, color: colors.border),
              Expanded(
                child: MetricReadout(
                  label: '最早到期',
                  value: earliestRemainingMs == null
                      ? '--'
                      : formatMonitorCountdown(earliestRemainingMs),
                  status: earliestDsStatus,
                  colorByStatus:
                      earliestDsStatus != null &&
                      earliestDsStatus != DsStatus.safe,
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          Divider(height: 1, thickness: 1, color: colors.border),
          const SizedBox(height: DsSpacing.sm),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              StatusPill(
                status: summary.timeoutCount > 0 ? DsStatus.timeout : DsStatus.neutral,
                icon: DsIcons.statusTimeout,
                label: '超时 ${summary.timeoutCount}',
                solid: summary.timeoutCount > 0,
              ),
              StatusPill(
                status: summary.alarmCount > 0 ? DsStatus.alarm : DsStatus.neutral,
                icon: DsIcons.statusAlarm,
                label: '告警 ${summary.alarmCount}',
              ),
              StatusPill(
                status: summary.cautionCount > 0 ? DsStatus.caution : DsStatus.neutral,
                icon: DsIcons.statusCaution,
                label: '注意 ${summary.cautionCount}',
              ),
              StatusPill(
                status: summary.safeCount > 0 ? DsStatus.safe : DsStatus.neutral,
                icon: DsIcons.statusSafe,
                label: '安全 ${summary.safeCount}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 危险人员高优先级横幅（取最严重等级着色：超时 `#7F1D1D` / 告警红 / 注意黄）。
class MonitorDangerBanner extends StatelessWidget {
  const MonitorDangerBanner({
    super.key,
    required this.summary,
    required this.nowMs,
  });

  final MonitorRiskSummary summary;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final earliest = summary.earliestEntry;
    if (summary.dangerCount <= 0 || earliest == null) {
      return const SizedBox.shrink();
    }

    final status = dsStatusForMonitor(summary.worstStatus);
    final pair = colors.statusColors(status);
    final isSolidDanger =
        status == DsStatus.timeout || status == DsStatus.alarm;
    final bg = isSolidDanger ? pair.fill : pair.pillBg;
    final fg = isSolidDanger ? pair.onFill : pair.text;
    final borderColor = isSolidDanger
        ? pair.fill
        : pair.fill.withValues(alpha: 0.35);
    final icon = switch (status) {
      DsStatus.timeout => DsIcons.statusTimeout,
      DsStatus.alarm => DsIcons.statusAlarm,
      _ => DsIcons.statusCaution,
    };
    final earliestText = formatMonitorCountdown(earliest.exitAt - nowMs);

    return Container(
      key: const Key('monitor-danger-banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: DsRadius.borderMd,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: DsSizes.iconMd, color: fg),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              '${summary.dangerCount} 人需要关注 · 最早到期 $earliestText',
              style: DsTypography.tabular(
                ds.typography.body.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部通用状态提示条（断线重试 / 报警音静音提示）。
class MonitorNoticeBanner extends StatelessWidget {
  const MonitorNoticeBanner({
    super.key,
    required this.status,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final DsStatus status;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pair = ds.colors.statusColors(status);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: pair.pillBg,
        borderRadius: DsRadius.borderMd,
        border: Border.all(color: pair.fill.withValues(alpha: 0.32), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: DsSizes.iconMd, color: pair.text),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ds.typography.body.copyWith(
                color: pair.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(width: DsSpacing.sm),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: pair.text,
                minimumSize: const Size(
                  DsSizes.touchTarget,
                  DsSizes.touchTarget,
                ),
                padding: const EdgeInsets.symmetric(horizontal: DsSpacing.sm),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                actionLabel!,
                style: ds.typography.body.copyWith(
                  color: pair.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
