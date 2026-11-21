import 'dart:io';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/local_media_store.dart';

/// 核对页 16:9 完整预览卡（BoxFit.contain 防止裁切底部水印）。
class MediaPreviewCard extends StatelessWidget {
  const MediaPreviewCard({
    super.key,
    required this.media,
    required this.firstFramePath,
    required this.onOpenVideo,
    required this.onOpenPhotoViewer,
  });

  final LocalMedia media;
  final String? firstFramePath;
  final VoidCallback onOpenVideo;
  final ValueChanged<String> onOpenPhotoViewer;

  @override
  Widget build(BuildContext context) {
    final isVideo = media.isVideo;
    final imagePath = isVideo ? firstFramePath : media.path;
    final hasImage =
        imagePath != null &&
        imagePath.isNotEmpty &&
        File(imagePath).existsSync();
    final onTap = isVideo
        ? onOpenVideo
        : (hasImage ? () => onOpenPhotoViewer(media.path) : null);

    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: DsRadius.borderLg,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxHeight = (MediaQuery.sizeOf(context).height * 0.36)
                  .clamp(140.0, 220.0)
                  .toDouble();
              final width = constraints.maxWidth < maxHeight * 16 / 9
                  ? constraints.maxWidth
                  : maxHeight * 16 / 9;
              return SizedBox(
                width: width,
                height: width * 9 / 16,
                child: Stack(
                  children: [
                    if (hasImage)
                      Container(
                        color: Colors.black,
                        width: double.infinity,
                        height: double.infinity,
                        child: Image.file(
                          File(imagePath),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) =>
                              _PreviewPlaceholder(isVideo: isVideo),
                        ),
                      )
                    else
                      _PreviewPlaceholder(isVideo: isVideo),
                    if (isVideo)
                      Center(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                      ),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: _PreviewChip(
                        text: isVideo ? '播放视频' : '查看原图',
                        icon: isVideo
                            ? Icons.play_circle_outline
                            : Icons.zoom_out_map_rounded,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 视频关键抽帧横向预览卡。
class MediaFramesCard extends StatelessWidget {
  const MediaFramesCard({
    super.key,
    required this.frames,
    required this.onOpenFrame,
  });

  final List<String> frames;
  final ValueChanged<String> onOpenFrame;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '关键画面',
            style: ds.typography.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.sm),
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: frames.length,
              separatorBuilder: (_, _) => const SizedBox(width: DsSpacing.sm),
              itemBuilder: (context, index) {
                final path = frames[index];
                return GestureDetector(
                  onTap: () => onOpenFrame(path),
                  child: ClipRRect(
                    borderRadius: DsRadius.borderSm,
                    child: Image.file(
                      File(path),
                      width: 128,
                      height: 84,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 128,
                        height: 84,
                        color: colors.surfaceMuted,
                        child: Icon(
                          Icons.image_not_supported_outlined,
                          color: colors.textTertiary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 全屏查看照片原图，支持双指缩放。
class MediaPhotoViewerPage extends StatelessWidget {
  const MediaPhotoViewerPage({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('查看原图'),
      ),
      body: SafeArea(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.image_not_supported_outlined,
                color: Colors.white70,
                size: 42,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder({required this.isVideo});

  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return Container(
      color: colors.surfaceMuted,
      alignment: Alignment.center,
      child: Icon(
        isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
        size: 42,
        color: colors.textSecondary,
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm,
        vertical: DsSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: DsRadius.borderPill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: DsSpacing.xs),
          Text(
            text,
            style: context.ds.typography.caption.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}
