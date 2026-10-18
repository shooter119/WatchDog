import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/camera_bridge.dart';
import '../services/local_asr_service.dart';
import '../services/local_media_store.dart';
import '../services/media_capture_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 拍摄后的核对页。
///
/// 产品约定：口述文字必须人工核对后才能写入警情；媒体文件始终只在本机，
/// 是否分享由用户在这里逐次决定。
class MediaReviewPage extends StatefulWidget {
  final AppController controller;
  final LocalMedia media;
  final bool deriving;

  const MediaReviewPage({
    super.key,
    required this.controller,
    required this.media,
    this.deriving = false,
  });

  @override
  State<MediaReviewPage> createState() => _MediaReviewPageState();
}

class _MediaReviewPageState extends State<MediaReviewPage> {
  static const Duration _draftDebounce = Duration(milliseconds: 400);

  late LocalMedia _media;
  late final TextEditingController _transcript;
  Timer? _draftTimer;
  String _lastText = '';
  String _savedDraft = '';
  bool _busy = false;
  bool _deriving = false;
  bool _submitted = false;
  String _stage = '';
  String? _deriveError;
  int _deriveRun = 0;

  @override
  void initState() {
    super.initState();
    _media = widget.media;
    _transcript = TextEditingController(text: _media.transcript);
    _lastText = _media.transcript;
    _savedDraft = _media.transcript;
    _transcript.addListener(_onTranscriptChanged);
    _submitted = widget.media.observationId.isNotEmpty;
    _deriving = widget.deriving;
    if (_deriving) {
      unawaited(_runDerive());
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (_transcript.text != _savedDraft) {
      // 离开页面也把最后一段手动编辑落盘，避免草稿随页面一起丢失。
      unawaited(_persistDraft());
    }
    _transcript.removeListener(_onTranscriptChanged);
    _transcript.dispose();
    super.dispose();
  }

  void _onTranscriptChanged() {
    final text = _transcript.text;
    if (text == _lastText) return; // 仅光标移动，不触发保存与重建
    _lastText = text;
    _draftTimer?.cancel();
    if (text != _savedDraft) {
      _draftTimer = Timer(_draftDebounce, _persistDraft);
    }
    if (mounted) setState(() {});
  }

  Future<void> _persistDraft() async {
    final text = _transcript.text;
    if (text == _savedDraft) return;
    try {
      await LocalMediaStore.instance.updateDerived(
        id: _media.id,
        transcript: text,
      );
      _savedDraft = text;
    } catch (_) {
      // 本机存储暂不可用时保留内存内容，下次编辑或写入前会再次尝试。
    }
  }

  Future<void> _flushDraft() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    await _persistDraft();
  }

  Future<void> _runDerive() async {
    final run = ++_deriveRun;
    String? deriveError;
    LocalMedia result;
    try {
      result = await MediaCaptureService.derive(
        _media,
        controller: widget.controller,
        onProgress: (stage) {
          if (!mounted || run != _deriveRun) return;
          setState(() => _stage = stage);
        },
        onError: (message) => deriveError = message,
        isCancelled: () => run != _deriveRun,
      );
    } catch (e) {
      deriveError = '识别失败：$e';
      result = _media;
    }
    if (!mounted || run != _deriveRun) return;
    setState(() {
      _media = result;
      _deriving = false;
      _stage = '';
      _deriveError = deriveError;
    });
    if (_transcript.text.trim().isEmpty && result.transcript.isNotEmpty) {
      _transcript.text = result.transcript;
    }
  }

  void _retryDerive() {
    if (_deriving) return;
    setState(() {
      _deriving = true;
      _deriveError = null;
      _stage = '';
    });
    unawaited(_runDerive());
  }

  void _cancelDerive() {
    _deriveRun++;
    setState(() {
      _deriving = false;
      _stage = '';
      _deriveError = null;
    });
    _toast('已取消识别，可随时重试');
  }

  void _dismissDeriveError() {
    setState(() => _deriveError = null);
  }

