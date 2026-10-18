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
              child: (_items.isEmpty && _unlinked.isEmpty) ? _empty() : _list(),
            ),
    );
  }

  Widget _empty() {
    final hasIncident = (widget.controller.currentIncident?.id ?? '').isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        const Icon(
          Icons.photo_library_outlined,
          size: 42,
          color: AppColors.textSecondary,
        ),
        const SizedBox(height: 12),
        Text(
          hasIncident ? '还没有拍摄现场照片或录像' : '还没有当前警情',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Text(
          hasIncident
              ? '在首页警情卡点「水印相机」拍摄，文件会保存在这台设备上'
              : '先加入或新建警情，拍摄的现场资料会归到当前警情下',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _list() {
    final all = [..._items, ..._unlinked];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      itemCount: all.length + (_unlinked.isNotEmpty ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (_unlinked.isNotEmpty) {
          if (index == 0) {
            return const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 2),
              child: Text(
                '未关联警情（加入警情后可关联并写入记录）',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
            );
          }
        }
        final media = all[index - (_unlinked.isNotEmpty ? 1 : 0)];
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
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (media.observationId.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          size: 14,
                          color: AppColors.online,
                        ),
                        SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '已写入警情',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  media.hasTranscript
                      ? media.transcript
                      : (media.address.isNotEmpty
                            ? media.address
                            : '未识别到口述内容'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
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
                  const PopupMenuItem(value: 'rederive', child: Text('重新识别口述')),
                const PopupMenuItem(value: 'open', child: Text('用其他应用打开')),
                const PopupMenuItem(value: 'share', child: Text('分享')),
                if (media.incidentId.isEmpty)
                  const PopupMenuItem(value: 'attach', child: Text('关联到当前警情')),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
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
