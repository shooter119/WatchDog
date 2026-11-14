import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/tactical_brief_engine.dart';
import '../theme/app_widgets.dart';

/// 指挥员 3 秒态势卡（遵循 UI Spec v2.0，重构升级自原主页现场监控卡片）
class CommanderGlanceCard extends StatelessWidget {
  final List<Entry> activeEntries;
  final List<Note> notes;
  final VoidCallback? onTap;

  const CommanderGlanceCard({
    super.key,
    required this.activeEntries,
    this.notes = const [],
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final summary = TacticalBriefEngine.extractAirSafetySummary(activeEntries);
    final intel = TacticalBriefEngine.extractIntelligence(notes);
    final hasHazard = intel.hasCriticalHazards;
    final tacticalProgress = TacticalBriefEngine.extractTacticalProgress(notes);

    final Color cardBorder;
    final Color statusSurfaceBg;
    final String statusBadgeType;

    switch (summary.level) {
      case AirSafetyLevel.critical:
        statusBadgeType = 'alarm';
        cardBorder = AppColors.alarm;
        statusSurfaceBg = AppColors.alarmSurface;
        break;
      case AirSafetyLevel.warning:
        statusBadgeType = 'warn';
        cardBorder = AppColors.caution;
        statusSurfaceBg = AppColors.cautionSurface;
        break;
      case AirSafetyLevel.normal:
        statusBadgeType = 'normal';
        cardBorder = AppColors.border.withValues(alpha: 0.85);
        statusSurfaceBg = AppColors.surfaceSubtle;
        break;
      case AirSafetyLevel.idle:
        statusBadgeType = 'idle';
        cardBorder = AppColors.border.withValues(alpha: 0.6);
        statusSurfaceBg = AppColors.surfaceSubtle.withValues(alpha: 0.5);
        break;
    }

    return AppCard(
      radius: AppRadius.lg,
      padding: const EdgeInsets.all(AppSpacing.cardInner),
      side: BorderSide(color: cardBorder, width: 1.0),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceSubtle,
                ),
                child: Icon(
                  Icons.shield_outlined,
                  size: 18,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  '现场监控',
                  style: AppTextStyles.bodyLg.copyWith(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '查看看板',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.actionPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.actionPrimary,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3,
              vertical: AppSpacing.s3,
            ),
            decoration: BoxDecoration(
              color: statusSurfaceBg,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final countText = Text(
                      summary.hasActive
                          ? '${summary.activeCount} 人进入火场'
                          : '暂无在场人员',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.h2.copyWith(
                        fontSize: 20,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                        fontFeatures: const [
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    );
                    final remainingLabel =
                        summary.hasActive && summary.shortestRemainingMin != null
                            ? Text(
                                '余${summary.shortestRemainingMin}分钟 (${summary.shortestName})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                  color: summary.level == AirSafetyLevel.critical
                                      ? AppColors.alarmText
                                      : summary.level == AirSafetyLevel.warning
                                          ? AppColors.cautionText
                                          : AppColors.textPrimary,
                                ),
                              )
                            : null;
                    final compact =
                        constraints.maxWidth < 275 ||
                        MediaQuery.textScalerOf(context).scale(1.0) > 1.15;
                    if (compact) {
                      return Wrap(
                        spacing: AppSpacing.s2,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          countText,
                          if (summary.hasActive)
                            StatusBadge(
                              status: statusBadgeType,
                              onColorCard: false,
                              fontSize: 12,
                            ),
                          if (remainingLabel != null) remainingLabel,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (!summary.hasActive)
                          Expanded(child: countText)
                        else ...[
                          countText,
                          const SizedBox(width: AppSpacing.s2),
                          StatusBadge(
                            status: statusBadgeType,
                            onColorCard: false,
                            fontSize: 12,
                          ),
                          if (remainingLabel != null) ...[
                            const SizedBox(width: AppSpacing.s2),
                            Expanded(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 26),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: remainingLabel,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ],
                    );
                  },
                ),
                if (tacticalProgress != null && tacticalProgress.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        hasHazard
                            ? Icons.warning_amber_rounded
                            : Icons.timeline_rounded,
                        size: 13,
                        color: hasHazard
                            ? AppColors.alarm
                            : AppColors.textTertiary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          tacticalProgress,
                          style: AppTextStyles.caption.copyWith(
                            fontSize: 12,
                            color: hasHazard
                                ? AppColors.alarmText
                                : AppColors.textSecondary,
                            fontWeight:
                                hasHazard ? FontWeight.w700 : FontWeight.normal,
                            height: 1.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
