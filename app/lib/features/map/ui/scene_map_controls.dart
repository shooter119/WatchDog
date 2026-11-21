import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/china_coord.dart';
import '../state/scene_map_store.dart';

/// 现场地图顶部悬浮控制条（图层切换、实时路况开关、定位告警与底图错误条）。
class SceneMapTopOverlay extends StatelessWidget {
  final SceneMapStore store;
  final VoidCallback onRetryBootstrap;

  const SceneMapTopOverlay({
    super.key,
    required this.store,
    required this.onRetryBootstrap,
  });

  @override
  Widget build(BuildContext context) {
    final mapReadyForLayers = store.canRenderMapSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mapReadyForLayers)
          Align(
            alignment: Alignment.centerRight,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SurfaceCard(
                level: DsSurfaceLevel.raised,
                borderRadius: DsRadius.borderPill,
                padding: const EdgeInsets.all(3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final mode in SceneMapLayerMode.values)
                      _LayerChip(
                        key: Key('scene-map-layer-${mode.jsValue}'),
                        label: mode.shortLabel,
                        tooltip: mode.label,
                        selected: store.layerMode == mode,
                        onTap: () => store.setLayerMode(mode),
                      ),
                    _LayerChip(
                      key: const Key('scene-map-layer-traffic'),
                      label: '路况',
                      tooltip: '实时路况图层',
                      selected: store.trafficEnabled,
                      onTap: store.toggleTraffic,
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (store.locStatus != SceneMapLocStatus.ok &&
            store.locStatus != SceneMapLocStatus.unknown) ...[
          if (mapReadyForLayers) const SizedBox(height: DsSpacing.sm),
          _LocationNoticeBanner(store: store),
        ],
        if (store.scriptError != null) ...[
          const SizedBox(height: DsSpacing.sm),
          _NoticeStrip(
            status: DsStatus.alarm,
            icon: Icons.cloud_off_rounded,
            text: store.scriptError!,
            actionLabel: '重试',
            onAction: onRetryBootstrap,
          ),
        ],
      ],
    );
  }
}

