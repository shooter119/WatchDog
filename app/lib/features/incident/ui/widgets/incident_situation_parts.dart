import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/incident_force.dart';

/// 弹出警情改名 [CommandSheet]。
Future<String?> showIncidentRenameSheet(
  BuildContext context, {
  String initialTitle = '',
}) async {
  final ctrl = TextEditingController(text: initialTitle);
  final result = await showCommandSheet<String>(
    context: context,
    title: '修改警情名称',
    subtitle: '留空将恢复默认警情编号',
    builder: (BuildContext sheetContext) {
      final ds = sheetContext.ds;
      return TextField(
        key: const Key('incident-rename-field'),
        controller: ctrl,
        autofocus: true,
        maxLength: 120,
        style: ds.typography.body.copyWith(color: ds.colors.textPrimary),
        decoration: InputDecoration(
          hintText: '如：幸福小区住宅火灾',
          filled: true,
          fillColor: ds.colors.surfaceMuted,
          border: OutlineInputBorder(
            borderRadius: DsRadius.borderMd,
            borderSide: BorderSide(color: ds.colors.border),
          ),
        ),
      );
    },
    actionsBuilder: (BuildContext sheetContext) => <Widget>[
      CommandButton(
        label: '稍后',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(sheetContext).pop(),
      ),
      CommandButton(
        key: const Key('incident-rename-save-btn'),
        label: '保存',
        variant: CommandButtonVariant.primary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(sheetContext).pop(ctrl.text.trim()),
      ),
    ],
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
  return result;
}

/// 弹出退出当前警情二次确认 [CommandSheet]。
Future<bool> showIncidentExitConfirmSheet(BuildContext context) async {
  final confirmed = await showCommandSheet<bool>(
    context: context,
    title: '退出当前警情',
    builder: (BuildContext ctx) => Text(
      '退出后不会归档警情，仍可从正在处置的警情列表重新加入。',
      style: ctx.ds.typography.body.copyWith(
        color: ctx.ds.colors.textSecondary,
      ),
    ),
    actionsBuilder: (BuildContext ctx) => <Widget>[
      CommandButton(
        label: '取消',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(false),
      ),
      CommandButton(
        key: const Key('incident-exit-confirm-btn'),
        label: '确认退出',
        variant: CommandButtonVariant.primary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    ],
  );
  return confirmed == true;
}

/// 弹出归档警情危险操作二次确认 [CommandSheet]，保留 `Key('incident-archive-confirm-btn')`。
Future<bool> showIncidentArchiveConfirmSheet(BuildContext context) async {
  final confirmed = await showCommandSheet<bool>(
    context: context,
    title: '归档警情',
    builder: (BuildContext ctx) => Text(
      '归档后现场数据只读，名称仍可在归档警情列表中修改。请确认处置已经结束。',
      style: ctx.ds.typography.body.copyWith(
        color: ctx.ds.colors.textSecondary,
      ),
    ),
    actionsBuilder: (BuildContext ctx) => <Widget>[
      CommandButton(
        label: '取消',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(false),
      ),
      CommandButton(
        key: const Key('incident-archive-confirm-btn'),
        label: '确认归档',
        variant: CommandButtonVariant.danger,
        size: CommandButtonSize.large,
        requireConfirmation: false,
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    ],
  );
  return confirmed == true;
}

/// 警情态势卡更多操作菜单按钮（改名 / 退出 / 归档，保留 `Key('incident-more-menu-btn')`）。
class IncidentMoreMenuButton extends StatelessWidget {
  const IncidentMoreMenuButton({
    super.key = const Key('incident-more-menu-btn'),
    required this.onRename,
    required this.onExit,
    required this.onArchive,
  });

  final VoidCallback onRename;
  final VoidCallback onExit;
  final VoidCallback onArchive;

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
        Icons.more_horiz_rounded,
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
              Icon(Icons.edit_outlined, size: 18, color: colors.textPrimary),
              const SizedBox(width: DsSpacing.sm),
              const Text('修改警情名称'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          key: const Key('exit-incident-menu-item'),
          value: 'exit',
          child: Row(
            children: <Widget>[
              Icon(Icons.logout_outlined, size: 18, color: colors.textPrimary),
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
              Icon(Icons.archive_outlined, size: 18, color: colors.alarmText),
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
                icon: Icons.group_add_outlined,
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
                icon: Icons.upload_file_outlined,
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
                icon: Icons.tune_rounded,
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
            Icons.local_shipping_outlined,
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
            icon: const Icon(Icons.edit_outlined, size: 20),
            color: colors.textSecondary,
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: '删除参战力量',
            icon: const Icon(Icons.close_rounded, size: 20),
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
