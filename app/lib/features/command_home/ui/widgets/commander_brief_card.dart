import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../../../services/tactical_brief_engine.dart';

/// 指挥员 3 秒态势卡（Design System v3.0）。
///
/// 展示在场内攻人数、木桶最短板余量、双通道状态胶囊与最新实质战术进展，
/// 点击直跳 Tab 1 现场监控看板。通过 [AirSafetySummary] 接收纯值数据，
/// 保持 `features/command_home/` 零跨 Feature 依赖。
class CommanderBriefCard extends StatelessWidget {
  const CommanderBriefCard({
    super.key = const Key('command-glance-card'),
    required this.summary,
    this.tacticalProgress,
    this.hasCriticalHazards = false,
    this.onTap,
  });

  factory CommanderBriefCard.fromIntelligence({
    Key? key = const Key('command-glance-card'),
    required AirSafetySummary summary,
    TacticalIntelligenceSummary? intelligence,
    VoidCallback? onTap,
  }) {
    String? progress;
    if (intelligence != null) {
      if (intelligence.hazards.isNotEmpty) {
        progress = intelligence.hazards.first;
      } else if (intelligence.lifeSafety.isNotEmpty) {
        progress = intelligence.lifeSafety.first;
      } else if (intelligence.suppression.isNotEmpty) {
        progress = intelligence.suppression.first;
      } else if (intelligence.technicalRescue.isNotEmpty) {
        progress = intelligence.technicalRescue.first;
      } else if (intelligence.perimeterAndSupport.isNotEmpty) {
        progress = intelligence.perimeterAndSupport.first;
      }
    }
    return CommanderBriefCard(
      key: key,
      summary: summary,
      tacticalProgress: progress,
      hasCriticalHazards: intelligence?.hasCriticalHazards ?? false,
      onTap: onTap,
    );
  }

  final AirSafetySummary summary;
  final String? tacticalProgress;
  final bool hasCriticalHazards;
  final VoidCallback? onTap;

  DsStatus _statusForLevel(AirSafetyLevel level) {
    return switch (level) {
      AirSafetyLevel.critical => DsStatus.alarm,
      AirSafetyLevel.warning => DsStatus.caution,
      AirSafetyLevel.normal => DsStatus.safe,
      AirSafetyLevel.idle => DsStatus.neutral,
    };
  }

  String _statusLabelForLevel(AirSafetyLevel level) {
    return switch (level) {
      AirSafetyLevel.critical => '告警',
      AirSafetyLevel.warning => '注意',
      AirSafetyLevel.normal => '正常',
      AirSafetyLevel.idle => '待命',
    };
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    final status = _statusForLevel(summary.level);
    final statusPair = colors.statusColors(status);
    final hasAccent =
        summary.level == AirSafetyLevel.critical ||
        summary.level == AirSafetyLevel.warning;

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      accentStatus: hasAccent ? status : null,
      borderColor: hasAccent ? statusPair.fill : colors.border,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.surfaceMuted,
                ),
                child: Icon(
                  DsIcons.shield,
                  size: DsSizes.iconMd,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  '现场监控',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.title.copyWith(color: colors.textPrimary),
                ),
              ),
              Text(
                '查看看板',
                style: typo.caption.copyWith(
                  color: colors.brandText,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(
                DsIcons.chevronRight,
                size: DsSizes.iconMd,
                color: colors.brandText,
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          SurfaceCard(
            level: DsSurfaceLevel.flat,
            backgroundColor: hasAccent ? statusPair.pillBg : colors.surfaceMuted,
            borderRadius: DsRadius.borderMd,
            padding: const EdgeInsets.all(DsSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final countText = Text(
                      summary.hasActive
                          ? '${summary.activeCount} 人进入火场'
                          : '暂无在场人员',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsTypography.tabular(typo.headline).copyWith(
                        color: colors.textPrimary,
                      ),
                    );
                    final remainingLabel =
                        summary.hasActive &&
                            summary.shortestRemainingMin != null
                        ? Text(
                            '余${summary.shortestRemainingMin}分钟 (${summary.shortestName ?? ''})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: typo.captionTabular.copyWith(
                              fontWeight: FontWeight.w700,
                              color: hasAccent
                                  ? statusPair.text
                                  : colors.textPrimary,
                            ),
                          )
                        : null;
                    final compact =
                        constraints.maxWidth < 275 ||
                        MediaQuery.textScalerOf(context).scale(1.0) > 1.15;
                    if (compact) {
                      return Wrap(
                        spacing: DsSpacing.sm,
                        runSpacing: DsSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          countText,
                          if (summary.hasActive)
                            StatusPill(
                              status: status,
                              label: _statusLabelForLevel(summary.level),
                            ),
                          if (remainingLabel != null) remainingLabel,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        if (!summary.hasActive)
                          Expanded(child: countText)
                        else ...<Widget>[
                          countText,
                          const SizedBox(width: DsSpacing.sm),
                          StatusPill(
                            status: status,
                            label: _statusLabelForLevel(summary.level),
                          ),
                          if (remainingLabel != null) ...<Widget>[
                            const SizedBox(width: DsSpacing.sm),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: remainingLabel,
                              ),
                            ),
                          ],
                        ],
                      ],
                    );
                  },
                ),
                if (tacticalProgress != null &&
                    tacticalProgress!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: DsSpacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Icon(
                        hasCriticalHazards
                            ? DsIcons.warning
                            : DsIcons.timeline,
                        size: DsSizes.iconSm,
                        color: hasCriticalHazards
                            ? colors.alarmText
                            : colors.textSecondary,
                      ),
                      const SizedBox(width: DsSpacing.xs),
                      Expanded(
                        child: Text(
                          tacticalProgress!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.caption.copyWith(
                            color: hasCriticalHazards
                                ? colors.alarmText
                                : colors.textSecondary,
                            fontWeight: hasCriticalHazards
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
