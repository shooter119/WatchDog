import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'archived_incident_models.dart';

export 'archived_incident_models.dart';

/// 归档页顶部统计摘要卡片。
class ArchiveSummaryCard extends StatelessWidget {
  const ArchiveSummaryCard({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.lg,
        vertical: DsSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.brand.withValues(alpha: 0.14),
              borderRadius: DsRadius.borderMd,
            ),
            child: Icon(
              DsIcons.archive,
              color: colors.brandText,
              size: DsSizes.iconLg,
            ),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Text(
              '处置档案库',
              style: typo.headline.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '$count',
                style: typo.metric.copyWith(color: colors.textPrimary),
              ),
              Text(
                '份档案',
                style: typo.caption.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单条已归档警情卡片。
class ArchivedIncidentCard extends StatelessWidget {
  const ArchivedIncidentCard({
    super.key,
    required this.incident,
    required this.onRename,
    required this.onTap,
  });

  final ArchivedIncidentView incident;
  final VoidCallback onRename;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.md,
        DsSpacing.sm,
        DsSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: DsRadius.borderSm,
                ),
                child: Icon(
                  DsIcons.categoryFireLine,
                  size: DsSizes.iconMd,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      incident.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typo.title.copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: DsSpacing.xs),
                    Text(
                      incident.title == null || incident.title!.trim().isEmpty
                          ? '默认名称 · ${incident.number}'
                          : incident.number,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.caption.copyWith(color: colors.textTertiary),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '修改名称',
                onPressed: onRename,
                constraints: const BoxConstraints(
                  minWidth: DsSizes.touchTarget,
                  minHeight: DsSizes.touchTarget,
                ),
                icon: Icon(
                  DsIcons.edit,
                  size: DsSizes.iconMd,
                  color: colors.textSecondary,
                ),
              ),
              Icon(
                DsIcons.chevronRight,
                color: colors.textTertiary,
                size: DsSizes.iconLg,
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              StatusPill(
                status: DsStatus.neutral,
                icon: DsIcons.calendar,
                label: formatArchiveTime(incident.archivedAt ?? 0),
              ),
              StatusPill(
                status: incident.autoArchived
                    ? DsStatus.caution
                    : DsStatus.safe,
                icon: incident.autoArchived
                    ? DsIcons.time
                    : DsIcons.taskCheck,
                label: archiveMethodLabel(incident.autoArchived),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.md),
            child: Divider(height: 1, color: colors.border),
          ),
          Padding(
            padding: const EdgeInsets.only(right: DsSpacing.sm),
            child: _ArchivedStatsGrid(incident: incident),
          ),
        ],
      ),
    );
  }
}

class _ArchivedStatsGrid extends StatelessWidget {
  const _ArchivedStatsGrid({required this.incident});

  final ArchivedIncidentView incident;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final items = <_StatCellData>[
      _StatCellData(label: '参战站点', value: '${incident.forceStationCount}'),
      _StatCellData(
        label: incident.unknownVehicleStationCount > 0 ? '已知车辆' : '车辆',
        value:
            '${incident.vehicleCount}${incident.unknownVehicleStationCount > 0 ? '+' : ''}',
      ),
      _StatCellData(
        label: incident.unknownPersonnelStationCount > 0 ? '已知人员' : '人员',
        value:
            '${incident.personnelCount}${incident.unknownPersonnelStationCount > 0 ? '+' : ''}',
      ),
      if (incident.unresolvedActiveCount > 0)
        _StatCellData(
          label: '未确认离场',
          value: '${incident.unresolvedActiveCount}',
          valueColor: colors.cautionText,
        ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final columns = constraints.maxWidth < 340
            ? 2
            : (items.length <= 3 ? items.length : 4);
        const spacing = DsSpacing.sm;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final item in items)
              SizedBox(
                width: itemWidth,
                child: _ArchivedStatTile(data: item),
              ),
          ],
        );
      },
    );
  }
}

@immutable
class _StatCellData {
  const _StatCellData({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;
}

class _ArchivedStatTile extends StatelessWidget {
  const _ArchivedStatTile({required this.data});

  final _StatCellData data;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return Container(
      padding: const EdgeInsets.all(DsSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: DsRadius.borderMd,
        border: Border.all(color: colors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            data.value,
            style: typo.metric.copyWith(
              color: data.valueColor ?? colors.textPrimary,
            ),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            data.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typo.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 复盘页身份概要卡片。
class ArchivedIncidentIdentityCard extends StatelessWidget {
  const ArchivedIncidentIdentityCard({super.key, required this.incident});

  final ArchivedIncidentView incident;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.brand.withValues(alpha: 0.14),
                  borderRadius: DsRadius.borderSm,
                ),
                child: Icon(
                  DsIcons.taskCheck,
                  color: colors.brandText,
                  size: DsSizes.iconMd,
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: Text(
                  '归档档案',
                  style: typo.caption.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              StatusPill(
                status: incident.autoArchived
                    ? DsStatus.caution
                    : DsStatus.safe,
                icon: incident.autoArchived
                    ? DsIcons.time
                    : DsIcons.taskCheck,
                label: archiveMethodLabel(incident.autoArchived),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          Text(
            incident.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: typo.headline.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            incident.number,
            style: typo.caption.copyWith(color: colors.textTertiary),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.md),
            child: Divider(height: 1, color: colors.border),
          ),
          Wrap(
            spacing: DsSpacing.lg,
            runSpacing: DsSpacing.sm,
            children: <Widget>[
              _ArchiveTimePair(
                label: '归档时间',
                value: formatArchiveTime(incident.archivedAt ?? 0),
              ),
              _ArchiveTimePair(
                label: '最后活动',
                value: formatArchiveTime(incident.lastActivityAt),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArchiveTimePair extends StatelessWidget {
  const _ArchiveTimePair({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: ds.typography.caption.copyWith(color: colors.textTertiary),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          value,
          style: ds.typography.bodyTabular.copyWith(
            color: colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 复盘页分区标题。
class ArchivedSectionHeader extends StatelessWidget {
  const ArchivedSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Row(
      children: <Widget>[
        Icon(icon, size: DsSizes.iconMd, color: colors.brandText),
        const SizedBox(width: DsSpacing.sm),
        Expanded(
          child: Text(
            title,
            style: ds.typography.title.copyWith(color: colors.textPrimary),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: ds.typography.captionTabular.copyWith(
              color: colors.textTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}
