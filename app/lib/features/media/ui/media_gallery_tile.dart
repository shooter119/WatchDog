import 'dart:io';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/local_media_store.dart';

/// 现场资料库单条媒体卡片操作类型。
enum MediaGalleryTileAction {
  review,
  rederive,
  open,
  save,
  share,
  attach,
  delete,
}

/// 现场资料库单条媒体卡片（Design System v3.0 `SurfaceCard` + `StatusPill`）。
class MediaGalleryTile extends StatelessWidget {
  const MediaGalleryTile({
    super.key,
    required this.media,
    required this.onTap,
    required this.onAction,
  });

  final LocalMedia media;
  final VoidCallback onTap;
  final ValueChanged<MediaGalleryTileAction> onAction;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.md,
        DsSpacing.sm,
        DsSpacing.xs,
        DsSpacing.sm,
      ),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Row(
          children: [
            _MediaThumb(media: media),
            const SizedBox(width: DsSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: DsSpacing.sm,
                    runSpacing: DsSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        media.isVideo
                            ? '录像 ${(media.durationMs / 1000).round()}s'
                            : '照片',
                        style: DsTypography.tabular(
                          typo.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      if (media.observationId.isNotEmpty)
                        const StatusPill(
                          status: DsStatus.safe,
                          label: '已写入警情',
                          icon: Icons.check_circle_outline,
                        )
                      else if (media.incidentId.isEmpty)
                        const StatusPill(
                          status: DsStatus.caution,
                          label: '未关联',
                          icon: Icons.link_off,
                        ),
                    ],
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    media.hasTranscript
                        ? media.transcript
                        : (media.address.isNotEmpty
                              ? media.address
                              : '未识别到口述内容'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.caption.copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
            PopupMenuButton<MediaGalleryTileAction>(
              tooltip: '更多操作',
              constraints: const BoxConstraints(
                minWidth: DsSizes.touchTarget,
                minHeight: DsSizes.touchTarget,
              ),
              icon: Icon(
                Icons.more_vert_rounded,
                color: colors.textSecondary,
                size: DsSizes.iconLg,
              ),
              onSelected: onAction,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: MediaGalleryTileAction.review,
                  child: Text('查看与核对'),
                ),
                if (media.isVideo && !media.hasTranscript)
                  const PopupMenuItem(
                    value: MediaGalleryTileAction.rederive,
                    child: Text('重新识别口述'),
                  ),
                const PopupMenuItem(
                  value: MediaGalleryTileAction.open,
                  child: Text('用其他应用打开'),
                ),
                const PopupMenuItem(
                  value: MediaGalleryTileAction.save,
                  child: Text('保存两份到手机相册'),
                ),
                const PopupMenuItem(
                  value: MediaGalleryTileAction.share,
                  child: Text('分享'),
                ),
                if (media.incidentId.isEmpty)
                  const PopupMenuItem(
                    value: MediaGalleryTileAction.attach,
                    child: Text('关联到当前警情'),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: MediaGalleryTileAction.delete,
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: colors.alarmText,
                      ),
                      const SizedBox(width: DsSpacing.sm),
                      Text(
                        '删除',
                        style: typo.body.copyWith(color: colors.alarmText),
                      ),
                    ],
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

class _MediaThumb extends StatelessWidget {
  const _MediaThumb({required this.media});

  final LocalMedia media;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final previewPath = media.isVideo
        ? (media.frames.isNotEmpty ? media.frames.first : null)
        : media.path;
    if (previewPath == null || !File(previewPath).existsSync()) {
      return Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: DsRadius.borderSm,
          border: Border.all(color: colors.border),
        ),
        child: Icon(
          media.isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
          color: colors.textTertiary,
        ),
      );
    }
    return ClipRRect(
      borderRadius: DsRadius.borderSm,
      child: Image.file(
        File(previewPath),
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: 64,
          height: 64,
          color: colors.surfaceMuted,
          child: Icon(
            Icons.image_not_supported_outlined,
            color: colors.textTertiary,
          ),
        ),
      ),
    );
  }
}
