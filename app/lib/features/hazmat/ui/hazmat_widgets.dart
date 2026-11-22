import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/hazmat.dart';

/// 危化品页共享高对比语义提示横幅（AI 警告 / 云端命中 / 离线提示）。
class HazmatNoticeBanner extends StatelessWidget {
  const HazmatNoticeBanner({
    super.key,
    required this.status,
    required this.icon,
    required this.text,
  });

  final DsStatus status;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pair = ds.colors.statusColors(status);
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      accentStatus: status,
      backgroundColor: pair.pillBg,
      borderColor: status == DsStatus.neutral
          ? ds.colors.border
          : pair.fill.withValues(alpha: 0.45),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: DsSizes.iconMd, color: pair.text),
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ds.typography.body.copyWith(
                color: ds.colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 等宽 UN 编号高对比徽章。
class HazmatUnBadge extends StatelessWidget {
  const HazmatUnBadge({
    super.key,
    required this.unNumber,
    this.showEmptyFallback = true,
  });

  final String unNumber;
  final bool showEmptyFallback;

  @override
  Widget build(BuildContext context) {
    if (unNumber.isEmpty && !showEmptyFallback) {
      return const SizedBox.shrink();
    }
    final ds = context.ds;
    final colors = ds.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm + 2,
        vertical: DsSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.brand,
        borderRadius: DsRadius.borderSm,
      ),
      child: Text(
        unNumber.isNotEmpty ? 'UN $unNumber' : '未列 UN 编号',
        style: ds.typography.captionTabular.copyWith(
          color: colors.onBrand,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 危化品战术卡条目块（图标 + 标签 + 正文）。
class HazmatInfoBlock extends StatelessWidget {
  const HazmatInfoBlock({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.highlightColor,
    this.tabular = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? highlightColor;
  final bool tabular;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final textValue = value.trim().isEmpty ? '暂无记录' : value.trim();
    final labelColor = highlightColor ?? colors.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: DsSizes.iconSm, color: labelColor),
            const SizedBox(width: DsSpacing.xs + 2),
            Expanded(
              child: Text(
                label,
                style: typo.caption.copyWith(
                  color: labelColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: DsSpacing.xs + 2),
        Text(
          textValue,
          style: (tabular ? typo.bodyTabular : typo.body).copyWith(
            color: colors.textPrimary,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// 危化品列表项卡片。
class HazmatListTile extends StatelessWidget {
  const HazmatListTile({super.key, required this.item, required this.onTap});

  final HazmatItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final waterStatus = item.isWaterForbidden
        ? DsStatus.alarm
        : (item.isWaterReactive ? DsStatus.caution : DsStatus.safe);
    final waterIcon = item.isWaterForbidden
        ? DsIcons.prohibited
        : (item.isWaterReactive
              ? DsIcons.warning
              : DsIcons.toolWaterSources);

    return SurfaceCard(
      key: ValueKey<String>('hazmat-list-item-${item.id}'),
      level: DsSurfaceLevel.outlined,
      accentStatus: waterStatus,
      onTap: onTap,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs + 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (item.unNumber.isNotEmpty)
                HazmatUnBadge(
                  unNumber: item.unNumber,
                  showEmptyFallback: false,
                ),
              StatusPill(
                status: waterStatus,
                icon: waterIcon,
                label: item.waterLabel,
              ),
              if (item.dangerCategory.isNotEmpty)
                Text(
                  item.dangerCategory,
                  style: typo.caption.copyWith(color: colors.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  item.nameCn,
                  style: typo.title.copyWith(color: colors.textPrimary),
                ),
              ),
              Icon(DsIcons.chevronRight, color: colors.textTertiary),
            ],
          ),
          if (item.aliases.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              '别名：${item.aliases.join('、')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.caption.copyWith(color: colors.textSecondary),
            ),
          ],
          if (item.forbiddenAgents.isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.xs + 2),
            Text(
              '禁忌：${item.forbiddenAgents}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: typo.caption.copyWith(
                color: item.isWaterForbidden
                    ? colors.alarmText
                    : colors.textSecondary,
                fontWeight: item.isWaterForbidden
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
