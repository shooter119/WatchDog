import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/route_models.dart';
import '../data/models/route_traffic_info.dart';

export 'route_traffic_header_cards.dart';

/// 路线概览卡（策略切换胶囊、等宽数字耗时/里程/红绿灯、双通道态势胶囊与拥堵条）。
class RouteOverviewCard extends StatelessWidget {
  final List<DrivingRoutePlan> routes;
  final int selectedRouteIndex;
  final DrivingRoutePlan selectedRoute;
  final ValueChanged<int> onSelectRoute;

  const RouteOverviewCard({
    super.key,
    required this.routes,
    required this.selectedRouteIndex,
    required this.selectedRoute,
    required this.onSelectRoute,
  });

  static DsStatus _statusForOverall(String overallStatus) {
    switch (overallStatus) {
      case '严重拥堵':
        return DsStatus.timeout;
      case '拥堵':
      case '局部拥堵':
        return DsStatus.alarm;
      case '局部缓行':
      case '缓行':
        return DsStatus.caution;
      default:
        return DsStatus.safe;
    }
  }

  static IconData _iconForOverall(DsStatus status) {
    switch (status) {
      case DsStatus.timeout:
      case DsStatus.alarm:
        return DsIcons.traffic;
      case DsStatus.caution:
        return DsIcons.warning;
      case DsStatus.safe:
      case DsStatus.neutral:
        return DsIcons.checkCircleFill;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final summary = selectedRoute.trafficSummary;
    final total = summary.totalMeters > 0
        ? summary.totalMeters
        : selectedRoute.distanceMeters;
    final status = _statusForOverall(selectedRoute.overallStatus);

    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (routes.length > 1) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < routes.length; i++) ...[
                    if (i > 0) const SizedBox(width: DsSpacing.sm),
                    _StrategyChip(
                      key: Key('route-strategy-chip-$i'),
                      label: routes[i].strategy.trim().isNotEmpty
                          ? routes[i].strategy.trim()
                          : (i == 0 ? '时间最短' : '备选路线'),
                      selected: selectedRouteIndex == i,
                      onTap: () => onSelectRoute(i),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: DsSpacing.md),
          ],
          Wrap(
            spacing: DsSpacing.md,
            runSpacing: DsSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                RouteTrafficInfo.formatDuration(selectedRoute.durationSeconds),
                style: ds.typography.metricLarge.copyWith(
                  color: colors.brandText,
                ),
              ),
              Text(
                RouteTrafficInfo.formatDistance(selectedRoute.distanceMeters),
                style: ds.typography.metric.copyWith(
                  fontSize: 18,
                  color: colors.textPrimary,
                ),
              ),
              Text(
                '红绿灯 ${selectedRoute.trafficLights} 个',
                style: ds.typography.captionTabular.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusPill(
                status: status,
                icon: _iconForOverall(status),
                label: '路况：${selectedRoute.overallStatus}',
              ),
              if (summary.totalMeters > 0)
                Text(
                  '畅通 ${RouteTrafficInfo.formatDistance(summary.smoothMeters, compactUnit: true)}',
                  style: ds.typography.captionTabular.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
          if (summary.totalMeters > 0 && total > 0) ...[
            const SizedBox(height: DsSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                width: double.infinity,
                height: 6,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (summary.smoothMeters > 0)
                      Expanded(
                        flex: summary.smoothMeters,
                        child: ColoredBox(color: colors.safeFill),
                      ),
                    if (summary.slowMeters > 0)
                      Expanded(
                        flex: summary.slowMeters,
                        child: ColoredBox(color: colors.cautionFill),
                      ),
                    if (summary.jamMeters > 0)
                      Expanded(
                        flex: summary.jamMeters,
                        child: ColoredBox(color: colors.alarmFill),
                      ),
                    if (summary.severeJamMeters > 0)
                      Expanded(
                        flex: summary.severeJamMeters,
                        child: ColoredBox(color: colors.timeoutFill),
                      ),
                    if (summary.unknownMeters > 0)
                      Expanded(
                        flex: summary.unknownMeters,
                        child: ColoredBox(color: colors.border),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StrategyChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StrategyChip({
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
      color: selected ? colors.brand : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: DsRadius.borderSm,
        side: BorderSide(color: selected ? colors.brand : colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: ds.typography.caption.copyWith(
              color: selected ? colors.onBrand : colors.textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// 沿途拥堵/缓行路段卡片。
class RouteCongestionCard extends StatelessWidget {
  final DrivingRoutePlan route;

  const RouteCongestionCard({super.key, required this.route});

  static DsStatus _segmentStatus(String status) {
    switch (status) {
      case '严重拥堵':
        return DsStatus.timeout;
      case '拥堵':
        return DsStatus.alarm;
      default:
        return DsStatus.caution;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final segments = route.congestedSegments;
    final hasJam = segments.isNotEmpty;

    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasJam
                    ? DsIcons.warning
                    : DsIcons.checkCircle,
                size: DsSizes.iconMd,
                color: hasJam ? colors.cautionText : colors.safeText,
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  hasJam ? '沿途拥堵/缓行路段' : '路况态势',
                  style: ds.typography.title.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          if (hasJam)
            for (final seg in segments)
              Builder(
                builder: (context) {
                  final pair = colors.statusColors(
                    _segmentStatus(seg.status),
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: pair.fill,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: DsSpacing.sm),
                        Expanded(
                          child: Text(
                            seg.road,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ds.typography.body.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: DsSpacing.sm),
                        Flexible(
                          child: Text(
                            '${seg.status} ${RouteTrafficInfo.formatDistance(seg.distanceMeters, compactUnit: true)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ds.typography.captionTabular.copyWith(
                              color: pair.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              )
          else
            Text(
              '当前路线全线畅通，无明显拥堵路段。',
              style: ds.typography.body.copyWith(
                color: colors.safeText,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

/// 主要途经道路与可展开分段路线卡片。
class RouteRoadsCard extends StatelessWidget {
  final DrivingRoutePlan route;
  final bool stepsExpanded;
  final VoidCallback onToggleSteps;

  const RouteRoadsCard({
    super.key,
    required this.route,
    required this.stepsExpanded,
    required this.onToggleSteps,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;

    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                DsIcons.altRoute,
                size: DsSizes.iconMd,
                color: colors.brand,
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  '主要途经道路',
                  style: ds.typography.title.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          if (route.roads.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < route.roads.length; i++) ...[
                  if (i > 0)
                    Icon(
                      DsIcons.arrowRight,
                      size: 14,
                      color: colors.textSecondary,
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.sm,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: DsRadius.borderSm,
                    ),
                    child: Text(
                      route.roads[i],
                      style: ds.typography.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            )
          else
            Text(
              '未获取到途经道路名称',
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          if (route.steps.isNotEmpty) ...[
            Divider(height: 24, color: colors.border),
            InkWell(
              borderRadius: DsRadius.borderSm,
              onTap: onToggleSteps,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        stepsExpanded
                            ? '收起详细分段'
                            : '查看详细分段路线（${route.steps.length} 段）',
                        style: ds.typography.caption.copyWith(
                          color: colors.brandText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      stepsExpanded
                          ? DsIcons.chevronUp
                          : DsIcons.chevronDown,
                      color: colors.brandText,
                      size: DsSizes.iconMd,
                    ),
                  ],
                ),
              ),
            ),
            if (stepsExpanded) ...[
              const SizedBox(height: DsSpacing.sm),
              for (var i = 0; i < route.steps.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}.',
                        style: ds.typography.captionTabular.copyWith(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: DsSpacing.sm),
                      Expanded(
                        child: Text(
                          route.steps[i].instruction,
                          style: ds.typography.caption.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: DsSpacing.sm),
                      Text(
                        RouteTrafficInfo.formatDistance(
                          route.steps[i].distanceMeters,
                          compactUnit: true,
                        ),
                        style: ds.typography.captionTabular.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
