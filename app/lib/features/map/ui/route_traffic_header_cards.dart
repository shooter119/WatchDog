import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/route_models.dart';
import '../data/models/route_traffic_info.dart';

/// 事发地气象与火场风向卡片（置顶展示）。
class RouteWeatherCard extends StatelessWidget {
  final RouteTrafficInfo info;

  const RouteWeatherCard({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final live = info.weather;
    final forecast = info.forecast;
    if (live == null && forecast == null && info.weatherLine == null) {
      return const SizedBox.shrink();
    }

    final ds = context.ds;
    final colors = ds.colors;
    final cautionPair = colors.statusColors(DsStatus.caution);

    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.wb_sunny_outlined,
                size: DsSizes.iconMd,
                color: colors.brand,
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  '事发地气象与火场风向',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typography.title.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (live?.city.isNotEmpty == true) ...[
                const SizedBox(width: DsSpacing.sm),
                Flexible(
                  child: Text(
                    live!.city,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ds.typography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          if (live != null) ...[
            Wrap(
              spacing: DsSpacing.md,
              runSpacing: DsSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (live.text.isNotEmpty)
                  Text(
                    live.text,
                    style: ds.typography.headline.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (live.temperature.isNotEmpty)
                  Text(
                    '${live.temperature}℃',
                    style: ds.typography.metric.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                if (live.humidity.isNotEmpty)
                  Text(
                    '湿度 ${live.humidity}%',
                    style: ds.typography.bodyTabular.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: DsSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: cautionPair.pillBg,
                borderRadius: DsRadius.borderSm,
                border: Border.all(
                  color: cautionPair.fill.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.air_rounded,
                    size: DsSizes.iconMd,
                    color: cautionPair.text,
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  Expanded(
                    child: Text(
                      live.windLabel.isNotEmpty
                          ? '风向：${live.windLabel}'
                          : '风向风力以现场实测为准',
                      style: ds.typography.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cautionPair.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: DsSpacing.sm),
            Text(
              '出警提示：请结合事发地风向选择上风或侧上风方向停车与集结。',
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
          ] else if (info.weatherLine != null)
            Text(
              info.weatherLine!,
              style: ds.typography.body.copyWith(color: colors.textPrimary),
            ),
          if (forecast != null &&
              (forecast.dayWeather.isNotEmpty ||
                  forecast.nightWeather.isNotEmpty)) ...[
            Divider(height: 20, color: colors.border),
            Text(
              '今日预报：白天 ${forecast.dayWeather} ${forecast.dayTemp}℃ · 夜间 ${forecast.nightWeather} ${forecast.nightTemp}℃',
              style: ds.typography.captionTabular.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 起终点卡片（支持修改警情地点、同名候选切换与歧义提示条）。
class RouteEndpointsCard extends StatelessWidget {
  final RouteTrafficInfo info;
  final String fallbackLocation;
  final RouteDestinationCandidate? selectedCandidate;
  final VoidCallback? onEditDetails;
  final VoidCallback onOpenCandidates;

  const RouteEndpointsCard({
    super.key,
    required this.info,
    required this.fallbackLocation,
    required this.selectedCandidate,
    this.onEditDetails,
    required this.onOpenCandidates,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final originAddr = info.origin?.address.trim();
    final destAddr = info.destination?.displayAddress ?? fallbackLocation;
    final cautionPair = colors.statusColors(DsStatus.caution);

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.lg,
        vertical: DsSpacing.md,
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.my_location_rounded,
                  size: DsSizes.iconSm,
                  color: colors.brand,
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  originAddr != null && originAddr.isNotEmpty
                      ? originAddr
                      : '当前位置（未获取具体地址）',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
            child: Row(
              children: [
                const SizedBox(width: 7),
                SizedBox(
                  height: 14,
                  child: VerticalDivider(width: 2, color: colors.border),
                ),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.location_on_rounded,
                  size: DsSizes.iconSm,
                  color: colors.alarmFill,
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  destAddr,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typography.body.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (onEditDetails != null)
                InkWell(
                  borderRadius: DsRadius.borderSm,
                  onTap: onEditDetails,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.xs,
                      vertical: 2,
                    ),
                    child: Text(
                      '修改',
                      style: ds.typography.caption.copyWith(
                        color: colors.brandText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (info.candidates.length > 1)
                InkWell(
                  key: const Key('route-traffic-switch-candidate'),
                  borderRadius: DsRadius.borderSm,
                  onTap: onOpenCandidates,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: DsSpacing.sm,
                      top: 2,
                      bottom: 2,
                    ),
                    child: Text(
                      '切换',
                      style: ds.typography.caption.copyWith(
                        color: colors.brandText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (info.ambiguous && info.candidates.length > 1) ...[
            const SizedBox(height: DsSpacing.sm),
            InkWell(
              key: const Key('route-traffic-ambiguous-banner'),
              onTap: onOpenCandidates,
              borderRadius: DsRadius.borderSm,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.sm,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: cautionPair.pillBg,
                  borderRadius: DsRadius.borderSm,
                  border: Border.all(
                    color: cautionPair.fill.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: DsSizes.iconSm,
                      color: cautionPair.text,
                    ),
                    const SizedBox(width: DsSpacing.xs),
                    Expanded(
                      child: Text(
                        '检测到多处同名地点，当前为${selectedCandidate?.name ?? "推荐地点"}，点此切换',
                        style: ds.typography.micro.copyWith(
                          color: cautionPair.text,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: DsSizes.iconSm,
                      color: cautionPair.text,
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
