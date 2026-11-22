import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/video_resource.dart';
import 'video_playback_surface.dart';

/// 视频监控资源列表卡片（Design System v3.0）。
///
/// 使用 1px 描边 [SurfaceCard] + 双通道 [StatusPill] 展示可达性状态
/// （绿：在线 / 红：离线·不可播放 / 中性：检测中），点击展开 16:9 行内播放器，
/// 并提供全屏、浮窗与关闭三个独立 48dp 触控操作。
class VideoResourceCard extends StatelessWidget {
  const VideoResourceCard({
    super.key,
    required this.resource,
    this.available,
    this.expandedPlayer,
    required this.onTap,
    required this.onClose,
    this.onFullscreen,
    this.onFloating,
  });

  final VideoResource resource;
  final bool? available;
  final Widget? expandedPlayer;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback? onFullscreen;
  final VoidCallback? onFloating;

  DsStatus get _reachabilityStatus {
    if (available == null) return DsStatus.neutral;
    return available! ? DsStatus.safe : DsStatus.alarm;
  }

  String get _statusLabel {
    if (available == null) return '检测中';
    return available! ? '在线' : '离线·不可播放';
  }

  String get _statusSemanticLabel {
    if (available == null) return '正在检测视频是否可用';
    return available! ? '视频可用' : '视频不可用';
  }

  IconData get _statusIcon {
    if (available == null) return DsIcons.hourglass;
    return available!
        ? DsIcons.checkCircle
        : DsIcons.videoOff;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final statusPair = colors.statusColors(_reachabilityStatus);
    final isExpanded = expandedPlayer != null;
    final description = resource.description.trim().isEmpty
        ? '已授权视频画面'
        : resource.description.trim();

    return SurfaceCard(
      onTap: isExpanded ? null : onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _LeadingCameraBadge(
                  statusColor: statusPair.fill,
                  showStatusDot: available != null,
                ),
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        resource.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: typo.title.copyWith(color: colors.textPrimary),
                      ),
                      const SizedBox(height: DsSpacing.xs),
                      Wrap(
                        spacing: DsSpacing.sm,
                        runSpacing: DsSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Tooltip(
                            message: _statusSemanticLabel,
                            child: Semantics(
                              label: _statusSemanticLabel,
                              child: StatusPill(
                                key: ValueKey<String>(
                                  'video-resource-status-${resource.id}',
                                ),
                                status: _reachabilityStatus,
                                label: _statusLabel,
                                icon: _statusIcon,
                              ),
                            ),
                          ),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: typo.caption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!isExpanded) ...<Widget>[
                  const SizedBox(width: DsSpacing.sm),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.border, width: 1),
                    ),
                    child: Icon(
                      DsIcons.play,
                      color: colors.brandText,
                      size: DsSizes.iconLg,
                    ),
                  ),
                ],
              ],
            ),
          ),
          AnimatedSize(
            duration: DsMotion.resolve(context, DsMotion.normal),
            curve: DsMotion.enter,
            alignment: Alignment.topCenter,
            child: !isExpanded
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: DsSpacing.md),
                    child: ClipRRect(
                      borderRadius: DsRadius.borderSm,
                      child: AspectRatio(
                        key: ValueKey<String>(
                          'video-resource-expanded-${resource.id}',
                        ),
                        aspectRatio: 16 / 9,
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            expandedPlayer!,
                            Positioned(
                              top: DsSpacing.sm,
                              right: DsSpacing.sm,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  PlayerOverlayButton(
                                    key: ValueKey<String>(
                                      'video-resource-fullscreen-${resource.id}',
                                    ),
                                    tooltip: '全屏播放',
                                    icon: DsIcons.fullscreen,
                                    onPressed: onFullscreen ?? () {},
                                  ),
                                  const SizedBox(width: DsSpacing.xs),
                                  PlayerOverlayButton(
                                    key: ValueKey<String>(
                                      'video-resource-floating-${resource.id}',
                                    ),
                                    tooltip: '浮窗播放',
                                    icon:
                                        DsIcons.pip,
                                    onPressed: onFloating ?? () {},
                                  ),
                                  const SizedBox(width: DsSpacing.xs),
                                  PlayerOverlayButton(
                                    key: ValueKey<String>(
                                      'video-resource-close-${resource.id}',
                                    ),
                                    tooltip: '关闭视频',
                                    icon: DsIcons.close,
                                    onPressed: onClose,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LeadingCameraBadge extends StatelessWidget {
  const _LeadingCameraBadge({
    required this.statusColor,
    required this.showStatusDot,
  });

  final Color statusColor;
  final bool showStatusDot;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: DsRadius.borderMd,
              border: Border.all(color: colors.border, width: 1),
            ),
            child: Icon(
              DsIcons.video,
              color: colors.brandText,
              size: DsSizes.iconLg,
            ),
          ),
          if (showStatusDot)
            Positioned(
              right: -2,
              top: -2,
              child: ExcludeSemantics(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.surface, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