  String get _timeText {
    final dt = DateTime.fromMillisecondsSinceEpoch(_media.capturedAt);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String get _durationText {
    if (!_media.isVideo) return '照片';
    final seconds = (_media.durationMs / 1000).round();
    return '视频 ${seconds}s';
  }

  String get _incidentName {
    final incident = widget.controller.currentIncident;
    if (incident == null) return '';
    final title = (incident.title ?? '').trim();
    return title.isNotEmpty ? title : incident.number;
  }

  bool get _hasIncident =>
      (widget.controller.currentIncident?.id ?? '').isNotEmpty;

  bool get _hasText => _transcript.text.trim().isNotEmpty;

  Future<void> _confirmAndSubmit() async {
    if (_busy || _submitted || !_hasText || !_hasIncident) return;
    final text = _transcript.text.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('写入警情？'),
        content: Text(
          '将把核对后的口述写入「$_incidentName」。'
          '写入后辅助问答会引用这段口述。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认写入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _submit(text);
  }

  Future<void> _submit(String text) async {
    if (_submitted || _busy) return;
    final incidentId = widget.controller.currentIncident?.id ?? '';
    if (incidentId.isEmpty) {
      _toast('还没有关联警情，先加入或新建警情才能写入');
      return;
    }
    final api = widget.controller.api;
    if (api == null) {
      await _flushDraft();
      if (!mounted) return;
      _toast('未连接服务器，口述文字已保存在本机草稿，联网后可再写入');
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = true);
    try {
      await api.createIncidentObservation(
        transcript: text,
        sourceType: _media.kind,
        capturedAt: _media.capturedAt,
        mediaRef: _media.id,
      );
      await LocalMediaStore.instance.updateDerived(
        id: _media.id,
        transcript: text,
        observationId: _media.id,
      );
      _savedDraft = text;
      if (!mounted) return;
      setState(() {
        _submitted = true;
        _busy = false;
      });
      _toast('已写入警情，辅助问答会把它作为现场背景');
      // 写入成功同样回到上级页面，避免停在本页让人以为还要再点一次。
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      // 失败时内容仍保留在本机草稿里，用户重进页面不会丢。
      await _flushDraft();
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('写入失败：$error；文字已保存在本机草稿');
    }
  }

  Future<void> _saveOnly() async {
    await _flushDraft();
    if (!mounted) return;
    // 保存即完成本次核对，回到上级页面；结果回传给上级用于提示，
    // 不再停在本页只弹一句 toast（现场会以为没保存成功，反复点）。
    Navigator.of(context).pop(true);
  }

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(_media.path)],
          text: _transcript.text.trim().isEmpty
              ? '火场现场资料'
              : _transcript.text.trim(),
        ),
      );
    } catch (_) {
      _toast('系统分享不可用');
    }
  }

  Future<void> _openMedia() async {
    try {
      await CameraBridge.openWithSystem(_media.path);
    } catch (_) {
      _toast('没有可打开该文件的应用');
    }
  }

  Future<void> _openPhotoViewer(String path) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _PhotoViewerPage(path: path),
      ),
    );
  }

  void _removeSegment(LocalAsrSegment segment) {
    final before = _transcript.text;
    final next = before.replaceFirst(segment.text, '').trim();
    if (next == before) return;
    _transcript.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('已删除该片段'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              if (!mounted) return;
              _transcript.value = TextEditingValue(
                text: before,
                selection: TextSelection.collapsed(offset: before.length),
              );
            },
          ),
        ),
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
        title: const Text('核对现场记录'),
        actions: [
          IconButton(
            tooltip: '打开原始文件',
            onPressed: File(_media.path).existsSync() ? _openMedia : null,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
        children: [
          _mediaPreviewCard(),
          const SizedBox(height: 14),
          _infoCard(),
          const SizedBox(height: 14),
          if (_deriving)
            _derivingCard()
          else ...[
            if (_deriveError != null) ...[
              _deriveErrorCard(),
              const SizedBox(height: 14),
            ],
            _transcriptCard(),
            if (_media.frames.isNotEmpty) ...[
              const SizedBox(height: 14),
              _framesCard(),
            ],
          ],
        ],
      ),
      bottomNavigationBar: _actionBar(),
    );
  }

  String? get _firstFramePath {
    for (final frame in _media.frames) {
      if (File(frame).existsSync()) return frame;
    }
    return null;
  }

  Widget _mediaPreviewCard() {
    final isVideo = _media.isVideo;
    final imagePath = isVideo ? _firstFramePath : _media.path;
    final hasImage =
        imagePath != null && imagePath.isNotEmpty && File(imagePath).existsSync();
    final onTap = isVideo
        ? _openMedia
        : (hasImage ? () => _openPhotoViewer(_media.path) : null);
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            SizedBox(
              height: 220,
              width: double.infinity,
              child: hasImage
                  ? Image.file(
                      File(imagePath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _previewPlaceholder(isVideo),
                    )
                  : _previewPlaceholder(isVideo),
            ),
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
      ),
    );
  }

  Widget _previewPlaceholder(bool isVideo) {
    return Container(
      color: AppColors.surfaceSubtle,
      alignment: Alignment.center,
      child: Icon(
        isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
        size: 42,
        color: AppColors.textSecondary,
      ),
    );
  }

  Widget _infoCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _media.isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
                size: 18,
                color: AppColors.voice,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _durationText,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (_submitted) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: AppColors.online,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '已写入警情',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _timeText,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          if (_media.address.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _media.weather.isEmpty
                    ? _media.address
                    : '${_media.address} · ${_media.weather}',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            '原始文件只保存在本机；只有你核对后的文字会上传',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _derivingCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(height: 12),
          Text(
            _stage.isEmpty ? '正在处理…' : _stage,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            '识别在本机完成，不上传音频',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: _cancelDerive,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('取消识别'),
          ),
        ],
      ),
    );
  }

  Widget _deriveErrorCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: AppColors.timeout,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _deriveError!,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: _dismissDeriveError,
                  child: const Text('手动填写'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _retryDerive,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重试识别'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _transcriptCard() {
    final segments = _media.segments;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '现场口述（请核对后再使用）',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _transcript,
            maxLines: null,
            minLines: 4,
            style: const TextStyle(fontSize: 14, height: 1.5),
            decoration: InputDecoration(
              hintText: '没有识别到口述内容时，可以在这里手动补写',
              hintStyle: TextStyle(color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.surfaceSubtle,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          if (segments.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '按住片段可删除误识别内容，删除后可撤销',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final segment in segments)
                  GestureDetector(
                    key: Key('segment-chip-${segment.startMs}'),
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () => _removeSegment(segment),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceSubtle,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_formatOffset(segment.startMs)}  ${segment.text}',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _formatOffset(int ms) {
    final seconds = (ms / 1000).floor();
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _framesCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('关键画面', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _media.frames.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final path = _media.frames[index];
                return GestureDetector(
                  onTap: () => CameraBridge.openWithSystem(path),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(path),
                      width: 128,
                      height: 84,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 128,
                        height: 84,
                        color: AppColors.surfaceSubtle,
                        child: const Icon(Icons.image_not_supported_outlined),
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

  Widget _actionBar() {
    final primary = FilledButton.icon(
      onPressed: _busy || _deriving || _submitted
          ? null
          : (!_hasText ? _saveOnly : (_hasIncident ? _confirmAndSubmit : null)),
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(
              _submitted
                  ? Icons.check_rounded
                  : (!_hasText
                        ? Icons.save_outlined
                        : Icons.check_rounded),
              size: 18,
            ),
      label: Text(
        _submitted
            ? '已写入'
            : (!_hasText
                  ? '仅保存'
                  : (_hasIncident ? '核对无误，写入警情' : '先加入警情才能写入')),
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final share = OutlinedButton.icon(
      onPressed: _busy || _deriving ? null : _share,
      icon: const Icon(Icons.ios_share_rounded, size: 18),
      label: const Text('分享'),
    );
    // 大字号下并排按钮会挤压文案，改为上下排列并占满整行。
    final stacked = MediaQuery.textScalerOf(context).scale(1) >= 1.4;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: stacked
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: double.infinity, child: primary),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: share),
                ],
              )
            : Row(
                children: [
                  share,
                  const SizedBox(width: 10),
                  Expanded(child: primary),
                ],
              ),
      ),
    );
  }
}

/// 全屏查看照片原图，支持双指缩放。
class _PhotoViewerPage extends StatelessWidget {
  final String path;

  const _PhotoViewerPage({required this.path});

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
              errorBuilder: (_, __, ___) => const Icon(
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

/// 预览角标：照片提示可查看原图，视频提示可播放。
class _PreviewChip extends StatelessWidget {
  final String text;
  final IconData icon;

  const _PreviewChip({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
