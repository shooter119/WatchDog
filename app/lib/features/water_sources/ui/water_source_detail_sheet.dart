import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/china_coord.dart';
import '../state/water_sources_store.dart';
import 'water_source_card.dart';

/// 弹出水源点位详情底栏（Design System v3.0 `CommandSheet`）。
Future<void> showWaterSourceDetailSheet(
  BuildContext context, {
  required WaterSourcesStore store,
  required WaterSource initialItem,
  required void Function(String message) onToast,
  required VoidCallback Function(WaterSource current) onEdit,
  required VoidCallback Function(WaterSource current) onReposition,
  required VoidCallback Function(WaterSource current) onDelete,
}) {
  var current = initialItem;
  var toggling = false;

  return showCommandSheet<void>(
    context: context,
    title: current.name,
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final ds = ctx.ds;
          final colors = ds.colors;
          final dist = store.distanceFor(current);

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WaterSourceCategoryBadge(
                    category: current.category,
                    available: current.isAvailable,
                  ),
                  const SizedBox(width: DsSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          current.category.label,
                          style: ds.typography.body.copyWith(
                            color: colors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (dist != null) ...[
                          const SizedBox(height: DsSpacing.xs),
                          Text(
                            '直线 ${ChinaCoord.formatDistance(dist)}',
                            style: ds.typography.captionTabular.copyWith(
                              color: colors.brandText,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  WaterSourceStatusPill(status: current.status),
                ],
              ),
              const SizedBox(height: DsSpacing.md),
              SurfaceCard(
                level: DsSurfaceLevel.flat,
                borderColor: colors.border,
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.md,
                  vertical: DsSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        current.isAvailable
                            ? '当前状态：可用（点击可快速标为不可用）'
                            : '当前状态：不可用（点击可快速恢复可用）',
                        style: ds.typography.caption.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    CommandButton(
                      key: const Key('water-detail-toggle-status'),
                      label: current.isAvailable ? '标为不可用' : '标为可用',
                      variant: CommandButtonVariant.secondary,
                      isLoading: toggling,
                      enabled: !toggling,
                      onPressed: () async {
                        setSheetState(() => toggling = true);
                        final nextStatus = current.isAvailable
                            ? WaterSourceStatus.unavailable
                            : WaterSourceStatus.available;
                        try {
                          final updated = await store.updateWaterSource(
                            current.id,
                            status: nextStatus,
                          );
                          if (!ctx.mounted) return;
                          setSheetState(() {
                            current = updated;
                            toggling = false;
                          });
                          onToast('已标记为「${updated.status.label}」');
                        } catch (e) {
                          if (!ctx.mounted) return;
                          setSheetState(() => toggling = false);
                          onToast(store.friendlyError(e));
                        }
                      },
                    ),
                  ],
                ),
              ),
              if (current.category == WaterSourceCategory.natural &&
                  current.intakeMethods.isNotEmpty) ...[
                const SizedBox(height: DsSpacing.md),
                Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.xs,
                  children: [
                    for (final m in current.intakeMethods)
                      StatusPill(
                        status: DsStatus.neutral,
                        icon: DsIcons.toolWaterSources,
                        label: m.label,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: DsSpacing.md),
              Text(
                current.hasNote ? current.note : '暂无备注',
                style: ds.typography.body.copyWith(
                  color: current.hasNote
                      ? colors.textPrimary
                      : colors.textTertiary,
                ),
              ),
              const SizedBox(height: DsSpacing.md),
              Text(
                'GCJ-02: ${current.lat.toStringAsFixed(6)}, ${current.lng.toStringAsFixed(6)}',
                style: ds.typography.captionTabular.copyWith(
                  color: colors.textTertiary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '最近维护：${current.latestActorName} · ${_formatTimestamp(current.updatedAt > 0 ? current.updatedAt : current.createdAt)}',
                style: ds.typography.captionTabular.copyWith(
                  color: colors.textTertiary,
                ),
              ),
              const SizedBox(height: DsSpacing.lg),
              Wrap(
                spacing: DsSpacing.sm,
                runSpacing: DsSpacing.sm,
                children: [
                  CommandButton(
                    key: const Key('water-detail-edit'),
                    label: '编辑',
                    icon: DsIcons.edit,
                    variant: CommandButtonVariant.secondary,
                    onPressed: () {
                      Navigator.pop(ctx);
                      onEdit(current)();
                    },
                  ),
                  if (store.canRenderMap)
                    CommandButton(
                      key: const Key('water-detail-reposition'),
                      label: '调坐标',
                      icon: DsIcons.myLocation,
                      variant: CommandButtonVariant.secondary,
                      onPressed: () {
                        Navigator.pop(ctx);
                        onReposition(current)();
                      },
                    ),
                  CommandButton(
                    key: const Key('water-detail-delete'),
                    label: '删除',
                    icon: DsIcons.delete,
                    variant: CommandButtonVariant.danger,
                    requireConfirmation: false,
                    onPressed: () {
                      Navigator.pop(ctx);
                      onDelete(current)();
                    },
                  ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
}

/// 弹出软删除二次确认底栏（遵循 DS v3.0 危险操作二次确认规范）。
Future<bool> showWaterSourceDeleteConfirmSheet(
  BuildContext context, {
  required WaterSource item,
}) async {
  final confirmed = await showCommandSheet<bool>(
    context: context,
    title: '删除水源点位',
    builder: (sheetCtx) {
      final ds = sheetCtx.ds;
      return Text(
        '确定删除「${item.name}」吗？删除后 60 秒内可在底部提示条一键撤销。',
        style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
      );
    },
    actionsBuilder: (sheetCtx) => [
      CommandButton(
        label: '取消',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(sheetCtx).pop(false),
      ),
      CommandButton(
        key: const Key('water-delete-confirm'),
        label: '删除',
        variant: CommandButtonVariant.danger,
        size: CommandButtonSize.large,
        requireConfirmation: false,
        onPressed: () => Navigator.of(sheetCtx).pop(true),
      ),
    ],
  );
  return confirmed == true;
}

String _formatTimestamp(int ms) {
  if (ms <= 0) return '未知时间';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}
