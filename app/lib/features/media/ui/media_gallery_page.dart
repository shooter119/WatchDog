import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/camera_bridge.dart';
import '../../../services/local_media_store.dart';
import '../../../services/media_capture_service.dart';
import '../../../services/media_share_service.dart';
import '../state/media_gateway.dart';
import 'media_gallery_tile.dart';
import 'media_review_page.dart';

/// 现场资料库筛选维度。
enum MediaGalleryFilter { all, incident, unlinked }

/// 本机现场资料页（Design System v3.0 重构版）。
///
/// 照片与录像始终保存在本机，支持按当前警情 / 未关联筛选、超期批量清理、
/// 重新识别口述、成对保存相册、分享及 `CommandSheet` 二次确认删除。
class MediaGalleryPage extends StatefulWidget {
  const MediaGalleryPage({
    super.key,
    required this.gateway,
    this.onOpenReview,
  });

  final MediaGateway gateway;
  final Future<MediaReviewOutcome?> Function(
    BuildContext context,
    LocalMedia media,
  )?
  onOpenReview;

  @override
  State<MediaGalleryPage> createState() => _MediaGalleryPageState();
}

class _MediaGalleryPageState extends State<MediaGalleryPage> {
  List<LocalMedia> _items = const [];
  List<LocalMedia> _unlinked = const [];
  MediaGalleryFilter _filter = MediaGalleryFilter.all;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _currentIncidentId =>
      widget.gateway.readCurrentIncident()?.id ?? '';

  Future<void> _load() async {
    final incidentId = _currentIncidentId;
    final items = incidentId.isEmpty
        ? const <LocalMedia>[]
        : await LocalMediaStore.instance.listForIncident(incidentId);
    final unlinked = await LocalMediaStore.instance.listUnlinked();
    if (!mounted) return;
    setState(() {
      _items = items;
      _unlinked = unlinked;
      _loading = false;
    });
  }

  Future<void> _attach(LocalMedia media) async {
    final incidentId = _currentIncidentId;
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
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: '清理过期文件？',
      builder: (sheetContext) {
        final ds = sheetContext.ds;
        return Text(
          '将删除 $count 个超过 ${LocalMediaStore.retentionDays} 天的媒体文件，'
          '删除后无法恢复。',
          style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
        );
      },
      actionsBuilder: (sheetContext) => [
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          label: '清理',
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
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
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: '删除这条现场资料？',
      builder: (sheetContext) {
        final ds = sheetContext.ds;
        return Text(
          '文件与已识别文字都会从本机删除，无法恢复。',
          style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
        );
      },
      actionsBuilder: (sheetContext) => [
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          label: '删除',
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    );
    if (confirmed != true) return;
    await MediaCaptureService.removeLocalCopy(media);
    await _load();
  }

  Future<void> _review(LocalMedia media) async {
    final custom = widget.onOpenReview;
    if (custom != null) {
      await custom(context, media);
    } else {
      await Navigator.of(context).push<MediaReviewOutcome>(
        MaterialPageRoute<MediaReviewOutcome>(
          builder: (_) =>
              MediaReviewPage(gateway: widget.gateway, media: media),
        ),
      );
    }
    if (mounted) await _load();
  }

  Future<void> _rederive(LocalMedia media) async {
    _toast('正在重新识别口述…');
    String? error;
    final updated = await runMediaDerive(
      media,
      gateway: widget.gateway,
      onError: (message) => error = message,
    );
    await _load();
    if (!mounted) return;
    _toast(
      error ??
          (updated.hasTranscript ? '识别完成，可在「查看与核对」里确认' : '没有识别到口述内容，可在核对页手动补写'),
    );
  }

  void _handleAction(LocalMedia media, MediaGalleryTileAction action) {
    switch (action) {
      case MediaGalleryTileAction.review:
        _review(media);
      case MediaGalleryTileAction.rederive:
        _rederive(media);
      case MediaGalleryTileAction.open:
        _openMedia(media);
      case MediaGalleryTileAction.save:
        _saveToGallery(media);
      case MediaGalleryTileAction.share:
        _share(media);
      case MediaGalleryTileAction.attach:
        _attach(media);
      case MediaGalleryTileAction.delete:
        _delete(media);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final hasAny = _items.isNotEmpty || _unlinked.isNotEmpty;
    return CommandScaffold(
      appBar: AppBar(
        title: const Text('现场资料'),
        actions: [
          IconButton(
            tooltip: '清理过期文件',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: _purge,
            icon: const Icon(DsIcons.cleanSweep),
          ),
        ],
      ),
      body: _loading
          ? const StatePlaceholder.loading(message: '正在加载现场资料…')
          : RefreshIndicator(
              onRefresh: _load,
              child: !hasAny ? _emptyAll() : _bodyWithFilter(),
            ),
    );
  }

  Widget _emptyAll() {
    final hasIncident = _currentIncidentId.isNotEmpty;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.md,
        DsSpacing.pageMargin,
        DsSpacing.xxl,
      ),
      children: [
        StatePlaceholder.empty(
          icon: DsIcons.photoLibrary,
          message: hasIncident ? '还没有拍摄现场照片或录像' : '还没有当前警情',
          detail: hasIncident
              ? '在首页点「水印相机」，文件会保存在这台设备上'
              : '先加入或新建警情，拍摄的现场资料会归到当前警情下',
        ),
      ],
    );
  }

