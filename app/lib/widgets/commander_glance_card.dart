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
    final Color statusBorderColor;
    final String statusBadgeType;

    switch (summary.level) {
      case AirSafetyLevel.critical:
        statusBadgeType = 'alarm';
        cardBorder = AppColors.alarm;
        statusSurfaceBg = AppColors.alarmSurface;
        statusBorderColor = AppColors.alarm;
        break;
      case AirSafetyLevel.warning:
        statusBadgeType = 'warn';
        cardBorder = AppColors.caution;
        statusSurfaceBg = AppColors.cautionSurface;
        statusBorderColor = AppColors.caution;
        break;
      case AirSafetyLevel.normal:
        statusBadgeType = 'normal';
        cardBorder = AppColors.border.withValues(alpha: 0.85);
        statusSurfaceBg = AppColors.surfaceSubtle;
        statusBorderColor = AppColors.border.withValues(alpha: 0.85);
        break;
      case AirSafetyLevel.idle:
        statusBadgeType = 'idle';
        cardBorder = AppColors.border.withValues(alpha: 0.6);
        statusSurfaceBg = AppColors.surfaceSubtle.withValues(alpha: 0.5);
        statusBorderColor = AppColors.border.withValues(alpha: 0.5);
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
                  color: AppColors.voice,
                ),
                child: Icon(
                  Icons.shield_outlined,
                  size: 18,
                  color: AppColors.onPrimary,
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
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.textTertiary,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s4,
              vertical: AppSpacing.s3,
            ),
            decoration: BoxDecoration(
              color: statusSurfaceBg,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: statusBorderColor,
                width: 1.0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              summary.hasActive
                                  ? '${summary.activeCount} 人进入火场'
                                  : '暂无在场人员',
                              style: AppTextStyles.h2.copyWith(
                                fontSize: 18,
                                height: 1.25,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (summary.hasActive) ...[
                            const SizedBox(width: AppSpacing.s2),
                            StatusBadge(
                              status: statusBadgeType,
                              onColorCard: false,
                              fontSize: 12,
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (summary.hasActive && summary.shortestRemainingMin != null) ...[
                      const SizedBox(width: AppSpacing.s2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: cardBorder.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                          border: Border.all(color: cardBorder, width: 0.8),
                        ),
                        child: Text(
                          '余${summary.shortestRemainingMin}m (${summary.shortestName})',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: summary.level == AirSafetyLevel.critical
                                ? AppColors.alarm
                                : summary.level == AirSafetyLevel.warning
                                    ? AppColors.caution
                                    : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ],
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
