import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/camera_bridge.dart';
import '../services/local_media_store.dart';
import '../services/media_capture_service.dart';
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
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _purge() async {
    final removed = await MediaCaptureService.purgeExpired();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(removed == 0 ? '没有超过保留期的文件' : '已清理 $removed 个过期文件')),
    );
  }

  Future<void> _share(LocalMedia media) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(media.path)],
          text: media.transcript.trim(),
        ),
      );
    } catch (_) {
      _toast('系统分享不可用');
    }
  }

  Future<void> _delete(LocalMedia media) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条现场资料？'),
        content: const Text('文件与已识别文字都会从本机删除，无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await LocalMediaStore.instance.deleteById(media.id);
    for (final path in [media.path, ...media.frames]) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }
    await _load();
  }

  Future<void> _review(LocalMedia media) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaReviewPage(controller: widget.controller, media: media),
      ),
    );
    await _load();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
              child: _items.isEmpty ? _empty() : _list(),
            ),
    );
  }

  Widget _empty() {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: const [
        SizedBox(height: 60),
        Icon(Icons.photo_library_outlined, size: 42, color: AppColors.textTertiary),
        SizedBox(height: 12),
        Text(
          '还没有现场照片或录像',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        SizedBox(height: 6),
        Text(
          '在首页警情卡点「水印相机」拍摄，文件会保存在这台设备上',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _list() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final media = _items[index];
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            leading: _thumb(media),
            title: Text(
              media.isVideo
                  ? '录像 ${(media.durationMs / 1000).round()}s'
                  : '照片',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Text(
              media.hasTranscript
                  ? media.transcript
                  : (media.address.isNotEmpty ? media.address : '未识别到口述内容'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (value) {
                switch (value) {
                  case 'review':
                    _review(media);
                  case 'open':
                    CameraBridge.openWithSystem(media.path);
                  case 'share':
                    _share(media);
                  case 'delete':
                    _delete(media);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'review', child: Text('查看与核对')),
                PopupMenuItem(value: 'open', child: Text('用其他应用打开')),
                PopupMenuItem(value: 'share', child: Text('分享')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
            onTap: () => _review(media),
          ),
        );
      },
    );
  }

  Widget _thumb(LocalMedia media) {
    final previewPath =
        media.isVideo ? (media.frames.isNotEmpty ? media.frames.first : null) : media.path;
    if (previewPath == null || !File(previewPath).existsSync()) {
      return Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          media.isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
          color: AppColors.textTertiary,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(previewPath),
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: 52,
          height: 52,
          color: AppColors.surfaceSubtle,
          child: const Icon(Icons.image_not_supported_outlined),
        ),
      ),
    );
  }
}
