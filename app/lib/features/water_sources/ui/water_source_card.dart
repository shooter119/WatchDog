import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/china_coord.dart';
import '../data/models/water_source.dart';

/// 水源列表卡片（Design System v3.0 `SurfaceCard` + 双通道 `StatusPill`）。
class WaterSourceCard extends StatelessWidget {
  final WaterSource item;
  final double? distanceMeters;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onQuickToggleStatus;

  const WaterSourceCard({
    super.key,
    required this.item,
    this.distanceMeters,
    this.selected = false,
    required this.onTap,
    required this.onQuickToggleStatus,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final dist = distanceMeters;

    return SurfaceCard(
      key: Key('water-card-${item.id}'),
      accentStatus: item.isAvailable ? DsStatus.safe : DsStatus.alarm,
      borderColor: selected ? colors.brand : null,
      padding: const EdgeInsets.all(DsSpacing.md),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              WaterSourceCategoryBadge(
                category: item.category,
                available: item.isAvailable,
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ds.typography.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dist != null
                          ? '${item.category.shortLabel} · ${ChinaCoord.formatDistance(dist)}'
                          : item.category.label,
                      style: ds.typography.captionTabular.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              WaterSourceStatusPill(status: item.status),
              const SizedBox(width: DsSpacing.xs),
              IconButton(
                key: Key('water-card-toggle-${item.id}'),
                tooltip: item.isAvailable ? '快捷标为不可用' : '快捷标为可用',
                constraints: const BoxConstraints(
                  minWidth: DsSizes.touchTarget,
                  minHeight: DsSizes.touchTarget,
                ),
                onPressed: onQuickToggleStatus,
                icon: Icon(
                  item.isAvailable
                      ? Icons.toggle_on_rounded
                      : Icons.toggle_off_outlined,
                  color: item.isAvailable ? colors.safeText : colors.alarmText,
                  size: 28,
                ),
              ),
            ],
          ),
          if (item.category == WaterSourceCategory.natural &&
              item.intakeMethods.isNotEmpty) ...[
            const SizedBox(height: DsSpacing.sm),
            Wrap(
              spacing: DsSpacing.xs,
              runSpacing: DsSpacing.xs,
              children: [
                for (final m in item.intakeMethods)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.sm,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: DsRadius.borderSm,
                    ),
                    child: Text(
                      m.shortLabel,
                      style: ds.typography.micro.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (item.firstNoteLine.isNotEmpty) ...[
            const SizedBox(height: DsSpacing.sm),
            Text(
              item.firstNoteLine,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 水源可用/不可用双通道语义状态胶囊（基于 `StatusPill`）。
class WaterSourceStatusPill extends StatelessWidget {
  final WaterSourceStatus status;

  const WaterSourceStatusPill({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final available = status == WaterSourceStatus.available;
    return StatusPill(
      status: available ? DsStatus.safe : DsStatus.alarm,
      solid: !available,
      icon: available
          ? Icons.check_circle_rounded
          : Icons.cancel_rounded,
      label: status.label,
    );
  }
}

/// 水源类别语义图标徽章。
class WaterSourceCategoryBadge extends StatelessWidget {
  final WaterSourceCategory category;
  final bool available;

  const WaterSourceCategoryBadge({
    super.key,
    required this.category,
    required this.available,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final IconData icon;
    final Color color;
    switch (category) {
      case WaterSourceCategory.hydrant:
        icon = Icons.fire_hydrant_alt_outlined;
        color = available ? colors.brandText : colors.alarmText;
      case WaterSourceCategory.natural:
        icon = Icons.water_drop_outlined;
        color = available ? colors.safeText : colors.alarmText;
      case WaterSourceCategory.pumpConnector:
        icon = Icons.plumbing_outlined;
        color = available ? colors.cautionText : colors.alarmText;
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: DsSizes.iconMd, color: color),
    );
  }
}
