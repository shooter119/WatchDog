import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/video_resources.dart';

enum VideoPlaybackStatus { idle, connecting, playing, failed }

enum VideoPlaybackPresentation { inline, fullscreen, floating }

/// Owns the one active video stream so inline, fullscreen and floating views
/// can hand off the same media session without opening another connection.
class VideoPlaybackSession extends ChangeNotifier {
  // Commander's HTTP-FLV gateway can take around 15 seconds to invite and
  // bind the upstream device before it returns headers. Showing a failure
  // before that window completes caused a false error followed by a reconnect.
  static const initialFailureGrace = Duration(seconds: 20);
  static const recoveryFailureGrace = Duration(seconds: 2);
  static const reconnectDelay = Duration(seconds: 2);

  VideoResource? _resource;
  Player? _player;
  VideoController? _videoController;
  VideoPlaybackStatus _status = VideoPlaybackStatus.idle;
  VideoPlaybackPresentation _presentation = VideoPlaybackPresentation.inline;
  bool _buffering = false;
  bool _hasVideo = false;
  String? _lastError;
  int _generation = 0;
  bool _disposed = false;

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<int?>? _widthSubscription;
  StreamSubscription<int?>? _heightSubscription;
  Timer? _reconnectTimer;
  Timer? _failureTimer;

  VideoPlaybackSession();

  @visibleForTesting
  VideoPlaybackSession.forTesting({
    VideoResource? resource,
    VideoPlaybackStatus status = VideoPlaybackStatus.idle,
    String? lastError,
  }) : _resource = resource,
       _status = status,
       _lastError = lastError;

  VideoResource? get resource => _resource;
  VideoController? get videoController => _videoController;
  VideoPlaybackStatus get status => _status;
  VideoPlaybackPresentation get presentation => _presentation;
  bool get buffering => _buffering;
  bool get hasResource => _resource != null;
  bool get hasError =>
      _status == VideoPlaybackStatus.failed && _lastError != null;

  void startInline(VideoResource resource) {
    if (_resource?.id != resource.id) {
      _replaceSession(resource);
    } else {
      _presentation = VideoPlaybackPresentation.inline;
      _notify();
      if (_status == VideoPlaybackStatus.failed) {
        retryNow();
      }
    }
  }

  void enterFullscreen() {
    if (!hasResource) return;
    _presentation = VideoPlaybackPresentation.fullscreen;
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    _debugPresentation();
    _notify();
  }

  void enterFloating() {
    if (!hasResource) return;
    _presentation = VideoPlaybackPresentation.floating;
    _usePortrait();
    _debugPresentation();
    _notify();
  }

  void returnInline() {
    if (!hasResource) return;
    _presentation = VideoPlaybackPresentation.inline;
    _usePortrait();
    _debugPresentation();
    _notify();
  }

  void retryNow() {
    if (!hasResource) return;
    _reconnectTimer?.cancel();
    _failureTimer?.cancel();
    _status = VideoPlaybackStatus.connecting;
    _notify();
    _openCurrent();
  }

  void stop() {
    if (_resource == null && _player == null) return;
    _generation++;
    _reconnectTimer?.cancel();
    _failureTimer?.cancel();
    _subscriptionsCancel();

    final player = _player;
    _player = null;
    _videoController = null;
    _resource = null;
    _status = VideoPlaybackStatus.idle;
    _presentation = VideoPlaybackPresentation.inline;
    _debugPresentation();
    _buffering = false;
    _hasVideo = false;
    _lastError = null;
    unawaited(SystemChrome.setPreferredOrientations(const []));
    if (player != null) {
      unawaited(player.dispose());
    }
    _notify();
  }