  Widget _bodyWithFilter() {
    final visibleIncident = _filter == MediaGalleryFilter.unlinked
        ? const <LocalMedia>[]
        : _items;
    final visibleUnlinked = _filter == MediaGalleryFilter.incident
        ? const <LocalMedia>[]
        : _unlinked;
    final colors = context.ds.colors;
    final typo = context.ds.typography;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.md,
        DsSpacing.pageMargin,
        DsSpacing.xxl,
      ),
      children: [
        _FilterBar(
          current: _filter,
          allCount: _items.length + _unlinked.length,
          incidentCount: _items.length,
          unlinkedCount: _unlinked.length,
          onChanged: (next) => setState(() => _filter = next),
        ),
        const SizedBox(height: DsSpacing.md),
        if (visibleIncident.isEmpty && visibleUnlinked.isEmpty)
          StatePlaceholder.empty(
            icon: DsIcons.filter,
            message: _filter == MediaGalleryFilter.incident
                ? '当前警情下暂无现场资料'
                : '暂无未关联警情的现场资料',
            detail: '切换其他筛选条件可查看本机保留的全部拍摄资料',
          )
        else ...[
          for (final media in visibleIncident) ...[
            MediaGalleryTile(
              media: media,
              onTap: () => _review(media),
              onAction: (action) => _handleAction(media, action),
            ),
            const SizedBox(height: DsSpacing.sm),
          ],
          if (visibleUnlinked.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.only(
                top: visibleIncident.isNotEmpty ? DsSpacing.sm : DsSpacing.xs,
                bottom: DsSpacing.sm,
              ),
              child: Text(
                '未关联警情（加入警情后可关联并写入记录）',
                style: typo.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textSecondary,
                ),
              ),
            ),
            for (final media in visibleUnlinked) ...[
              MediaGalleryTile(
                media: media,
                onTap: () => _review(media),
                onAction: (action) => _handleAction(media, action),
              ),
              const SizedBox(height: DsSpacing.sm),
            ],
          ],
        ],
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.current,
    required this.allCount,
    required this.incidentCount,
    required this.unlinkedCount,
    required this.onChanged,
  });

  final MediaGalleryFilter current;
  final int allCount;
  final int incidentCount;
  final int unlinkedCount;
  final ValueChanged<MediaGalleryFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: DsSpacing.sm,
      runSpacing: DsSpacing.sm,
      children: [
        _FilterChipButton(
          key: const Key('media-filter-all'),
          label: '全部 ($allCount)',
          selected: current == MediaGalleryFilter.all,
          onTap: () => onChanged(MediaGalleryFilter.all),
        ),
        _FilterChipButton(
          key: const Key('media-filter-incident'),
          label: '当前警情 ($incidentCount)',
          selected: current == MediaGalleryFilter.incident,
          onTap: () => onChanged(MediaGalleryFilter.incident),
        ),
        _FilterChipButton(
          key: const Key('media-filter-unlinked'),
          label: '未关联 ($unlinkedCount)',
          selected: current == MediaGalleryFilter.unlinked,
          onTap: () => onChanged(MediaGalleryFilter.unlinked),
        ),
      ],
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? colors.brand : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderPill,
          side: BorderSide(color: selected ? colors.brand : colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.sm,
              ),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: DsTypography.tabular(
                    ds.typography.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color: selected ? colors.onBrand : colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
