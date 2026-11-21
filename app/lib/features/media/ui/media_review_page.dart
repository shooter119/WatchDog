import 'dart:io';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/camera_bridge.dart';
import '../../../services/local_asr_service.dart';
import '../../../services/local_media_store.dart';
import '../state/media_gateway.dart';
import '../state/media_review_store.dart';
import 'media_review_cards.dart';

/// 拍摄后的现场记录核对页（Design System v3.0 重构版）。
///
/// 保持口述人工核对写入、400ms 草稿防抖落盘、防串警情写入守卫、
/// 离线视频 ASR 派生重试/取消、原图与水印版成对保存及全屏看图能力。
class MediaReviewPage extends StatefulWidget {
  const MediaReviewPage({
    super.key,
    required this.gateway,
    required this.media,
    this.deriving = false,
  });

  final MediaGateway gateway;
  final LocalMedia media;
  final bool deriving;

  @override
  State<MediaReviewPage> createState() => _MediaReviewPageState();
}

class _MediaReviewPageState extends State<MediaReviewPage> {
  late final MediaReviewStore _store;

  @override
  void initState() {
    super.initState();
    _store = MediaReviewStore(
      gateway: widget.gateway,
      initialMedia: widget.media,
      initialDeriving: widget.deriving,
    )..addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    _store
      ..removeListener(_onStoreChanged)
      ..dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _confirmAndSubmit() async {
    if (_store.busy ||
        _store.submitted ||
        !_store.hasText ||
        !_store.hasIncident) {
      return;
    }
    final text = _store.transcriptController.text.trim();
    final incidentName = _store.incidentName;
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: '写入警情？',
      builder: (sheetContext) {
        final ds = sheetContext.ds;
        return Text(
          '将把核对后的口述写入「$incidentName」。'
          '写入后辅助问答会引用这段口述。',
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
          label: '确认写入',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    final message = await _store.submitObservation(text);
    if (message != null && mounted) _toast(message);
  }

  Future<void> _saveOnly() async {
    final result = await _store.saveOnly();
    if (result == null || !mounted) return;
    if (!result.succeeded) {
      if (result.errorMessage != null) _toast(result.errorMessage!);
      return;
    }
    Navigator.of(context).pop(result.outcome);
    await _store.cleanupLocalCopy();
  }

  Future<void> _saveAndShare() async {
    final result = await _store.saveAndShare();
    if (result == null || !mounted) return;
    if (!result.succeeded) {
      if (result.errorMessage != null) _toast(result.errorMessage!);
      return;
    }
    Navigator.of(context).pop(result.outcome);
    await _store.cleanupLocalCopy();
  }

  Future<void> _openMedia() async {
    final opened = await CameraBridge.openWithSystem(_store.media.path);
    if (!opened && mounted) _toast('没有可打开该文件的应用');
  }

  Future<void> _openPhotoViewer(String path) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaPhotoViewerPage(path: path),
      ),
    );
  }

  void _cancelDerive() {
    _store.cancelDerive();
    _toast('已取消识别，可随时重试');
  }

  void _removeSegment(LocalAsrSegment segment) {
    final previous = _store.removeSegment(segment);
    if (previous == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('已删除该片段'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              if (!mounted) return;
              _store.restoreTranscript(previous);
            },
          ),
        ),
      );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final media = _store.media;
    return CommandScaffold(
      appBar: AppBar(
        title: const Text('核对现场记录'),
        actions: [
          IconButton(
            tooltip: '打开带水印版',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: File(media.path).existsSync() ? _openMedia : null,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
      body: ListView(
        cacheExtent: 1000,
        padding: const EdgeInsets.fromLTRB(
          DsSpacing.pageMargin,
          14,
          DsSpacing.pageMargin,
          160,
        ),
        children: [
          MediaPreviewCard(
            media: media,
            firstFramePath: _store.firstExistingFramePath,
            onOpenVideo: _openMedia,
            onOpenPhotoViewer: _openPhotoViewer,
          ),
          const SizedBox(height: DsSpacing.md),
          MediaInfoCard(
            media: media,
            durationText: _store.durationText,
            timeText: _store.timeText,
            submitted: _store.submitted,
          ),
          const SizedBox(height: DsSpacing.md),
          if (_store.deriving)
            MediaDerivingCard(stage: _store.stage, onCancel: _cancelDerive)
          else ...[
            if (_store.deriveError != null) ...[
              MediaDeriveErrorCard(
                errorMessage: _store.deriveError!,
                onDismiss: _store.dismissDeriveError,
                onRetry: _store.retryDerive,
              ),
              const SizedBox(height: DsSpacing.md),
            ],
            MediaTranscriptCard(
              controller: _store.transcriptController,
              segments: media.segments,
              hasText: _store.hasText,
              hasIncident: _store.hasIncident,
              submitted: _store.submitted,
              busy: _store.busy,
              deriving: _store.deriving,
              onConfirmAndSubmit: _confirmAndSubmit,
              onRemoveSegment: _removeSegment,
            ),
            if (media.frames.isNotEmpty) ...[
              const SizedBox(height: DsSpacing.md),
              MediaFramesCard(
                frames: media.frames,
                onOpenFrame: CameraBridge.openWithSystem,
              ),
            ],
          ],
        ],
      ),
      bottomNavigationBar: _ActionBar(
        enabled: _store.actionsEnabled,
        busy: _store.busy,
        onSaveOnly: _saveOnly,
        onSaveAndShare: _saveAndShare,
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.enabled,
    required this.busy,
    required this.onSaveOnly,
    required this.onSaveAndShare,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onSaveOnly;
  final VoidCallback onSaveAndShare;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        10,
        DsSpacing.lg,
        DsSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: CommandButton(
                    key: const Key('review-save-only'),
                    label: '仅保存',
                    icon: Icons.save_alt_rounded,
                    variant: CommandButtonVariant.secondary,
                    size: CommandButtonSize.large,
                    enabled: enabled,
                    onPressed: onSaveOnly,
                  ),
                ),
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: CommandButton(
                    key: const Key('review-save-share'),
                    label: '保存并分享',
                    icon: Icons.ios_share_rounded,
                    variant: CommandButtonVariant.primary,
                    size: CommandButtonSize.large,
                    enabled: enabled,
                    isLoading: busy,
                    onPressed: onSaveAndShare,
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
