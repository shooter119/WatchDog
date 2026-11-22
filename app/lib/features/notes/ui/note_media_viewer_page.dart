import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../design_system/design_system.dart';
import '../data/models/note_media.dart';

/// 火场日志拍照原图缩放预览与视频流式播放页。
class NoteMediaViewerPage extends StatelessWidget {
  const NoteMediaViewerPage({
    super.key,
    required this.attachment,
    this.resolvedFileUrl = '',
    this.mediaHeaders = const <String, String>{},
  });

  final NoteMediaAttachment attachment;
  final String resolvedFileUrl;
  final Map<String, String> mediaHeaders;

  @override
  Widget build(BuildContext context) {
    final hasLocalFile =
        attachment.localPath.isNotEmpty &&
        File(attachment.localPath).existsSync();
    final String? networkUrl =
        (resolvedFileUrl.startsWith('http://') ||
            resolvedFileUrl.startsWith('https://'))
        ? resolvedFileUrl
        : null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(attachment.isVideo ? '火场视频' : '现场照片'),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: attachment.isVideo
                  ? _NoteVideoPlayerView(
                      localPath: hasLocalFile ? attachment.localPath : null,
                      networkUrl: networkUrl,
                      mediaHeaders: mediaHeaders,
                    )
                  : _NotePhotoZoomView(
                      localPath: hasLocalFile ? attachment.localPath : null,
                      networkUrl: networkUrl,
                      mediaHeaders: mediaHeaders,
                    ),
            ),
            if (attachment.address.isNotEmpty || attachment.weather.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.pageMargin,
                  vertical: DsSpacing.sm,
                ),
                color: Colors.black87,
                child: Text(
                  <String>[
                    if (attachment.address.isNotEmpty) attachment.address,
                    if (attachment.weather.isNotEmpty) attachment.weather,
                  ].join(' · '),
                  style: context.ds.typography.caption.copyWith(
                    color: Colors.white70,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NotePhotoZoomView extends StatefulWidget {
  const _NotePhotoZoomView({
    required this.localPath,
    required this.networkUrl,
    required this.mediaHeaders,
  });

  final String? localPath;
  final String? networkUrl;
  final Map<String, String> mediaHeaders;

  @override
  State<_NotePhotoZoomView> createState() => _NotePhotoZoomViewState();
}

class _NotePhotoZoomViewState extends State<_NotePhotoZoomView> {
  int _reloadTick = 0;

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (widget.localPath != null) {
      content = Image.file(
        File(widget.localPath!),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _loadError(),
      );
    } else if (widget.networkUrl != null) {
      content = Image.network(
        widget.networkUrl!,
        key: ValueKey<int>(_reloadTick),
        headers: widget.mediaHeaders.isEmpty ? null : widget.mediaHeaders,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        },
        errorBuilder: (_, _, _) => _loadError(),
      );
    } else {
      content = _loadError();
    }

    return Center(
      child: InteractiveViewer(minScale: 1, maxScale: 4, child: content),
    );
  }

  Widget _loadError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(DsIcons.imageBroken, color: Colors.white54, size: 42),
        const SizedBox(height: DsSpacing.sm),
        const Text('照片加载失败或已清理', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: DsSpacing.md),
        if (widget.networkUrl != null)
          CommandButton(
            label: '重新加载',
            icon: DsIcons.refresh,
            variant: CommandButtonVariant.secondary,
            onPressed: () => setState(() => _reloadTick++),
          ),
      ],
    );
  }
}

class _NoteVideoPlayerView extends StatefulWidget {
  const _NoteVideoPlayerView({
    required this.localPath,
    required this.networkUrl,
    required this.mediaHeaders,
  });

  final String? localPath;
  final String? networkUrl;
  final Map<String, String> mediaHeaders;

  @override
  State<_NoteVideoPlayerView> createState() => _NoteVideoPlayerViewState();
}

class _NoteVideoPlayerViewState extends State<_NoteVideoPlayerView> {
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  bool _playing = false;
  bool _buffering = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  void _initPlayer() {
    final target = widget.localPath ?? widget.networkUrl;
    if (target == null || target.isEmpty) {
      _error = '找不到视频播放地址或已被清理';
      _buffering = false;
      return;
    }
    try {
      final player = Player();
      final controller = VideoController(player);
      _player = player;
      _controller = controller;
      _subs.add(
        player.stream.playing.listen((v) {
          if (mounted) setState(() => _playing = v);
        }),
      );
      _subs.add(
        player.stream.buffering.listen((v) {
          if (mounted) setState(() => _buffering = v);
        }),
      );
      _subs.add(
        player.stream.position.listen((v) {
          if (mounted) setState(() => _position = v);
        }),
      );
      _subs.add(
        player.stream.duration.listen((v) {
          if (mounted) setState(() => _duration = v);
        }),
      );
      _subs.add(
        player.stream.error.listen((msg) {
          if (msg.isNotEmpty && mounted) {
            setState(() {
              _error = '视频播放失败：$msg';
              _buffering = false;
            });
          }
        }),
      );
      unawaited(
        player.open(
          Media(
            target,
            httpHeaders: widget.localPath == null ? widget.mediaHeaders : null,
          ),
          play: true,
        ),
      );
    } catch (_) {
      _error = '当前环境不支持内置视频播放';
      _buffering = false;
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final p = _player;
    _player = null;
    if (p != null) {
      unawaited(p.dispose());
    }
    super.dispose();
  }

  static String _fmt(Duration d) {
    final total = d.inSeconds.clamp(0, 36000);
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_error != null || controller == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(DsSpacing.lg),
          child: Text(
            _error ?? '视频加载失败',
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : 1;
    final posMs = _position.inMilliseconds.clamp(0, maxMs).toDouble();

    return Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Video(controller: controller, controls: NoVideoControls),
              if (_buffering)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
            ],
          ),
        ),
        Container(
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.md,
            vertical: DsSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                iconSize: 28,
                color: Colors.white,
                constraints: const BoxConstraints(
                  minWidth: DsSizes.touchTarget,
                  minHeight: DsSizes.touchTarget,
                ),
                icon: Icon(_playing ? DsIcons.pauseCircle : DsIcons.playCircle),
                onPressed: () => unawaited(_player?.playOrPause()),
              ),
              Text(
                _fmt(_position),
                style: context.ds.typography.captionTabular.copyWith(
                  color: Colors.white,
                ),
              ),
              Expanded(
                child: Slider(
                  value: posMs,
                  min: 0,
                  max: maxMs.toDouble(),
                  onChanged: (value) {
                    unawaited(
                      _player?.seek(Duration(milliseconds: value.round())),
                    );
                  },
                ),
              ),
              Text(
                _fmt(_duration),
                style: context.ds.typography.captionTabular.copyWith(
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
