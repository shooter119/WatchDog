import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';
import 'connection_pill.dart';
import 'status_pill.dart';
import 'surface_card.dart';

/// 警情类别语义。
enum DsIncidentCategory {
  /// 火灾扑救
  fire,

  /// 抢险救援
  rescue,

  /// 社会救助
  aid,
}

/// Design System v3.0 警情头部态势概览栏。
///
/// 采用分层响应式布局：
/// - 顶部元信息行：`Wrap` 自适应两端对齐警情类别标识与 [ConnectionPill]
/// - 警情标题行：完整宽度展示警情名称（最多 2 行省略）
/// - 底部态势行：`Wrap` 自适应排列等宽持续时间与最高风险 [StatusPill]
class IncidentHeader extends StatelessWidget {
  const IncidentHeader({
    super.key,
    required this.incidentName,
    this.category = DsIncidentCategory.fire,
    this.categoryLabel,
    this.categoryIcon,
    required this.elapsedText,
    required this.highestRiskStatus,
    this.highestRiskLabel,
    required this.connectionState,
    this.pendingSyncCount = 0,
    this.showConnectionPill = true,
    this.onTap,
    this.onConnectionTap,
  });

  final String incidentName;
  final DsIncidentCategory category;
  final String? categoryLabel;
  final IconData? categoryIcon;
  final String elapsedText;
  final DsStatus highestRiskStatus;
  final String? highestRiskLabel;
  final DsConnectionState connectionState;
  final int pendingSyncCount;
  final bool showConnectionPill;
  final VoidCallback? onTap;
  final VoidCallback? onConnectionTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    final (Color tagBg, Color tagFg, IconData defaultIcon, String defaultLabel) =
        switch (category) {
      DsIncidentCategory.fire => (
          colors.statusColors(DsStatus.alarm).pillBg,
          colors.statusColors(DsStatus.alarm).text,
          Icons.local_fire_department_rounded,
          '火灾',
        ),
      DsIncidentCategory.rescue => (
          colors.statusColors(DsStatus.caution).pillBg,
          colors.statusColors(DsStatus.caution).text,
          Icons.handyman_rounded,
          '抢险',
        ),
      DsIncidentCategory.aid => (
          colors.brand.withValues(alpha: 0.12),
          colors.brandText,
          Icons.medical_services_outlined,
          '救援',
        ),
    };

    final resolvedCategoryLabel =
        (categoryLabel != null && categoryLabel!.isNotEmpty)
            ? categoryLabel!
            : defaultLabel;
    final resolvedCategoryIcon = categoryIcon ?? defaultIcon;

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      padding: const EdgeInsets.all(DsSpacing.md),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              runAlignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: DsSpacing.sm,
              runSpacing: DsSpacing.xs,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.sm,
                    vertical: DsSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: tagBg,
                    borderRadius: DsRadius.borderSm,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        resolvedCategoryIcon,
                        size: 14,
                        color: tagFg,
                      ),
                      const SizedBox(width: DsSpacing.xs),
                      Flexible(
                        child: Text(
                          resolvedCategoryLabel,
                          style: typo.micro.copyWith(
                            color: tagFg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (showConnectionPill)
                  ConnectionPill(
                    state: connectionState,
                    pendingCount: pendingSyncCount,
                    onTap: onConnectionTap,
                  ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          Text(
            incidentName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: typo.headline.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.sm),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.schedule_rounded,
                    size: DsSizes.iconSm,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: DsSpacing.xs),
                  Text(
                    elapsedText,
                    style: typo.captionTabular.copyWith(
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              StatusPill(
                status: highestRiskStatus,
                label: highestRiskLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
