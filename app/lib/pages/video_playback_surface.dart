import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/video_playback_session.dart';
import '../theme/app_widgets.dart';

class VideoPlaybackSurface extends StatelessWidget {
  final VideoPlaybackSession session;
  final bool compact;

  const VideoPlaybackSurface({
    super.key,
    required this.session,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final controller = session.videoController;
        final connecting =
            session.status == VideoPlaybackStatus.connecting ||
            session.buffering;
        final failed = session.status == VideoPlaybackStatus.failed;
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (controller != null)
                Video(
                  key: ValueKey(controller),
                  controller: controller,
                  fit: BoxFit.contain,
                  controls: NoVideoControls,
                ),
              if (connecting && !failed)
                Center(
                  child: SizedBox(
                    width: compact ? 24 : 30,
                    height: compact ? 24 : 30,
                    child: const CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.6,
                    ),
                  ),
                ),
              if (failed)
                _PlayerFailure(compact: compact, onRetry: session.retryNow),
            ],
          ),
        );
      },
    );
  }
}

class VideoFullscreenPage extends StatefulWidget {
  final VideoPlaybackSession session;

  const VideoFullscreenPage({super.key, required this.session});

  @override
  State<VideoFullscreenPage> createState() => _VideoFullscreenPageState();
}

class _VideoFullscreenPageState extends State<VideoFullscreenPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: VideoPlaybackSurface(
                  key: const Key('video-fullscreen-surface'),
                  session: widget.session,
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: _OverlayButton(
                key: const Key('video-fullscreen-exit'),
                tooltip: '退出全屏',
                icon: Icons.fullscreen_exit_rounded,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              child: _OverlayButton(
                key: const Key('video-fullscreen-close'),
                tooltip: '关闭视频',
                icon: Icons.close_rounded,
                onPressed: () {
                  widget.session.stop();
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FloatingVideoWindow extends StatelessWidget {
  final VideoPlaybackSession session;
  final VoidCallback? onFullscreen;

  const FloatingVideoWindow({
    super.key,
    required this.session,
    this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('video-floating-window'),
      width: 224,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white30),
        boxShadow: AppShadow.float,
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoPlaybackSurface(session: session, compact: true),
            Positioned(
              top: 2,
              left: 2,
              child: _OverlayButton(
                key: const Key('video-floating-fullscreen'),
                tooltip: '全屏播放',
                icon: Icons.fullscreen_rounded,
                onPressed: onFullscreen ?? () {},
              ),
            ),
            Positioned(
              top: 2,
              right: 2,
              child: _OverlayButton(
                key: const Key('video-floating-close'),
                tooltip: '关闭浮窗视频',
                icon: Icons.close_rounded,
                onPressed: session.stop,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerOverlayButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const PlayerOverlayButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return _OverlayButton(tooltip: tooltip, icon: icon, onPressed: onPressed);
  }
}

class _OverlayButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _OverlayButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon),
    );
  }
}

class _PlayerFailure extends StatelessWidget {
  final bool compact;
  final VoidCallback onRetry;

  const _PlayerFailure({required this.compact, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Center(
        child: IconButton(
          tooltip: '重新连接视频',
          onPressed: onRetry,
          style: IconButton.styleFrom(
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.refresh_rounded),
        ),
      );
    }
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = (constraints.maxHeight / 230).clamp(0.72, 1.0);
          return Transform.scale(
            scale: scale,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.videocam_off_outlined,
                    color: Colors.white,
                    size: 32,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '视频连接失败',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  TextButton.icon(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重新连接'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
