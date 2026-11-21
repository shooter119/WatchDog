import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/calc_config.dart';
import '../../data/models/entry.dart';
import '../../state/monitor_store.dart';
import 'monitor_risk_bar.dart';

/// 单个在场人员空呼倒计时卡片。
///
/// 性能与安全不变量：
/// - 整卡包在独立 [RepaintBoundary] 内，由 [clockTick] 局部驱动重绘，不触发列表重建；
/// - 严格执行 D6 语义分级（安全绿 / 注意黄 / 告警红 / 超时深红 `#7F1D1D`），双通道图标+文字表达；
/// - 主操作按钮（更新压力）最小高度 ≥ 56dp（[CommandButtonSize.large]），适配手套点击；
/// - 全部计时与数值强制 `tabularFigures`，320~360dp 与 130%~200% 字体缩放下零溢出。
class PersonnelCountdownCard extends StatelessWidget {
  const PersonnelCountdownCard({
    super.key,
    required this.entry,
    required this.calcConfig,
    required this.clockTick,
    required this.onTap,
    required this.onReportPressure,
    this.nowMs,
  });

  final Entry entry;
  final CalcConfig calcConfig;
  final ValueListenable<int> clockTick;
  final VoidCallback onTap;
  final VoidCallback onReportPressure;
  final int Function()? nowMs;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: clockTick,
        builder: (BuildContext context, int _, Widget? __) {
          final currentNow = nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
          final rawStatus = MonitorStore.statusOf(
            entry,
            calcConfig,
            nowMs: currentNow,
          );
          final dsStatus = dsStatusForMonitor(rawStatus);
          final isTimeout = dsStatus == DsStatus.timeout;
          final remainingMs = entry.exitAt - currentNow;

          final ds = context.ds;
          final colors = ds.colors;
          final pair = colors.statusColors(dsStatus);
          final textScale = MediaQuery.textScalerOf(context).scale(1.0);
          final stackedHeader =
              MediaQuery.sizeOf(context).width < 300 || textScale > 1.35;

          final Color? borderColor = switch (dsStatus) {
            DsStatus.timeout => colors.timeoutFill,
            DsStatus.alarm => colors.alarmFill,
            DsStatus.caution => colors.cautionFill,
            _ => null,
          };

          final statusPill = StatusPill(
            status: dsStatus,
            solid: isTimeout,
          );

          final nameText = Text(
            entry.name,
            maxLines: stackedHeader ? 2 : 1,
            softWrap: stackedHeader,
            overflow: TextOverflow.ellipsis,
            style: ds.typography.headline.copyWith(
              color: colors.textPrimary,
            ),
          );

          return SurfaceCard(
            key: Key('monitor-card-${entry.id}'),
            level: DsSurfaceLevel.outlined,
            accentStatus: dsStatus,
            borderColor: borderColor,
            padding: const EdgeInsets.all(DsSpacing.md),
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (stackedHeader) ...<Widget>[
                  nameText,
                  const SizedBox(height: DsSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: statusPill,
                  ),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(child: nameText),
                      const SizedBox(width: DsSpacing.sm),
                      statusPill,
                    ],
                  ),
                const SizedBox(height: DsSpacing.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: MetricReadout(
                        label: isTimeout ? '已超时' : '剩余时间',
                        value: formatMonitorCountdown(
                          remainingMs,
                          showOvertime: isTimeout,
                          overtimePrefix: '+',
                        ),
                        status: dsStatus,
                        colorByStatus: dsStatus != DsStatus.safe,
                        large: true,
                      ),
                    ),
                    const SizedBox(width: DsSpacing.md),
                    Container(
                      width: 1,
                      height: 54,
                      color: isTimeout
                          ? pair.fill.withValues(alpha: 0.35)
                          : colors.border,
                    ),
                    const SizedBox(width: DsSpacing.md),
                    Expanded(
                      child: MetricReadout(
                        label: '持续时长',
                        value: formatMonitorElapsed(entry.entryAt, currentNow),
                        large: true,
                        crossAxisAlignment: CrossAxisAlignment.end,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.md),
                CommandButton(
                  key: Key('monitor-card-report-btn-${entry.id}'),
                  label: '更新压力',
                  icon: Icons.speed_rounded,
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.large,
                  expanded: true,
                  onPressed: onReportPressure,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
