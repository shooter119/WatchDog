import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../design_system/design_system.dart';
import '../../../services/system_pip.dart';
import '../../../services/video_playback_session.dart';

/// 将冻结的 [VideoPlaybackSession] 状态同步给原生系统画中画自动进入开关。
Future<bool> syncVideoSystemPip(VideoPlaybackSession session) =>
    SystemPip.setAutoEnter(enabled: session.hasResource);

/// 视频播放渲染表面（行内 / 全屏 / 悬浮小窗 / 系统 PiP 共用同一 [VideoPlaybackSession]）。
class VideoPlaybackSurface extends StatelessWidget {
  const VideoPlaybackSurface({
    super.key,
    required this.session,
    this.compact = false,
  });

  final VideoPlaybackSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return ListenableBuilder(
      listenable: session,
      builder: (BuildContext context, _) {
        final controller = session.videoController;
        final connecting =
            session.status == VideoPlaybackStatus.connecting ||
            session.buffering;
        final failed = session.status == VideoPlaybackStatus.failed;

        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (controller != null)
                Video(
                  key: ValueKey<VideoController>(controller),
                  controller: controller,
                  fit: BoxFit.contain,
                  controls: NoVideoControls,
                ),
              if (connecting && !failed)
                Center(
                  child: SizedBox(
                    width: compact ? 24 : 30,
                    height: compact ? 24 : 30,
                    child: CircularProgressIndicator(
                      value: disableAnimations ? 0.72 : null,
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

/// 全屏横屏沉浸式播放页面（与行内/浮窗共享同一 [VideoPlaybackSession]）。
class VideoFullscreenScreen extends StatefulWidget {
  const VideoFullscreenScreen({super.key, required this.session});

  final VideoPlaybackSession session;

  @override
  State<VideoFullscreenScreen> createState() => _VideoFullscreenScreenState();
}

class _VideoFullscreenScreenState extends State<VideoFullscreenScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(syncVideoSystemPip(widget.session));
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
          children: <Widget>[
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
              top: DsSpacing.sm + 2,
              right: DsSpacing.sm + 2,
              child: PlayerOverlayButton(
                key: const Key('video-fullscreen-exit'),
                tooltip: '退出全屏',
                icon: Icons.fullscreen_exit_rounded,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              top: DsSpacing.sm + 2,
              left: DsSpacing.sm + 2,
              child: PlayerOverlayButton(
                key: const Key('video-fullscreen-close'),
                tooltip: '关闭视频',
                icon: Icons.close_rounded,
                onPressed: () {
                  widget.session.stop();
                  unawaited(syncVideoSystemPip(widget.session));
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

/// 应用内悬浮视频小窗（16:9，共享同一 [VideoPlaybackSession]，提供全屏与关闭操作）。
class FloatingVideoOverlay extends StatelessWidget {
  const FloatingVideoOverlay({
    super.key,
    required this.session,
    this.onFullscreen,
    this.onClose,
  });

  final VideoPlaybackSession session;
  final VoidCallback? onFullscreen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('video-floating-window'),
      width: 224,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: DsRadius.borderMd,
        border: Border.all(color: Colors.white30, width: 1),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            VideoPlaybackSurface(session: session, compact: true),
            Positioned(
              top: DsSpacing.xs + 2,
              left: DsSpacing.xs + 2,
              child: PlayerOverlayButton(
                key: const Key('video-floating-fullscreen'),
                tooltip: '全屏播放',
                icon: Icons.fullscreen_rounded,
                onPressed: onFullscreen ?? () {},
              ),
            ),
            Positioned(
              top: DsSpacing.xs + 2,
              right: DsSpacing.xs + 2,
              child: PlayerOverlayButton(
                key: const Key('video-floating-close'),
                tooltip: '关闭浮窗视频',
                icon: Icons.close_rounded,
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.7),
                  width: 1.5,
                ),
                onPressed: () {
                  onClose?.call();
                  session.stop();
                  unawaited(syncVideoSystemPip(session));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频画面浮层操作按钮（≥ 48dp 手套触控热区，暗底高对比白图标）。
class PlayerOverlayButton extends StatelessWidget {
  const PlayerOverlayButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.side,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final BorderSide? side;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: () {
        HapticFeedback.selectionClick();
        onPressed();
      },
      style: IconButton.styleFrom(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const CircleBorder(),
        side: side,
      ),
      icon: Icon(icon, size: DsSizes.iconLg),
    );
  }
}

class _PlayerFailure extends StatelessWidget {
  const _PlayerFailure({required this.compact, required this.onRetry});

  final bool compact;
  final VoidCallback onRetry;

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
            minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
          ),
          icon: const Icon(Icons.refresh_rounded),
        ),
      );
    }

    final typo = (DsTheme.maybeOf(context) ?? DsTheme.night).typography;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DsSpacing.md),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.videocam_off_outlined,
                color: Colors.white,
                size: 32,
              ),
              const SizedBox(height: DsSpacing.xs + 2),
              Text(
                '视频连接失败',
                textAlign: TextAlign.center,
                style: typo.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: DsSpacing.sm),
              OutlinedButton.icon(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                  minimumSize: const Size(0, DsSizes.touchTarget),
                  padding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.md,
                    vertical: DsSpacing.sm,
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: DsSizes.iconMd),
                label: const Text('重新连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
