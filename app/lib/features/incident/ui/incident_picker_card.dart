import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'incident_picker_items.dart';
import 'widgets/incident_category_chip.dart';
import 'widgets/incident_category_style.dart';

export 'incident_picker_items.dart';

final RegExp _warningHighlightPattern = RegExp(r'被困|伤|危|泄漏|燃气|煤气|爆炸');

/// Design System v3.0 警情选择卡片（三层信息架构：事件主标题 / 辖区地点时间 / 力量与状态胶囊）。
class IncidentPickerCard extends StatelessWidget {
  const IncidentPickerCard({super.key, required this.item, this.enabled = true});

  final IncidentPickerItem item;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final hasExtraChips =
        item.forceTags.isNotEmpty || item.factHighlights.isNotEmpty;
    final cautionPair = colors.statusColors(DsStatus.caution);
    final districtBg = item.isCustom ? cautionPair.pillBg : colors.surfaceMuted;
    final districtFg = item.isCustom ? cautionPair.text : colors.textSecondary;

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md + 2,
        vertical: DsSpacing.md,
      ),
      onTap: enabled ? item.onTap : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              IncidentCategoryIconBadge(
                key: Key('ext-category-badge-${item.key}-${item.category.name}'),
                category: item.category,
                size: 38,
                iconSize: 20,
              ),
              const SizedBox(width: DsSpacing.sm + 2),
              Expanded(
                child: IncidentAntiOrphanText(
                  text: item.eventTitle,
                  style: typo.title.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              Container(
                key: Key('picker-enter-pill-${item.key}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.sm,
                  vertical: DsSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: colors.brand.withValues(alpha: 0.12),
                  borderRadius: DsRadius.borderPill,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      item.badgeText,
                      style: typo.micro.copyWith(
                        color: colors.brandText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      DsIcons.chevronRight,
                      size: DsSizes.iconSm,
                      color: colors.brandText,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          Row(
            children: <Widget>[
              if (item.districtTag.isNotEmpty)
                Container(
                  key: Key('picker-district-tag-${item.key}'),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: districtBg,
                    borderRadius: DsRadius.borderSm,
                  ),
                  child: Text(
                    item.districtTag,
                    style: typo.micro.copyWith(
                      color: districtFg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        item.locationText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.caption.copyWith(color: colors.textSecondary),
                      ),
                    ),
                    if (item.timeText.isNotEmpty)
                      Flexible(
                        flex: 0,
                        child: Text(
                          ' · ${item.timeText}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.captionTabular.copyWith(
                            color: colors.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (hasExtraChips) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            Wrap(
              key: Key('ext-forces-wrap-${item.key}'),
              spacing: 6,
              runSpacing: DsSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final forceTag in item.forceTags)
                  Container(
                    constraints: const BoxConstraints(minHeight: 26),
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.sm,
                      vertical: DsSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: DsRadius.borderPill,
                      border: Border.all(color: colors.border, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          DsIcons.truck,
                          size: DsSizes.iconSm,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: DsSpacing.xs),
                        Flexible(
                          child: Text(
                            forceTag,
                            style: typo.micro.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final highlight in item.factHighlights)
                  _buildHighlightPill(highlight),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHighlightPill(String highlight) {
    if (highlight == '处置中') {
      return StatusPill(
        status: DsStatus.safe,
        label: highlight,
        icon: DsIcons.navMonitorFill,
      );
    }
    if (_warningHighlightPattern.hasMatch(highlight)) {
      return StatusPill(
        status: DsStatus.caution,
        label: highlight,
        icon: DsIcons.statusCaution,
      );
    }
    if (IncidentCardViewModel.isTerminalOfficialStatus(highlight)) {
      return StatusPill(
        status: DsStatus.neutral,
        label: highlight,
        icon: DsIcons.checkCircle,
      );
    }
    return StatusPill(
      status: DsStatus.neutral,
      label: highlight,
      icon: DsIcons.statusNeutral,
    );
  }
}
