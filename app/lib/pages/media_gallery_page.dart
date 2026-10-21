import 'dart:io';

import 'package:flutter/material.dart';

import '../services/camera_bridge.dart';
import '../services/local_media_store.dart';
import '../services/media_capture_service.dart';
import '../services/media_share_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'media_review_page.dart';

/// 本机现场媒体：照片与录像都留在这台设备上，可逐条分享或删除。
class MediaGalleryPage extends StatefulWidget {
  final AppController controller;

  const MediaGalleryPage({super.key, required this.controller});

  @override
  State<MediaGalleryPage> createState() => _MediaGalleryPageState();
}

class _MediaGalleryPageState extends State<MediaGalleryPage> {
  List<LocalMedia> _items = const [];
  List<LocalMedia> _unlinked = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final incidentId = widget.controller.currentIncident?.id ?? '';
    final items = incidentId.isEmpty
        ? const <LocalMedia>[]
        : await LocalMediaStore.instance.listForIncident(incidentId);
    // 未关联警情的文件单独一栏，避免它们永远消失
    final unlinked = await LocalMediaStore.instance.listUnlinked();
    if (!mounted) return;
    setState(() {
      _items = items;
      _unlinked = unlinked;
      _loading = false;
    });
  }

  Future<void> _attach(LocalMedia media) async {
    final incidentId = widget.controller.currentIncident?.id ?? '';
    if (incidentId.isEmpty) {
      _toast('请先加入或新建警情');
      return;
    }
    await LocalMediaStore.instance.attachToIncident(media.id, incidentId);
    await _load();
    _toast('已关联到当前警情');
  }

  Future<void> _purge() async {
    final count = await MediaCaptureService.countExpired();
    if (!mounted) return;
    if (count == 0) {
      _toast('没有超过保留期的文件');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理过期文件？'),
        content: Text(
          '将删除 $count 个超过 ${LocalMediaStore.retentionDays} 天的媒体文件，'
          '删除后无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await MediaCaptureService.purgeExpired();
    await _load();
    if (!mounted) return;
    _toast(removed == 0 ? '没有超过保留期的文件' : '已清理 $removed 个过期文件');
  }

  Future<void> _share(LocalMedia media) async {
    try {
      await MediaShareService.shareWatermarked(media.path);
    } catch (_) {
      _toast('系统分享不可用');
    }
  }

  Future<void> _saveToGallery(LocalMedia media) async {
    _toast('正在保存到手机相册…');
    final paired = media.sourcePath.isNotEmpty;
    final saved = paired
        ? await CameraBridge.savePairToGallery(
                watermarkedPath: media.path,
                sourcePath: media.sourcePath,
              ) !=
              null
        : await CameraBridge.saveToGallery(media.path) != null;
    if (saved) {
      await MediaCaptureService.removeLocalCopy(media);
    }
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    _toast(
      saved ? (paired ? '已保存带水印版和无水印版到手机相册' : '旧资料仅保存了带水印版') : '两份相册文件保存失败，已回滚',
    );
  }

  Future<void> _openMedia(LocalMedia media) async {
    final opened = await CameraBridge.openWithSystem(media.path);
    if (!mounted) return;
    if (!opened) _toast('没有可打开该文件的应用');
  }

  Future<void> _delete(LocalMedia media) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条现场资料？'),
        content: const Text('文件与已识别文字都会从本机删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MediaCaptureService.removeLocalCopy(media);
    await _load();
  }

  Future<void> _review(LocalMedia media) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            MediaReviewPage(controller: widget.controller, media: media),
      ),
    );
    await _load();
  }

  /// 识别失败或中途离开后，可以从资料页重新触发，不必重新拍摄。
  Future<void> _rederive(LocalMedia media) async {
    _toast('正在重新识别口述…');
    String? error;
    final updated = await MediaCaptureService.derive(
      media,
      controller: widget.controller,
      onError: (message) => error = message,
    );
    await _load();
    if (!mounted) return;
    _toast(
      error ??
          (updated.hasTranscript ? '识别完成，可在「查看与核对」里确认' : '没有识别到口述内容，可在核对页手动补写'),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    // 新的保存结果要立刻可见，不能排在「正在保存…」后面等它自然消失。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('现场资料'),
        actions: [
          IconButton(
            tooltip: '清理过期文件',
            onPressed: _purge,
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: (_items.isEmpty && _unlinked.isEmpty) ? _empty() : _list(),
            ),
    );
  }

  Widget _empty() {
    final hasIncident =
        (widget.controller.currentIncident?.id ?? '').isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const SizedBox(height: AppSpacing.s10),
        Center(
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(
              Icons.photo_library_outlined,
              size: 40,
              color: AppColors.textTertiary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        Text(
          hasIncident ? '还没有拍摄现场照片或录像' : '还没有当前警情',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyMd.copyWith(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          hasIncident ? '在首页点「水印相机」，文件会保存在这台设备上' : '先加入或新建警情，拍摄的现场资料会归到当前警情下',
          textAlign: TextAlign.center,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textTertiary,
          ),
        ),
      ],
    );
  }

  Widget _list() {
    final all = [..._items, ..._unlinked];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: all.length + (_unlinked.isNotEmpty ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s2),
      itemBuilder: (context, index) {
        if (_unlinked.isNotEmpty) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s1),
              child: Text(
                '未关联警情（加入警情后可关联并写入记录）',
                style: AppTextStyles.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
            );
          }
        }
        final media = all[index - (_unlinked.isNotEmpty ? 1 : 0)];
        return AppCard(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s3,
            AppSpacing.s2,
            AppSpacing.s1,
            AppSpacing.s2,
          ),
          onTap: () => _review(media),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                _thumb(media),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: AppSpacing.s2,
                        runSpacing: AppSpacing.s1,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            media.isVideo
                                ? '录像 ${(media.durationMs / 1000).round()}s'
                                : '照片',
                            style: AppTextStyles.bodyMd.copyWith(
                              fontSize: 14,
                              height: 1.3,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          if (media.observationId.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 14,
                                  color: AppColors.online,
                                ),
                                const SizedBox(width: AppSpacing.s1),
                                Text(
                                  '已写入警情',
                                  style: AppTextStyles.caption.copyWith(
                                    height: 1.2,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.s1),
                      Text(
                        media.hasTranscript
                            ? media.transcript
                            : (media.address.isNotEmpty
                                  ? media.address
                                  : '未识别到口述内容'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption.copyWith(
                          height: 1.3,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: AppColors.textSecondary,
                  ),
                  onSelected: (value) {
                    switch (value) {
                      case 'review':
                        _review(media);
                      case 'open':
                        _openMedia(media);
                      case 'share':
                        _share(media);
                      case 'save':
                        _saveToGallery(media);
                      case 'rederive':
                        _rederive(media);
                      case 'attach':
                        _attach(media);
                      case 'delete':
                        _delete(media);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'review', child: Text('查看与核对')),
                    if (media.isVideo && !media.hasTranscript)
                      const PopupMenuItem(
                        value: 'rederive',
                        child: Text('重新识别口述'),
                      ),
                    const PopupMenuItem(value: 'open', child: Text('用其他应用打开')),
                    const PopupMenuItem(
                      value: 'save',
                      child: Text('保存两份到手机相册'),
                    ),
                    const PopupMenuItem(value: 'share', child: Text('分享')),
                    if (media.incidentId.isEmpty)
                      const PopupMenuItem(
                        value: 'attach',
                        child: Text('关联到当前警情'),
                      ),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _thumb(LocalMedia media) {
    final previewPath = media.isVideo
        ? (media.frames.isNotEmpty ? media.frames.first : null)
        : media.path;
    if (previewPath == null || !File(previewPath).existsSync()) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Icon(
          media.isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
          color: AppColors.textTertiary,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Image.file(
        File(previewPath),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: 48,
          height: 48,
          color: AppColors.surfaceSubtle,
          child: Icon(
            Icons.image_not_supported_outlined,
            color: AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}
