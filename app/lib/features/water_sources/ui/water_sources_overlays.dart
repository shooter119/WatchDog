import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/water_sources_store.dart';

/// 周边水源全屏地图模式的顶部悬浮筛选条。
class WaterMapFilterOverlay extends StatelessWidget {
  final WaterSourcesStore store;
  final WaterSourceSummary summary;

  const WaterMapFilterOverlay({
    super.key,
    required this.store,
    required this.summary,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _OverlayFilterChip(
            key: const Key('water-filter-all'),
            label: '全部 (${summary.total})',
            selected: store.categoryFilter == null,
            onTap: () => store.setCategoryFilter(null),
          ),
          const SizedBox(width: DsSpacing.sm),
          _OverlayFilterChip(
            key: const Key('water-filter-hydrant'),
            label: '消火栓 (${summary.hydrant})',
            selected: store.categoryFilter == WaterSourceCategory.hydrant,
            onTap: () => store.setCategoryFilter(WaterSourceCategory.hydrant),
          ),
          const SizedBox(width: DsSpacing.sm),
          _OverlayFilterChip(
            key: const Key('water-filter-natural'),
            label: '天然水源 (${summary.natural})',
            selected: store.categoryFilter == WaterSourceCategory.natural,
            onTap: () => store.setCategoryFilter(WaterSourceCategory.natural),
          ),
          const SizedBox(width: DsSpacing.sm),
          _OverlayFilterChip(
            key: const Key('water-filter-pump_connector'),
            label: '接合器 (${summary.pumpConnector})',
            selected: store.categoryFilter == WaterSourceCategory.pumpConnector,
            onTap: () =>
                store.setCategoryFilter(WaterSourceCategory.pumpConnector),
          ),
          const SizedBox(width: DsSpacing.sm),
          _OverlayFilterChip(
            key: const Key('water-filter-only-available'),
            label: '仅看可用',
            selected: store.onlyAvailable,
            onTap: () => store.setOnlyAvailable(!store.onlyAvailable),
          ),
        ],
      ),
    );
  }
}