class _LayerChip extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  const _LayerChip({
    super.key,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? colors.brand : Colors.transparent,
        borderRadius: DsRadius.borderPill,
        child: InkWell(
          borderRadius: DsRadius.borderPill,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              label,
              style: ds.typography.caption.copyWith(
                color: selected ? colors.onBrand : colors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationNoticeBanner extends StatelessWidget {
  final SceneMapStore store;

  const _LocationNoticeBanner({required this.store});

  @override
  Widget build(BuildContext context) {
    final String text;
    final String actionLabel;
    final VoidCallback onAction;
    switch (store.locStatus) {
      case SceneMapLocStatus.permissionDenied:
        text = '未授予定位权限，无法实时标记当前位置';
        actionLabel = '去授权';
        onAction = () => unawaited(store.gateway.openAppSettings());
      case SceneMapLocStatus.serviceDisabled:
        text = '系统定位服务未开启，请开启后重试';
        actionLabel = '去开启';
        onAction = () => unawaited(store.gateway.openLocationSettings());
      case SceneMapLocStatus.fixFailed:
        text = '暂未获取到实时定位，可点击右侧定位图标重试';
        actionLabel = '重试';
        onAction = () => unawaited(store.retryLocation());
      case SceneMapLocStatus.unknown:
      case SceneMapLocStatus.ok:
        return const SizedBox.shrink();
    }

    return _NoticeStrip(
      key: const Key('scene-map-location-notice'),
      status: DsStatus.caution,
      icon: Icons.warning_amber_rounded,
      text: text,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }
}

class _NoticeStrip extends StatelessWidget {
  final DsStatus status;
  final IconData icon;
  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  const _NoticeStrip({
    super.key,
    required this.status,
    required this.icon,
    required this.text,
    required this.actionLabel,
    required this.onAction,
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
          const SizedBox(width: DsSpacing.xs),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
              foregroundColor: ds.colors.brandText,
            ),
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

/// 现场地图右侧快捷视角控制按钮组（我的位置 / 事发地点 / 全览两点）。
class SceneMapQuickFocusButtons extends StatelessWidget {
  final SceneMapStore store;

  const SceneMapQuickFocusButtons({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MapActionButton(
          key: const Key('scene-map-focus-me'),
          icon: store.followMe
              ? Icons.my_location_rounded
              : Icons.location_searching,
          tooltip: '我的位置',
          active: store.followMe && store.myGcj != null,
          onTap: store.focusMyLocation,
        ),
        if (store.incidentGcj != null) ...[
          const SizedBox(height: DsSpacing.sm),
          _MapActionButton(
            key: const Key('scene-map-focus-incident'),
            icon: Icons.location_on_rounded,
            tooltip: '事发地点',
            iconColor: ds.colors.alarmFill,
            onTap: store.focusIncident,
          ),
          const SizedBox(height: DsSpacing.sm),
          _MapActionButton(
            key: const Key('scene-map-fit-both'),
            icon: Icons.fit_screen_rounded,
            tooltip: '全览两点',
            onTap: store.fitBoth,
          ),
        ],
      ],
    );
  }
}

class _MapActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final Color? iconColor;

  const _MapActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Tooltip(
      message: tooltip,
      child: SurfaceCard(
        level: DsSurfaceLevel.raised,
        borderRadius: DsRadius.borderMd,
        padding: EdgeInsets.zero,
        onTap: onTap,
        child: SizedBox(
          width: DsSizes.touchTarget,
          height: DsSizes.touchTarget,
          child: Icon(
            icon,
            size: 22,
            color:
                iconColor ??
                (active ? ds.colors.brandText : ds.colors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// 现场地图底部遥测信息卡片（当前位置/精度/WGS84、事发地距离方位与一键导航）。
class SceneMapTelemetryCard extends StatelessWidget {
  final SceneMapStore store;
  final VoidCallback onNavigate;

  const SceneMapTelemetryCard({
    super.key,
    required this.store,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final fix = store.myWgsFix;
    final accuracyText = (fix != null && fix.accuracyMeters > 0)
        ? '±${fix.accuracyMeters.toStringAsFixed(0)} m'
        : null;
    final distanceMeters = store.distanceToIncidentMeters;
    final bearingDegrees = store.bearingToIncidentDegrees;
    final incidentSubtitle = distanceMeters == null
        ? null
        : (bearingDegrees == null
              ? '直线距离 ${ChinaCoord.formatDistance(distanceMeters)}'
              : '${ChinaCoord.cardinalDirection(bearingDegrees)} · 直线距离 ${ChinaCoord.formatDistance(distanceMeters)}');

    return SurfaceCard(
      key: const Key('scene-map-telemetry-card'),
      level: DsSurfaceLevel.raised,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: store.locStatus == SceneMapLocStatus.ok
                      ? colors.safeFill
                      : colors.cautionFill,
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  store.myAddress?.isNotEmpty == true
                      ? store.myAddress!
                      : (store.locStatus == SceneMapLocStatus.ok
                            ? '实时定位已开启'
                            : '正在获取当前位置…'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typography.body.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (accuracyText != null) ...[
                const SizedBox(width: DsSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: DsRadius.borderPill,
                  ),
                  child: Text(
                    accuracyText,
                    style: ds.typography.captionTabular.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (fix != null) ...[
            const SizedBox(height: DsSpacing.xs),
            Text(
              'WGS84 ${fix.lat.toStringAsFixed(6)}, ${fix.lon.toStringAsFixed(6)}',
              style: ds.typography.captionTabular.copyWith(
                color: colors.textTertiary,
              ),
            ),
          ],
          if (store.incidentGcj != null ||
              (store.incidentDisplayLocation?.isNotEmpty ?? false)) ...[
            const SizedBox(height: DsSpacing.sm),
            Divider(height: 1, color: colors.border),
            const SizedBox(height: DsSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: const Key('scene-map-telemetry-incident'),
                    borderRadius: DsRadius.borderMd,
                    onTap: store.incidentGcj != null
                        ? store.focusIncident
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.local_fire_department_rounded,
                            size: 18,
                            color: colors.alarmFill,
                          ),
                          const SizedBox(width: DsSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  store.incidentDisplayLocation ??
                                      store.incidentName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ds.typography.caption.copyWith(
                                    color: colors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (incidentSubtitle != null)
                                  Text(
                                    incidentSubtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: ds.typography.captionTabular
                                        .copyWith(
                                          color: colors.alarmText,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (store.incidentGcj != null) ...[
                  const SizedBox(width: DsSpacing.sm),
                  CommandButton(
                    key: const Key('scene-map-navigate'),
                    label: '导航',
                    icon: Icons.navigation_rounded,
                    size: CommandButtonSize.standard,
                    onPressed: onNavigate,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
