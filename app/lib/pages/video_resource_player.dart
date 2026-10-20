import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/video_resources.dart';

class VideoResourcePlayer extends StatefulWidget {
  final VideoResource resource;

  const VideoResourcePlayer({super.key, required this.resource});

  @override
  State<VideoResourcePlayer> createState() => _VideoResourcePlayerState();
}

class _VideoResourcePlayerState extends State<VideoResourcePlayer> {
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
    // A playing resource stays portrait even if the list was opened while the
    // phone was horizontal. Removing this widget restores the prior behavior.
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
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
    return ColoredBox(
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
    );
  }
}

class _PlayerFailure extends StatelessWidget {
  const _PlayerFailure();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off_outlined, color: Colors.white, size: 34),
          SizedBox(height: 10),
          Text(
            '视频连接失败，正在自动重试',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
