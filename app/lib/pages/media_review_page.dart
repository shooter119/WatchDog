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
  late LocalMedia _media;
  late final TextEditingController _transcript;
  bool _busy = false;
  bool _deriving = false;
  String _stage = '';
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _media = widget.media;
    _transcript = TextEditingController(text: _media.transcript);
    _deriving = widget.deriving;
    if (_deriving) _runDerive();
  }

  @override
  void dispose() {
    _transcript.dispose();
    super.dispose();
  }

  Future<void> _runDerive() async {
    final updated = await MediaCaptureService.derive(
      _media,
      controller: widget.controller,
      onProgress: (stage) {
        if (!mounted) return;
        setState(() => _stage = stage);
      },
    );
    if (!mounted) return;
    setState(() {
      _media = updated;
      _deriving = false;
      _stage = '';
      if (_transcript.text.trim().isEmpty && updated.transcript.isNotEmpty) {
        _transcript.text = updated.transcript;
      }
    });
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

  Future<void> _submit() async {
    final text = _transcript.text.trim();
    if (text.isEmpty) {
      _toast('口述内容为空，没有可写入的现场记录');
      return;
    }
    final api = widget.controller.api;
    if (api == null) {
      _toast('未连接服务器，当前仅保存在本机');
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
      if (!mounted) return;
      setState(() {
        _submitted = true;
        _busy = false;
      });
      _toast('已写入警情，辅助问答会把它作为现场背景');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('写入失败：$error');
    }
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

  void _removeSegment(LocalAsrSegment segment) {
    final current = _transcript.text;
    final next = current.replaceFirst(segment.text, '').trim();
    setState(() {
      _transcript.text = next;
      _transcript.selection = TextSelection.collapsed(offset: next.length);
    });
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
          _infoCard(),
          const SizedBox(height: 14),
          if (_deriving) _derivingCard(),
          if (!_deriving) ...[
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
              Text(
                _durationText,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (_submitted)
                const Text(
                  '已写入警情',
                  style: TextStyle(fontSize: 12, color: AppColors.safe),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _timeText,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          if (_media.address.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _media.weather.isEmpty
                    ? _media.address
                    : '${_media.address} · ${_media.weather}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          const SizedBox(height: 6),
          const Text(
            '文件只保存在本机，不会自动上传',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _derivingCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
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
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          const Text(
            '识别在本机完成，不上传音频',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
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
            const Text(
              '按住片段可删除误识别内容',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final segment in segments)
                  GestureDetector(
                    onLongPress: () => _removeSegment(segment),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceSubtle,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_formatOffset(segment.startMs)}  ${segment.text}',
                        style: const TextStyle(
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            OutlinedButton.icon(
              onPressed: _busy || _deriving ? null : _share,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('分享'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || _deriving || _submitted ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_rounded, size: 18),
                label: Text(_submitted ? '已写入' : '核对无误，写入警情'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
