import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/location_share_store.dart';

/// 定位分享卡片内部辅助视图（信息行、WGS84 坐标槽位、告警横幅与错误卡片）。
class LocationShareReadyCards extends StatelessWidget {
  final LocationShareStore store;
  final VoidCallback onRelocate;
  final VoidCallback onOpenLocationSettings;

  const LocationShareReadyCards({
    super.key,
    required this.store,
    required this.onRelocate,
    required this.onOpenLocationSettings,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final draft = store.draft!;
    final text = store.previewText ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SurfaceCard(
          padding: const EdgeInsets.all(DsSpacing.lg),
          child: Column(
            children: [
              _infoRow(
                context,
                '警情',
                draft.incidentName.isEmpty ? '未选择警情' : draft.incidentName,
              ),
              _infoRow(
                context,
                '单位',
                draft.unitName.isEmpty ? '未填写单位' : draft.unitName,
              ),
              _infoRow(
                context,
                '地址',
                store.addressLoading
                    ? '正在查询地址…'
                    : (draft.address.isEmpty ? '地址暂不可用' : draft.address),
              ),
              _LocationCoordSlot(draft: draft),
            ],
          ),
        ),
        if (store.isStaleBlocked) ...[
          const SizedBox(height: DsSpacing.md),
          const LocationShareBanner(
            status: DsStatus.alarm,
            icon: DsIcons.statusTimeout,
            text: '定位已超过 5 分钟，不能直接分享。请重新定位后再发送。',
          ),
        ] else if (store.isStaleWarning) ...[
          const SizedBox(height: DsSpacing.md),
          const LocationShareBanner(
            status: DsStatus.caution,
            icon: DsIcons.time,
            text: '定位已超过 2 分钟，位置可能已变化，请结合现场情况核实。',
          ),
        ],
        if (draft.hasPoorAccuracy) ...[
          const SizedBox(height: DsSpacing.md),
          const LocationShareBanner(
            status: DsStatus.caution,
            icon: DsIcons.locationOff,
            text: '定位精度较差或未提供精度，接收方可能看到明显偏移。',
          ),
        ],
        if (store.addressFailed) ...[
          const SizedBox(height: DsSpacing.md),
          LocationShareBanner(
            status: DsStatus.neutral,
            icon: DsIcons.info,
            text: !draft.hasAmapLocation
                ? '地址或坐标转换未完成，已切换为 WGS84 坐标，仍可分享查看位置。'
                : '地址查询未完成，但高德位置链接仍可用。',
          ),
        ],
        const SizedBox(height: DsSpacing.md),
        SurfaceCard(
          padding: const EdgeInsets.all(DsSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '分享文案预览',
                style: ds.typography.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: DsSpacing.sm),
              SelectableText(
                text,
                style: ds.typography.caption.copyWith(
                  height: 1.5,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.md),
        Wrap(
          spacing: DsSpacing.sm,
          runSpacing: DsSpacing.sm,
          children: [
            CommandButton(
              key: const Key('location-share-relocate'),
              label: '重新定位',
              icon: DsIcons.myLocation,
              variant: CommandButtonVariant.secondary,
              onPressed: onRelocate,
            ),
            CommandButton(
              key: const Key('location-share-open-settings'),
              label: '打开定位设置',
              icon: DsIcons.myLocation,
              variant: CommandButtonVariant.secondary,
              onPressed: onOpenLocationSettings,
            ),
          ],
        ),
      ],
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final ds = context.ds;
    final colors = ds.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: ds.typography.caption.copyWith(
                color: colors.textTertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Text(
              value,
              style: ds.typography.bodyTabular.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationCoordSlot extends StatelessWidget {
  final LocationShareDraft draft;

  const _LocationCoordSlot({required this.draft});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final accuracyText = draft.accuracyMeters > 0
        ? '±${draft.accuracyMeters.toStringAsFixed(0)} m'
        : '精度未提供';

    return SurfaceCard(
      level: DsSurfaceLevel.flat,
      borderColor: colors.border,
      borderRadius: DsRadius.borderMd,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.lg,
        vertical: DsSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'WGS84',
                style: ds.typography.caption.copyWith(
                  color: colors.textTertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              StatusPill(
                status: draft.hasPoorAccuracy
                    ? DsStatus.caution
                    : DsStatus.neutral,
                label: accuracyText,
                icon: DsIcons.myLocation,
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            '${draft.lat.toStringAsFixed(6)}, ${draft.lon.toStringAsFixed(6)}',
            style: ds.typography.metric.copyWith(
              fontSize: 18,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          Row(
            children: [
              Icon(
                DsIcons.time,
                size: 14,
                color: colors.textTertiary,
              ),
              const SizedBox(width: DsSpacing.xs),
              Expanded(
                child: Text(
                  '定位时间 ${formatLocationTime(draft.locatedAt)}',
                  style: ds.typography.captionTabular.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 定位分享状态提示横幅。
class LocationShareBanner extends StatelessWidget {
  final DsStatus status;
  final IconData icon;
  final String text;

  const LocationShareBanner({
    super.key,
    required this.status,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pair = ds.colors.statusColors(status);
    return SurfaceCard(
      accentStatus: status,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: DsSizes.iconMd, color: pair.text),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ds.typography.caption.copyWith(
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

/// 定位分享错误状态卡片。
class LocationShareProblemCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  const LocationShareProblemCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.xl),
      child: Column(
        children: [
          Icon(icon, size: 40, color: colors.textSecondary),
          const SizedBox(height: DsSpacing.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: ds.typography.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.sm),
          Text(
            body,
            textAlign: TextAlign.center,
            style: ds.typography.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: DsSpacing.lg),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(height: DsSpacing.sm),
            actions[i],
          ],
        ],
      ),
    );
  }
}
