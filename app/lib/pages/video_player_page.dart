import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/video_resources.dart';
import '../theme/app_widgets.dart';

class VideoPlayerPage extends StatefulWidget {
  final VideoResource resource;

  const VideoPlayerPage({super.key, required this.resource});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<bool>? _completedSubscription;
  Timer? _reconnectTimer;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    // Video resources are a portrait-first field tool. Lock this route so a
    // player surface cannot rotate the whole app into landscape.
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    // Use the existing media_kit Video surface instead of maintaining a
    // custom native player. The FLV URL is passed through unchanged.
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'WatchDog video resource',
        bufferSize: 1024 * 1024,
        protocolWhitelist: [
          'udp',
          'rtp',
          'tcp',
          'tls',
          'data',
          'file',
          'http',
          'https',
          'crypto',
        ],
      ),
    );
    _controller = VideoController(_player);
    _errorSubscription = _player.stream.error.listen(_handleError);
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (completed && mounted) _scheduleReconnect();
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    final generation = ++_generation;
    try {
      await _player.open(Media(widget.resource.streamUrl), play: true);
      if (generation == _generation && mounted) {
        setState(() => _error = null);
      }
    } catch (error) {
      _handleError(error.toString());
    }
  }

  void _handleError(String error) {
    if (!mounted) return;
    setState(() => _error = error);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) unawaited(_open());
    });
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.resource.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Video(
                      controller: _controller,
                      fit: BoxFit.contain,
                      controls: NoVideoControls,
                    ),
                    StreamBuilder<bool>(
                      stream: _player.stream.buffering,
                      initialData: _player.state.buffering,
                      builder: (context, snapshot) {
                        if (snapshot.data != true || _error != null) {
                          return const SizedBox.shrink();
                        }
                        return const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        );
                      },
                    ),
                    if (_error != null) const Center(child: _PlayerFailure()),
                  ],
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.alarm.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: AppColors.alarm.withValues(alpha: 0.55),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 8,
                                color: AppColors.alarm,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'HTTP-FLV 直连',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (widget.resource.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        widget.resource.description.trim(),
                        style: const TextStyle(
                          color: Color(0xFFD6D6D6),
                          fontSize: 15,
                          height: 1.6,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      '画面由授权摄像头直接提供。断线后播放器会自动重试；若持续无法播放，请联系管理员检查资源地址或摄像头推流状态。',
                      style: TextStyle(
                        color: Color(0xFF919191),
                        fontSize: 13,
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerFailure extends StatelessWidget {
  const _PlayerFailure();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off_outlined, color: Colors.white, size: 38),
          SizedBox(height: 12),
          Text(
            '视频连接失败，正在自动重试',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 6),
          Text(
            '请检查手机网络或联系管理员确认监控地址',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFABABAB), fontSize: 12),
          ),
        ],
      ),
    );
  }
}