class _OverlayFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OverlayFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Material(
      color: selected
          ? colors.brand
          : colors.surface.withValues(alpha: 0.94),
      shape: RoundedRectangleBorder(
        borderRadius: DsRadius.borderPill,
        side: BorderSide(color: selected ? colors.brand : colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            label,
            style: ds.typography.caption.copyWith(
              color: selected ? colors.onBrand : colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// 十字准星选点底部确认面板。
class WaterPickingPanel extends StatelessWidget {
  final WaterSourcesStore store;
  final VoidCallback onConfirm;

  const WaterPickingPanel({
    super.key,
    required this.store,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final pos = store.pickCenter;
    final isReposition = store.editingCoordTarget != null;

    return Padding(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: SurfaceCard(
        level: DsSurfaceLevel.raised,
        padding: const EdgeInsets.all(DsSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isReposition
                  ? '调整「${store.editingCoordTarget!.name}」坐标'
                  : '拖动卫星图微调中心十字准星',
              style: ds.typography.title.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(
              pos != null
                  ? '当前准星 (GCJ-02)：${pos.lat.toStringAsFixed(6)}, ${pos.lng.toStringAsFixed(6)}'
                  : '正在读取地图中心坐标...',
              style: ds.typography.bodyTabular.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(
              '确认位置后手填点位简称即可保存，有效修正 GPS 漂移。',
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: DsSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: CommandButton(
                    key: const Key('water-pick-cancel'),
                    label: '取消',
                    variant: CommandButtonVariant.secondary,
                    expanded: true,
                    onPressed: store.cancelPicking,
                  ),
                ),
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: CommandButton(
                    key: const Key('water-pick-confirm'),
                    label: isReposition ? '保存新坐标' : '确认此位置',
                    variant: CommandButtonVariant.primary,
                    expanded: true,
                    enabled: pos != null,
                    onPressed: pos == null ? null : onConfirm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 周边水源通用语义提示横幅。
class WaterStatusBanner extends StatelessWidget {
  final DsStatus status;
  final String text;
  final Widget? action;

  const WaterStatusBanner({
    super.key,
    required this.status,
    required this.text,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pair = ds.colors.statusColors(status);
    return SurfaceCard(
      level: DsSurfaceLevel.raised,
      accentStatus: status,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            status == DsStatus.alarm
                ? Icons.error_outline_rounded
                : Icons.warning_amber_rounded,
            size: DsSizes.iconMd,
            color: pair.text,
          ),
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
          if (action != null) ...[
            const SizedBox(width: DsSpacing.xs),
            action!,
          ],
        ],
      ),
    );
  }
}

/// 定位降级提示条（地图叠加态与纯列表降级态复用）。
class WaterLocationDegradedBanner extends StatelessWidget {
  final WaterSourcesStore store;
  final bool inOverlay;

  const WaterLocationDegradedBanner({
    super.key,
    required this.store,
    this.inOverlay = false,
  });

  @override
  Widget build(BuildContext context) {
    final String message;
    final VoidCallback? secondaryAction;
    final String? secondaryLabel;
    switch (store.locStatus) {
      case WaterLocStatus.permissionDenied:
        message = inOverlay
            ? '未授予定位权限，无法自动定位到当前位置'
            : '未授予精确定位权限，已降级按更新时间展示水源列表';
        secondaryAction = () => unawaited(store.openAppSettings());
        secondaryLabel = '去授权';
      case WaterLocStatus.serviceDisabled:
        message = inOverlay
            ? '系统定位服务未开启，请开启后重试'
            : '系统定位服务未开启，已降级按更新时间展示水源列表';
        secondaryAction = () => unawaited(store.openLocationSettings());
        secondaryLabel = '去开启';
      case WaterLocStatus.fixFailed:
      case WaterLocStatus.loading:
      case WaterLocStatus.ok:
        message = inOverlay
            ? '当前位置获取失败，可手动拖动地图查看'
            : '当前位置获取失败，已降级按更新时间展示水源列表';
        secondaryAction = null;
        secondaryLabel = null;
    }

    final banner = WaterStatusBanner(
      key: const Key('water-location-degraded-banner'),
      status: DsStatus.caution,
      text: message,
      action: Wrap(
        spacing: 2,
        children: [
          if (secondaryAction != null && secondaryLabel != null)
            TextButton(onPressed: secondaryAction, child: Text(secondaryLabel)),
          TextButton(
            key: const Key('water-location-retry'),
            onPressed: () => unawaited(store.retryLocation()),
            child: const Text('重试定位'),
          ),
        ],
      ),
    );
    if (inOverlay) return banner;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.sm,
        DsSpacing.pageMargin,
        0,
      ),
      child: banner,
    );
  }
}

/// 纯列表降级态的搜索框与类别筛选条。
class WaterDegradedFilterBar extends StatelessWidget {
  final WaterSourcesStore store;
  final WaterSourceSummary summary;
  final TextEditingController searchController;

  const WaterDegradedFilterBar({
    super.key,
    required this.store,
    required this.summary,
    required this.searchController,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.sm,
        DsSpacing.pageMargin,
        DsSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('water-search-input'),
            controller: searchController,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索点位名称或备注（如水池、闷盖、楼栋）',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: store.searchQuery.isNotEmpty
                  ? IconButton(
                      onPressed: () {
                        searchController.clear();
                        store.setSearchQuery('');
                      },
                      icon: const Icon(Icons.clear, size: 18),
                    )
                  : null,
              filled: true,
              fillColor: colors.surface,
              border: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.border),
              ),
            ),
            onChanged: store.setSearchQuery,
          ),
          const SizedBox(height: DsSpacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  key: const Key('water-filter-all'),
                  label: Text('全部 (${summary.total})'),
                  selected: store.categoryFilter == null,
                  onSelected: (_) => store.setCategoryFilter(null),
                ),
                const SizedBox(width: DsSpacing.sm),
                ChoiceChip(
                  key: const Key('water-filter-hydrant'),
                  label: Text('消火栓 (${summary.hydrant})'),
                  selected: store.categoryFilter == WaterSourceCategory.hydrant,
                  onSelected: (_) =>
                      store.setCategoryFilter(WaterSourceCategory.hydrant),
                ),
                const SizedBox(width: DsSpacing.sm),
                ChoiceChip(
                  key: const Key('water-filter-natural'),
                  label: Text('天然水源 (${summary.natural})'),
                  selected: store.categoryFilter == WaterSourceCategory.natural,
                  onSelected: (_) =>
                      store.setCategoryFilter(WaterSourceCategory.natural),
                ),
                const SizedBox(width: DsSpacing.sm),
                ChoiceChip(
                  key: const Key('water-filter-pump_connector'),
                  label: Text('接合器 (${summary.pumpConnector})'),
                  selected:
                      store.categoryFilter == WaterSourceCategory.pumpConnector,
                  onSelected: (_) => store.setCategoryFilter(
                    WaterSourceCategory.pumpConnector,
                  ),
                ),
                const SizedBox(width: DsSpacing.sm),
                FilterChip(
                  key: const Key('water-filter-only-available'),
                  label: const Text('仅看可用'),
                  selected: store.onlyAvailable,
                  onSelected: store.setOnlyAvailable,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