  void _replaceSession(VideoResource resource) {
    _generation++;
    _reconnectTimer?.cancel();
    _failureTimer?.cancel();
    _subscriptionsCancel();

    final previousPlayer = _player;
    _player = null;
    _videoController = null;
    if (previousPlayer != null) {
      unawaited(previousPlayer.dispose());
    }

    MediaKit.ensureInitialized();
    final player = Player(
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
    final controller = VideoController(player);
    _player = player;
    _videoController = controller;
    _resource = resource;
    _status = VideoPlaybackStatus.connecting;
    _presentation = VideoPlaybackPresentation.inline;
    _buffering = player.state.buffering;
    _hasVideo = false;
    _lastError = null;

    _errorSubscription = player.stream.error.listen(_handleError);
    _bufferingSubscription = player.stream.buffering.listen((value) {
      if (!hasResource) return;
      if (_buffering == value) return;
      _buffering = value;
      _notify();
    });
    _completedSubscription = player.stream.completed.listen((completed) {
      if (completed) _handleInterrupted('播放已结束');
    });
    _widthSubscription = player.stream.width.listen(_handleVideoSize);
    _heightSubscription = player.stream.height.listen(_handleVideoSize);

    _usePortrait();
    _notify();
    _openCurrent();
  }

  void _openCurrent() {
    final player = _player;
    final resource = _resource;
    if (player == null || resource == null) return;

    final generation = ++_generation;
    _reconnectTimer?.cancel();
    _hasVideo = false;
    if (_status != VideoPlaybackStatus.failed) {
      _status = VideoPlaybackStatus.connecting;
      _lastError = null;
      _startFailureGrace(initialFailureGrace);
    }
    _notify();

    unawaited(() async {
      try {
        await player.open(Media(resource.streamUrl), play: true);
      } catch (error) {
        if (generation == _generation) {
          _recordError(error);
        }
      }
    }());
  }

  void _handleVideoSize(int? value) {
    if (!hasResource) return;
    if (value == null || value <= 0) return;
    if (_status == VideoPlaybackStatus.playing) return;
    _failureTimer?.cancel();
    _reconnectTimer?.cancel();
    _hasVideo = true;
    _lastError = null;
    _status = VideoPlaybackStatus.playing;
    _notify();
  }

  void _handleError(String error) {
    _recordError(error);
  }

  void _recordError(Object error) {
    if (!hasResource) return;
    _lastError = error.toString();
    if (kDebugMode) {
      debugPrint('video-session: ${_redactUrl(_lastError!)}');
    }

    if (_isBenignError(_lastError!)) return;
    // mpv can report decoder or demuxer noise after the first frame while the
    // stream keeps running. A completed event is the reliable stop signal.
    if (_hasVideo || _status == VideoPlaybackStatus.playing) return;
    _scheduleReconnect();
  }

  void _handleInterrupted(String reason) {
    if (!hasResource) return;
    _hasVideo = false;
    _lastError = reason;
    _status = VideoPlaybackStatus.connecting;
    _startFailureGrace(recoveryFailureGrace);
    _notify();
    _scheduleReconnect();
  }

  void _startFailureGrace(Duration duration) {
    if (_failureTimer?.isActive == true) return;
    _failureTimer = Timer(duration, () {
      if (!hasResource || _status == VideoPlaybackStatus.playing) {
        return;
      }
      _status = VideoPlaybackStatus.failed;
      _notify();
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (!hasResource || _reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(reconnectDelay, () {
      if (hasResource) _openCurrent();
    });
  }

  void _subscriptionsCancel() {
    unawaited(_errorSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    unawaited(_widthSubscription?.cancel());
    unawaited(_heightSubscription?.cancel());
    _errorSubscription = null;
    _bufferingSubscription = null;
    _completedSubscription = null;
    _widthSubscription = null;
    _heightSubscription = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _redactUrl(String value) => value.replaceAll(
    RegExp(r'https?://\S+', caseSensitive: false),
    '<redacted-url>',
  );

  static bool _isBenignError(String value) {
    final text = value.toLowerCase();
    return text.contains('cannot seek') || text.contains('force-seekable');
  }

  static void _usePortrait() {
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
  }

  void _debugPresentation() {
    if (kDebugMode) {
      debugPrint('video-session: presentation=${_presentation.name}');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _reconnectTimer?.cancel();
    _failureTimer?.cancel();
    _subscriptionsCancel();
    final player = _player;
    _player = null;
    _videoController = null;
    if (player != null) {
      unawaited(player.dispose());
    }
    unawaited(SystemChrome.setPreferredOrientations(const []));
    super.dispose();
  }
}
