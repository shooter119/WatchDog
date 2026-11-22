import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_icons.dart';
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
/// 采用精炼 2 层响应式布局：
/// - 警情标题行：完整宽度展示警情名称（最多 2 行省略）
/// - 元信息态势行：`Wrap` 自适应顺序排列淡指挥蓝类别胶囊、等宽持续时间、
///   最高风险 [StatusPill] 与按需展示的 [ConnectionPill]
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

    final Color tagBg = colors.brand.withValues(alpha: 0.12);
    final Color tagBorder = colors.brand.withValues(alpha: 0.22);
    final Color tagFg = colors.brandText;
    final (IconData defaultIcon, String defaultLabel) = switch (category) {
      DsIncidentCategory.fire => (DsIcons.categoryFire, '火灾'),
      DsIncidentCategory.rescue => (DsIcons.categoryRescue, '抢险'),
      DsIncidentCategory.aid => (DsIcons.categoryAid, '救援'),
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
              Container(
                key: const Key('incident-header-category-pill'),
                constraints: const BoxConstraints(minHeight: 26),
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.sm,
                  vertical: DsSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: tagBg,
                  borderRadius: DsRadius.borderPill,
                  border: Border.all(color: tagBorder, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      resolvedCategoryIcon,
                      size: DsSizes.iconSm,
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    DsIcons.time,
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
              if (showConnectionPill)
                ConnectionPill(
                  state: connectionState,
                  pendingCount: pendingSyncCount,
                  onTap: onConnectionTap,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
