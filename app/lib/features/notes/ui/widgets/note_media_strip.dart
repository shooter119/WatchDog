import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/note_media.dart';

/// 火场日志条目底部的照片/视频附件微缩条。
///
/// 支持已同步、等待上传、上传中、失败重试/丢弃以及已归档清理 5 种状态，
/// 并在 360dp @ 130% 大字号下自适应宽度保持零溢出。
class NoteMediaStrip extends StatelessWidget {
  const NoteMediaStrip({
    super.key,
    required this.attachments,
    this.resolveMediaUrl,
    this.mediaHeaders = const <String, String>{},
    this.compact = false,
    this.onOpenMedia,
    this.onRetryUpload,
    this.onDiscardUpload,
  });

  final List<NoteMediaAttachment> attachments;
  final String Function(String relativePath)? resolveMediaUrl;
  final Map<String, String> mediaHeaders;
  final bool compact;
  final ValueChanged<NoteMediaAttachment>? onOpenMedia;
  final ValueChanged<String>? onRetryUpload;
  final ValueChanged<String>? onDiscardUpload;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < attachments.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: DsSpacing.sm),
          _NoteMediaTile(
            item: attachments[i],
            resolveMediaUrl: resolveMediaUrl,
            mediaHeaders: mediaHeaders,
            compact: compact,
            onOpen: onOpenMedia != null
                ? () => onOpenMedia!(attachments[i])
                : null,
            onRetry:
                attachments[i].queueTaskId.isNotEmpty && onRetryUpload != null
                ? () => onRetryUpload!(attachments[i].queueTaskId)
                : null,
            onDiscard:
                attachments[i].queueTaskId.isNotEmpty &&
                    onDiscardUpload != null
                ? () => onDiscardUpload!(attachments[i].queueTaskId)
                : null,
          ),
        ],
      ],
    );
  }
}

class _NoteMediaTile extends StatelessWidget {
  const _NoteMediaTile({
    required this.item,
    required this.resolveMediaUrl,
    required this.mediaHeaders,
    required this.compact,
    this.onOpen,
    this.onRetry,
    this.onDiscard,
  });

  final NoteMediaAttachment item;
  final String Function(String relativePath)? resolveMediaUrl;
  final Map<String, String> mediaHeaders;
  final bool compact;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    if (!item.available && !item.isPendingUpload) {
      return Container(
        key: Key('note-media-purged-${item.id}'),
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.sm,
          vertical: DsSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: DsRadius.borderMd,
          border: Border.all(color: colors.border, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              item.isVideo ? DsIcons.videoOff : DsIcons.photoLibrary,
              size: DsSizes.iconSm,
              color: colors.textTertiary,
            ),
            const SizedBox(width: DsSpacing.xs),
            Flexible(
              child: Text(
                '${item.isVideo ? '视频' : '照片'}附件已归档清理',
                style: typo.caption.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }

    final double targetMax = compact ? 168.0 : 216.0;
    const double aspectRatio = 16 / 9;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 外层 TimelineList 使用 IntrinsicHeight 时，RenderConstrainedBox 不会用 maxWidth
        // 裁剪传入 AspectRatio 的 width；必须同步声明 maxHeight，避免卡片底部拉出多余空白。
        ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 96.0,
            maxWidth: targetMax,
            maxHeight: targetMax / aspectRatio,
          ),
          child: Semantics(
            button: onOpen != null,
            label: item.isVideo ? '查看水印视频' : '查看水印照片',
            child: Material(
              color: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: DsRadius.borderMd,
                side: BorderSide(color: colors.border, width: 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: Key('note-media-card-${item.id}'),
                onTap: onOpen,
                child: AspectRatio(
                  aspectRatio: aspectRatio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      _buildThumbnail(colors),
                      if (item.isVideo)
                        Center(
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              DsIcons.play,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      if (item.isVideo && item.durationMs > 0)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: _OverlayBadge(
                            text: item.formattedDuration,
                            style: DsTypography.tabular(typo.micro).copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (item.isPendingUpload)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: _buildStatusChip(colors, typo),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (item.uploadStatus == NoteMediaUploadStatus.failed) ...<Widget>[
          const SizedBox(height: DsSpacing.xs),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              if (onRetry != null)
                CommandButton(
                  key: Key('note-media-retry-${item.queueTaskId}'),
                  label: '重试上传',
                  icon: DsIcons.refresh,
                  variant: CommandButtonVariant.secondary,
                  onPressed: onRetry,
                ),
              if (onDiscard != null)
                CommandButton(
                  key: Key('note-media-discard-${item.queueTaskId}'),
                  label: '取消上传',
                  variant: CommandButtonVariant.ghost,
                  onPressed: onDiscard,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildStatusChip(DsColors colors, DsTypography typo) {
    final (String text, Color bg, Color fg) = switch (item.uploadStatus) {
      NoteMediaUploadStatus.queued => ('等待上传', Colors.black87, Colors.white),
      NoteMediaUploadStatus.uploading => ('上传中…', colors.brand, colors.onBrand),
      NoteMediaUploadStatus.failed => (
        '上传失败',
        colors.statusColors(DsStatus.alarm).fill,
        colors.statusColors(DsStatus.alarm).onFill,
      ),
      NoteMediaUploadStatus.synced => ('已同步', Colors.black54, Colors.white),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: DsRadius.borderPill,
      ),
      child: Text(
        text,
        style: typo.micro.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildThumbnail(DsColors colors) {
    final String localThumb = item.isVideo
        ? item.localThumbPath
        : item.localPath;
    if (localThumb.isNotEmpty && File(localThumb).existsSync()) {
      return Image.file(
        File(localThumb),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _Placeholder(item: item),
      );
    }
    final rawRel = item.thumbUrl.isNotEmpty
        ? item.thumbUrl
        : (item.isPhoto ? item.fileUrl : '');
    final resolved = rawRel.isNotEmpty
        ? (resolveMediaUrl?.call(rawRel) ?? rawRel)
        : '';
    if (resolved.startsWith('http://') || resolved.startsWith('https://')) {
      return Image.network(
        resolved,
        headers: mediaHeaders.isEmpty ? null : mediaHeaders,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _Placeholder(item: item),
      );
    }
    return _Placeholder(item: item);
  }
}

class _OverlayBadge extends StatelessWidget {
  const _OverlayBadge({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: DsRadius.borderSm,
      ),
      child: Text(text, style: style),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.item});

  final NoteMediaAttachment item;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF18202C),
      child: Center(
        child: Icon(
          item.isVideo ? DsIcons.video : DsIcons.photoLibrary,
          size: 28,
          color: Colors.white54,
        ),
      ),
    );
  }
}
