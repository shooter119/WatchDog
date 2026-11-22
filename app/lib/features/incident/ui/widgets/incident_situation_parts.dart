import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/incident_force.dart';
import 'incident_category_chip.dart';

export '../sheets/incident_action_sheets.dart';

/// 警情态势卡更多操作菜单按钮（改名 / 退出 / 归档，保留 `Key('incident-more-menu-btn')`）。
class IncidentMoreMenuButton extends StatelessWidget {
  const IncidentMoreMenuButton({
    super.key = const Key('incident-more-menu-btn'),
    required this.onRename,
    required this.onExit,
    required this.onArchive,
    this.renameLabel = '修改警情名称',
  });

  final VoidCallback onRename;
  final VoidCallback onExit;
  final VoidCallback onArchive;
  final String renameLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return PopupMenuButton<String>(
      tooltip: '更多警情操作',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: DsSizes.touchTarget,
        minHeight: DsSizes.touchTarget,
      ),
      icon: Icon(
        DsIcons.moreHoriz,
        size: DsSizes.iconMd,
        color: colors.textSecondary,
      ),
      onSelected: (String value) {
        switch (value) {
          case 'rename':
            onRename();
          case 'exit':
            onExit();
          case 'archive':
            onArchive();
        }
      },
      itemBuilder: (BuildContext _) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: const Key('rename-incident'),
          value: 'rename',
          child: Row(
            children: <Widget>[
              Icon(DsIcons.edit, size: 18, color: colors.textPrimary),
              const SizedBox(width: DsSpacing.sm),
              Text(renameLabel),
            ],
          ),
        ),
        PopupMenuItem<String>(
          key: const Key('exit-incident-menu-item'),
          value: 'exit',
          child: Row(
            children: <Widget>[
              Icon(DsIcons.logout, size: 18, color: colors.textPrimary),
              const SizedBox(width: DsSpacing.sm),
              const Text('退出当前警情'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          key: const Key('archive-incident-menu-item'),
          value: 'archive',
          child: Row(
            children: <Widget>[
              Icon(DsIcons.archive, size: 18, color: colors.alarmText),
              const SizedBox(width: DsSpacing.sm),
              Text(
                '归档警情',
                style: TextStyle(
                  color: colors.alarmText,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 警情态势卡展开区三联操作条（登记力量 / 信息导入 / 警情调整），自适应横排与堆叠排版。
class IncidentActionStrip extends StatelessWidget {
  const IncidentActionStrip({
    super.key,
    this.onAddForce,
    this.onImportInfo,
    this.onAdjustIncident,
  });

  final VoidCallback? onAddForce;
  final VoidCallback? onImportInfo;
  final VoidCallback? onAdjustIncident;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final labelStyle = ds.typography.caption.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w700,
    );

    return SurfaceCard(
      level: DsSurfaceLevel.flat,
      borderColor: colors.border,
      borderRadius: DsRadius.borderMd,
      padding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final scaler = MediaQuery.textScalerOf(context);
          final direction = Directionality.of(context);
          var maxLabelWidth = 0.0;
          for (final label in const <String>['登记力量', '信息导入', '警情调整']) {
            final painter = TextPainter(
              text: TextSpan(text: label, style: labelStyle),
              textScaler: scaler,
              textDirection: direction,
              maxLines: 1,
            )..layout();
            maxLabelWidth = math.max(maxLabelWidth, painter.width);
            painter.dispose();
          }
          final cellWidth = (constraints.maxWidth - 2.0) / 3.0;
          final stacked =
              !constraints.maxWidth.isFinite ||
              (maxLabelWidth + 36.0 > cellWidth);
          return Row(
            children: <Widget>[
              _ActionStripCell(
                label: '登记力量',
                icon: DsIcons.userAdd,
                stacked: stacked,
                labelStyle: labelStyle,
                onTap: onAddForce,
              ),
              SizedBox(
                height: stacked ? 30 : 22,
                child: VerticalDivider(width: 1, color: colors.border),
              ),
              _ActionStripCell(
                label: '信息导入',
                icon: DsIcons.toolTacticalBrief,
                stacked: stacked,
                labelStyle: labelStyle,
                onTap: onImportInfo,
              ),
              SizedBox(
                height: stacked ? 30 : 22,
                child: VerticalDivider(width: 1, color: colors.border),
              ),
              _ActionStripCell(
                label: '警情调整',
                icon: DsIcons.edit,
                stacked: stacked,
                labelStyle: labelStyle,
                onTap: onAdjustIncident,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ActionStripCell extends StatelessWidget {
  const _ActionStripCell({
    required this.label,
    required this.icon,
    required this.stacked,
    required this.labelStyle,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final bool stacked;
  final TextStyle labelStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final labelWidget = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false, style: labelStyle),
    );
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: stacked ? DsSizes.primaryAction : DsSizes.touchTarget,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.xs,
              vertical: DsSpacing.xs,
            ),
            child: stacked
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(icon, size: 18, color: colors.textPrimary),
                      const SizedBox(height: DsSpacing.xs),
                      labelWidget,
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(icon, size: 16, color: colors.textPrimary),
                      const SizedBox(width: DsSpacing.xs),
                      Flexible(child: labelWidget),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 参战力量单行卡片（48dp 编辑与删除触控热区）。
class IncidentForceItemRow extends StatelessWidget {
  const IncidentForceItemRow({
    super.key,
    required this.force,
    this.onEdit,
    this.onRemove,
  });

  final IncidentForce force;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      level: DsSurfaceLevel.flat,
      borderColor: colors.border,
      borderRadius: DsRadius.borderMd,
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.sm,
        DsSpacing.xs,
        DsSpacing.xs,
        DsSpacing.xs,
      ),
      onTap: onEdit,
      child: Row(
        children: <Widget>[
          Icon(
            DsIcons.truck,
            size: DsSizes.iconMd,
            color: colors.textSecondary,
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              '${force.stationName} ${force.quantityLabel}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ds.typography.bodyTabular.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: '编辑参战力量',
            icon: const Icon(DsIcons.edit, size: 20),
            color: colors.textSecondary,
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: '删除参战力量',
            icon: const Icon(DsIcons.close, size: 20),
            color: colors.textSecondary,
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// 警情态势卡摘要栏中的地点与出动力量压缩行。
class IncidentCollapsedLocationForces extends StatelessWidget {
  const IncidentCollapsedLocationForces({
    super.key,
    required this.hasRealLocation,
    required this.locationText,
    required this.expanded,
    required this.compactForces,
  });

  final bool hasRealLocation, expanded;
  final String locationText, compactForces;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (hasRealLocation)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(DsIcons.locationPin, size: DsSizes.iconSm, color: colors.textSecondary),
              ),
              const SizedBox(width: DsSpacing.xs),
              Expanded(
                child: IncidentAntiOrphanText(
                  text: locationText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: typo.caption.copyWith(color: colors.textSecondary, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        if (hasRealLocation && !expanded && compactForces.isNotEmpty) const SizedBox(height: DsSpacing.xs),
        if (!expanded && compactForces.isNotEmpty)
          Row(
            key: const Key('incident-collapsed-forces'),
            children: <Widget>[
              Icon(DsIcons.truck, size: DsSizes.iconSm, color: colors.textSecondary),
              const SizedBox(width: DsSpacing.xs),
              Expanded(
                child: Text(
                  compactForces,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.caption.copyWith(color: colors.textSecondary, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          )
        else if (!hasRealLocation)
          Row(
            children: <Widget>[
              Icon(DsIcons.roster, size: DsSizes.iconSm, color: colors.textSecondary),
              const SizedBox(width: DsSpacing.xs),
              Expanded(
                child: Text(
                  expanded ? '收起警情详情' : '展开警情管理与力量',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.caption.copyWith(color: colors.textSecondary, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
