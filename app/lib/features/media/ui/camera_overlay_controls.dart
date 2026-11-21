import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/watermark_settings.dart';
import '../state/camera_session_store.dart';
import 'camera_shutter_bar.dart';

export 'camera_shutter_bar.dart';

/// 相机顶部悬浮工具条：资料库入口、模式胶囊、权限状态徽章、可选水印设置与关闭键、警情标签与录像计时。
class CameraTopBar extends StatelessWidget {
  const CameraTopBar({
    super.key,
    required this.store,
    required this.onOpenGallery,
    required this.onClose,
    required this.onRequestPermissionsAgain,
    this.onOpenWatermarkSettings,
  });

  final CameraSessionStore store;
  final VoidCallback onOpenGallery;
  final VoidCallback onClose;
  final VoidCallback onRequestPermissionsAgain;
  final VoidCallback? onOpenWatermarkSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final unlinked = store.isUnlinked;
    final isPortrait =
        store.captureOrientation == CameraCaptureOrientation.portrait;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.sm,
              DsSpacing.sm,
              DsSpacing.md,
              0,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: '现场资料',
                  onPressed: store.isControlLocked ? null : onOpenGallery,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(
                      DsSizes.touchTarget,
                      DsSizes.touchTarget,
                    ),
                  ),
                  icon: const Icon(
                    Icons.photo_library_outlined,
                    color: Colors.white,
                    size: DsSizes.iconLg,
                  ),
                ),
                if (!store.recording) ...[
                  const SizedBox(width: DsSpacing.xs),
                  _ModeBadge(
                    isVideo: store.mode == CameraCaptureMode.video,
                    alarmColor: colors.alarmFill,
                  ),
                ],
                if (onOpenWatermarkSettings != null && !store.recording) ...[
                  const SizedBox(width: DsSpacing.xs),
                  IconButton(
                    tooltip: '水印设置',
                    onPressed: store.isControlLocked
                        ? null
                        : onOpenWatermarkSettings,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(
                        DsSizes.touchTarget,
                        DsSizes.touchTarget,
                      ),
                    ),
                    icon: const Icon(
                      Icons.tune_rounded,
                      color: Colors.white,
                      size: DsSizes.iconMd,
                    ),
                  ),
                ],
                if (store.hasPermissionBadges) ...[
                  const SizedBox(width: DsSpacing.xs),
                  Flexible(
                    child: _PermissionBadges(
                      store: store,
                      onRequestAgain: onRequestPermissionsAgain,
                    ),
                  ),
                ],
                const Spacer(),
                CameraRoundIconButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  onTap: onClose,
                ),
              ],
            ),
          ),
          if (!unlinked)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DsSpacing.md,
                DsSpacing.sm,
                DsSpacing.md,
                0,
              ),
              child: Align(
                alignment: isPortrait
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: _IncidentChip(
                  title: store.currentIncident?.title ?? '',
                  unlinked: unlinked,
                  cautionColor: colors.cautionFill,
                ),
              ),
            ),
          if (store.recording)
            Padding(
              padding: const EdgeInsets.only(top: DsSpacing.sm),
              child: _RecordingTimerPill(
                timerText: store.timerText,
                elapsedSeconds: store.elapsed.inSeconds,
                alarmColor: colors.alarmFill,
                cautionColor: colors.cautionFill,
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.isVideo, required this.alarmColor});

  final bool isVideo;
  final Color alarmColor;

  @override
  Widget build(BuildContext context) {
    final typo = context.ds.typography;
    return Container(
      key: const Key('camera-mode-badge'),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm,
        vertical: DsSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: isVideo ? alarmColor : Colors.black54,
        borderRadius: DsRadius.borderPill,
        border: Border.all(
          color: isVideo ? const Color(0xFFFF6B6B) : Colors.white24,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isVideo ? Icons.videocam_rounded : Icons.photo_camera_rounded,
            size: 14,
            color: Colors.white,
          ),
          const SizedBox(width: DsSpacing.xs),
          Text(
            isVideo ? '录像模式' : '拍照模式',
            style: typo.caption.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _IncidentChip extends StatelessWidget {
  const _IncidentChip({
    required this.title,
    required this.unlinked,
    required this.cautionColor,
  });

  final String title;
  final bool unlinked;
  final Color cautionColor;

  @override
  Widget build(BuildContext context) {
    final typo = context.ds.typography;
    final label = unlinked || title.isEmpty ? '未关联警情' : title;
    return Container(
      key: const Key('camera-incident-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: DsRadius.borderPill,
        border: Border.all(color: unlinked ? cautionColor : Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            size: 14,
            color: unlinked ? cautionColor : Colors.white70,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.caption.copyWith(
                color: unlinked ? const Color(0xFFFFE1A8) : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordingTimerPill extends StatelessWidget {
  const _RecordingTimerPill({
    required this.timerText,
    required this.elapsedSeconds,
    required this.alarmColor,
    required this.cautionColor,
  });

  final String timerText;
  final int elapsedSeconds;
  final Color alarmColor;
  final Color cautionColor;

  @override
  Widget build(BuildContext context) {
    final typo = context.ds.typography;
    final remaining = (60 - elapsedSeconds).clamp(0, 60);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: DsRadius.borderPill,
        border: Border.all(
          color: elapsedSeconds >= 50 ? cautionColor : Colors.white24,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 10, color: alarmColor),
          const SizedBox(width: 5),
          Text(
            'REC',
            style: typo.caption.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          Text(
            '$timerText · 剩 ${remaining}s',
            style: DsTypography.tabular(
              typo.body.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionBadges extends StatelessWidget {
  const _PermissionBadges({required this.store, required this.onRequestAgain});

  final CameraSessionStore store;
  final VoidCallback onRequestAgain;

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[];
    if (!store.permissions.microphone) {
      badges.add(_badge(context, '麦克风未授权', Icons.mic_off_rounded, onRequestAgain));
    }
    if (!store.permissions.location) {
      badges.add(
        _badge(context, '定位未授权', Icons.location_off_rounded, onRequestAgain),
      );
    } else if (store.locating) {
      badges.add(
        _badge(context, '定位更新中', Icons.location_searching_rounded, null),
      );
    } else if (!store.permissions.preciseLocation) {
      badges.add(
        _badge(context, '粗略定位', Icons.location_searching_rounded, null),
      );
    }
    if (badges.isEmpty) return const SizedBox.shrink();
    return Wrap(alignment: WrapAlignment.end, children: badges);
  }

  Widget _badge(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback? onTap,
  ) {
    final typo = context.ds.typography;
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: DsRadius.borderPill,
              border: Border.all(color: Colors.white38),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
