import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/route_models.dart';
import '../data/models/route_traffic_info.dart';

/// 现场地图底栏事发地预警区（粗粒度降级预警，或非降级下的多候选地点切换提示）。
class SceneMapTelemetryAlertSection extends StatelessWidget {
  final RouteTrafficInfo? info;
  final VoidCallback? onAmapSearch;
  final VoidCallback? onOpenCandidates;

  const SceneMapTelemetryAlertSection({
    super.key,
    required this.info,
    this.onAmapSearch,
    this.onOpenCandidates,
  });

  @override
  Widget build(BuildContext context) {
    final dest = info?.destination;
    final candidates = info?.candidates ?? const <RouteDestinationCandidate>[];
    if (dest?.isCoarse == true) {
      return Padding(
        padding: const EdgeInsets.only(top: DsSpacing.sm),
        child: SceneMapCoarseWarning(
          destination: dest!,
          hasCandidates: candidates.isNotEmpty,
          onAmapSearch: onAmapSearch,
          onOpenCandidates: onOpenCandidates,
        ),
      );
    }
    if (candidates.length > 1 && onOpenCandidates != null) {
      final ds = context.ds;
      return Padding(
        padding: const EdgeInsets.only(top: DsSpacing.xs),
        child: Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            key: const Key('scene-map-switch-candidate'),
            onTap: onOpenCandidates,
            borderRadius: DsRadius.borderSm,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Text(
                '发现多处候选地点 · 切换候选点',
                style: ds.typography.caption.copyWith(
                  color: ds.colors.brandText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// 现场地图底栏精度降级预警条（提醒坐标落于乡镇/区县级并引导高德搜原址或切换候选）。
class SceneMapCoarseWarning extends StatelessWidget {
  final RouteEndpointInfo destination;
  final bool hasCandidates;
  final VoidCallback? onAmapSearch;
  final VoidCallback? onOpenCandidates;

  const SceneMapCoarseWarning({
    super.key,
    required this.destination,
    required this.hasCandidates,
    this.onAmapSearch,
    this.onOpenCandidates,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final cautionPair = colors.statusColors(DsStatus.caution);
    final level = destination.precisionLevel.trim().isNotEmpty
        ? destination.precisionLevel.trim()
        : '乡镇/区县';

    return Container(
      key: const Key('scene-map-coarse-warning'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: cautionPair.pillBg,
        borderRadius: DsRadius.borderSm,
        border: Border.all(color: cautionPair.fill.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  DsIcons.warning,
                  size: 14,
                  color: cautionPair.text,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '仅定位至$level级，坐标可能偏移',
                  style: ds.typography.caption.copyWith(
                    color: cautionPair.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: DsSpacing.md,
            runSpacing: 4,
            children: [
              InkWell(
                key: const Key('scene-map-amap-search'),
                onTap: onAmapSearch,
                borderRadius: DsRadius.borderSm,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(DsIcons.search, size: 14, color: colors.brandText),
                      const SizedBox(width: 4),
                      Text(
                        '高德搜原址',
                        style: ds.typography.caption.copyWith(
                          color: colors.brandText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (hasCandidates)
                InkWell(
                  key: const Key('scene-map-switch-candidate'),
                  onTap: onOpenCandidates,
                  borderRadius: DsRadius.borderSm,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(DsIcons.swap, size: 14, color: colors.brandText),
                        const SizedBox(width: 4),
                        Text(
                          '切换候选点',
                          style: ds.typography.caption.copyWith(
                            color: colors.brandText,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
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
