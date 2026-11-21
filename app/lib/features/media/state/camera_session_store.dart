import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../services/camera_bridge.dart';
import '../../../services/screen_on.dart';
import '../../../services/watermark_settings.dart';
import 'camera_flow_policy.dart';
import 'media_gateway.dart';

export 'camera_flow_policy.dart';

/// 水印相机页面状态管理：权限、定位与天气水印、拍照/录像、母版重试与前后台生命周期。
class CameraSessionStore extends ChangeNotifier {
  CameraSessionStore({
    required this.gateway,
    this.onAnnounce,
    this.onOpenReview,
  });

  final MediaGateway gateway;
  final void Function(String message)? onAnnounce;
  final CameraReviewOpener? onOpenReview;

  StreamSubscription<CameraRecordEvent>? _subscription;
  Timer? _ticker;
  Future<void>? _locationWork;
  bool _disposed = false;

  WatermarkPayload _watermark = const WatermarkPayload();
  WatermarkPayload? _recordingWatermark;
  CameraPermissionState _permissions = CameraPermissionState.denied;
  LocationFix? _fix;
  DateTime? _fixReceived;
  DateTime? _recordingStarted;

  bool _permissionDenied = false;
  bool _ready = false;
  bool _locating = false;
  bool _recording = false;
  bool _starting = false;
  bool _capturing = false;
  bool _processing = false;
  bool _torch = false;
  bool _saveWithoutReview = false;
  bool _stateUnknown = false;
  bool _screenHeld = false;

  CameraCaptureMode _mode = CameraCaptureMode.photo;
  CameraCaptureOrientation _captureOrientation =
      CameraCaptureOrientation.landscape;
  Duration _elapsed = Duration.zero;
  String? _statusText;
  String? _processingTaskId;
  double _processingProgress = 0;
  int _mediaTaskSerial = 0;
  PendingMediaRender? _pendingRender;

  WatermarkPayload get watermark => _watermark;
  CameraPermissionState get permissions => _permissions;
  LocationFix? get fix => _fix;
  bool get permissionDenied => _permissionDenied;
  bool get ready => _ready;
  bool get locating => _locating;
  bool get recording => _recording;
  bool get starting => _starting;
  bool get capturing => _capturing;
  bool get processing => _processing;
  bool get torch => _torch;
  bool get stateUnknown => _stateUnknown;
  CameraCaptureMode get mode => _mode;
  CameraCaptureOrientation get captureOrientation => _captureOrientation;
  Duration get elapsed => _elapsed;
  String? get statusText => _statusText;
  double get processingProgress => _processingProgress;
  PendingMediaRender? get pendingRender => _pendingRender;

  MediaIncidentRef? get currentIncident => gateway.readCurrentIncident();
  bool get isUnlinked => (currentIncident?.id ?? '').isEmpty;
  bool get hasPermissionBadges =>
      !_permissions.microphone ||
      !_permissions.location ||
      _locating ||
      !_permissions.preciseLocation;
  bool get isControlLocked =>
      _recording || _starting || _capturing || _processing || _stateUnknown;
  bool get isShutterBusy =>
      _capturing || _processing || _starting || _stateUnknown;
  bool get isTorchDisabled => _capturing || _processing || _starting;

  String get timerText => CameraFlowPolicy.formatTimer(_elapsed);

  Map<String, Object?> get creationParams => <String, Object?>{
    'watermark': _watermark.toMap(),
    'maxDurationMs': CameraBridge.maxRecordingDuration.inMilliseconds,
    'captureOrientation': _captureOrientation.storageValue,
  };

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void setStatusText(String? text) {
    _statusText = text;
    _emit();
  }

  void setMode(CameraCaptureMode next) {
    if (isControlLocked || _mode == next) return;
    _mode = next;
    _emit();
  }

  Future<void> initialize() async {
    _subscription ??= CameraBridge.events.listen(_onRecordEvent);
    final config = await WatermarkSettings.load();
    if (_disposed) return;
    _captureOrientation = config.captureOrientation;
    lockCameraOrientation(config.captureOrientation);
    _emit();
    await bootstrap();
  }

  void _applyGrantedPermissions(CameraPermissionState state) {
    _permissions = state;
    _permissionDenied = false;
    _ready = true;
    _emit();
  }

  Future<void> bootstrap() async {
    final permissions = await CameraBridge.requestPermissions();
    if (_disposed) return;
    if (!permissions.camera) {
      _permissionDenied = true;
      _emit();
      return;
    }
    _applyGrantedPermissions(permissions);
    await loadWatermark();
  }

  Future<void> reloadWatermarkSettings() async {
    final config = await WatermarkSettings.load();
    if (_disposed) return;
    if (_captureOrientation != config.captureOrientation) {
      _captureOrientation = config.captureOrientation;
      lockCameraOrientation(config.captureOrientation);
    }
    await loadWatermark();
  }

  Future<void> requestPermissionsFromDenied() async {
    final state = await CameraBridge.requestPermissions();
    if (_disposed) return;
    if (state.camera) {
      _applyGrantedPermissions(state);
      await loadWatermark();
    } else {
      await CameraBridge.openSystemSettings();
    }
  }

  Future<void> requestOptionalPermissionsAgain() async {
    final state = await CameraBridge.requestPermissions();
    if (_disposed) return;
    _permissions = state;
    _emit();
    if (!state.location || _fix == null) await resolveLocation();
  }

  void handleAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        (_recording || _starting)) {
      _saveWithoutReview = true;
      unawaited(stopRecording());
    }
    if (state == AppLifecycleState.resumed) {
      if (_permissionDenied) unawaited(bootstrap());
      if (_stateUnknown) unawaited(reconcileRecording());
    }
  }

  Future<void> loadWatermark() async {
    final base = await loadCameraBaseWatermark();
    if (_disposed) return;
    _watermark = base;
    _emit();
    await CameraBridge.updateWatermark(_watermark);
    await resolveLocation();
  }

  Future<void> resolveLocation() =>
      _locationWork ??= _fetchLocation().whenComplete(() => _locationWork = null);

  Future<void> _fetchLocation() async {
    _locating = _permissions.location;
    _emit();
    final resolved = await resolveCameraLocationWatermark(
      hasLocationPermission: _permissions.location,
      current: _watermark,
      gateway: gateway,
    );
    if (_disposed) return;
    _fix = resolved.fix;
    _fixReceived = resolved.received;
    _locating = false;
    _watermark = resolved.watermark;
    _emit();
    await CameraBridge.updateWatermark(_watermark);
  }

  Future<WatermarkPayload> _snapshotWatermark() async {
    if (!_permissions.location ||
        CameraFlowPolicy.locationExpired(_fix, _fixReceived, DateTime.now())) {
      if (!_disposed && _permissions.location) setStatusText('定位更新中');
      await resolveLocation();
      if (!_disposed) {
        setStatusText(_fix == null ? '定位不可用，水印不含地点与坐标' : null);
      }
    }
    final snapshot = _watermark.copyWith(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    _watermark = snapshot;
    await CameraBridge.updateWatermark(snapshot);
    return snapshot;
  }

  Future<String?> _renderWatermarkedCopy(PendingMediaRender pending) async {
    final kind = pending.video ? 'video' : 'photo';
    final taskId =
        '${kind}_${DateTime.now().microsecondsSinceEpoch}_${_mediaTaskSerial++}';
    _processing = true;
    _processingTaskId = taskId;
    _processingProgress = 0;
    _statusText = pending.video ? '正在生成水印版视频…' : '正在生成水印版照片…';
    _emit();
    final watermarked = await renderWatermarkedWithWakeLock(
      pending: pending,
      taskId: taskId,
    );
    if (!_disposed) {
      _processing = false;
      _processingTaskId = null;
      _processingProgress = 0;
      _emit();
    }
    return watermarked;
  }

  void applyReviewOutcome(MediaReviewOutcome outcome) =>
      setStatusText(CameraFlowPolicy.outcomeStatusText(outcome));

  Future<void> stopRecording() async {
    try {
      unawaited(HapticFeedback.mediumImpact());
      await CameraBridge.stopRecording();
    } catch (_) {
      await reconcileRecording();
    }
  }

  Future<void> reconcileRecording([String? message]) async {
    try {
      final active = await CameraBridge.isRecording();
      if (_disposed) return;
      _recording = active;
      if (active) _mode = CameraCaptureMode.video;
      _starting = false;
      _stateUnknown = false;
      _statusText = active
          ? '${message ?? '录制异常'}，仍在录像，请点击停止'
          : '${message ?? '录制已结束'}，请到现场资料检查文件';
      if (!active) _ticker?.cancel();
      _screenHeld = active;
      _emit();
      await ScreenOn.setKeepScreenOn(active);
    } catch (_) {
      if (_disposed) return;
      _stateUnknown = true;
      _starting = false;
      setStatusText('无法确认录制状态，请点击“重试确认”；确认前请勿退出');
    }
  }

  Future<bool> _checkStorage(bool video) async {
    final error = await checkCameraStorageError(video: video);
    if (_disposed) return false;
    if (error != null) {
      setStatusText(error);
      return false;
    }
    return true;
  }

  Future<void> toggleTorch() async {
    if (isTorchDisabled) return;
    try {
      await CameraBridge.setTorch(!_torch);
      if (!_disposed) {
        _torch = !_torch;
        _emit();
      }
      await HapticFeedback.selectionClick();
    } catch (_) {
      if (!_disposed) setStatusText('手电筒切换失败，请重试');
    }
  }

  Future<void> takePhoto() async {
    if (isControlLocked) return;
    _capturing = true;
    _emit();
    try {
      if (!await _checkStorage(false)) return;
      final snapshot = await _snapshotWatermark();
      final sourcePath = await CameraBridge.takePhoto();
      if (_disposed) return;
      if (sourcePath == null) {
        setStatusText('拍照失败，请重试');
        return;
      }
      await _completeRender(
        PendingMediaRender(
          video: false,
          sourcePath: sourcePath,
          watermark: snapshot,
          fix: _fix,
        ),
      );
    } on PlatformException catch (error) {
      if (!_disposed) setStatusText(error.message ?? '拍照失败');
    } finally {
      if (!_disposed) {
        _capturing = false;
        _emit();
      }
    }
  }

  Future<void> _completeRender(PendingMediaRender pending) async {
    final watermarked = await _renderWatermarkedCopy(pending);
    if (_disposed) return;
    if (watermarked == null) {
      _pendingRender = pending;
      setStatusText(
        pending.video
            ? '水印视频生成失败，无水印母版已保留，可点击“重新生成水印版”'
            : '水印照片生成失败，母版已保留，可点击“重新生成水印版”',
      );
      if (pending.video) onAnnounce?.call('水印视频生成失败');
      return;
    }
    final media = await registerRenderedMedia(
      pending: pending,
      watermarkedPath: watermarked,
      incidentId: currentIncident?.id ?? '',
    );
    if (_disposed) return;
    if (_pendingRender?.sourcePath == pending.sourcePath) _pendingRender = null;
    if (!pending.video) {
      _statusText = '照片已保存';
    } else if (!pending.review) {
      _statusText = '视频已生成水印版，可到现场资料查看';
    }
    _emit();
    if (!pending.review) return;
    final outcome = await onOpenReview?.call(media, deriving: pending.video);
    if (outcome != null && !_disposed) applyReviewOutcome(outcome);
  }

  Future<void> retryPendingRender() async {
    final pending = _pendingRender;
    if (pending == null || _processing || _capturing || _starting) return;
    await _completeRender(pending);
  }

  Future<void> discardPendingRender() async {
    final pending = _pendingRender;
    if (pending == null) return;
    _pendingRender = null;
    _emit();
    await CameraBridge.deleteLocalFile(pending.sourcePath);
  }

  Future<void> toggleRecording() async {
    if (isShutterBusy) return;
    if (_recording) return stopRecording();
    _starting = true;
    _saveWithoutReview = false;
    _statusText = null;
    _emit();
    try {
      if (!await _checkStorage(true)) {
        if (!_disposed) {
          _starting = false;
          _emit();
        }
        return;
      }
      _recordingWatermark = await _snapshotWatermark();
      await CameraBridge.startRecording();
    } on PlatformException catch (error) {
      if (!_disposed) {
        _recordingWatermark = null;
        _starting = false;
        setStatusText(error.message ?? '无法开始录制');
      }
    }
  }

  Future<bool> stopRecordingAndAwaitFinish() async {
    _saveWithoutReview = true;
    await stopRecording();
    for (var i = 0; i < 30 && _recording; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return !_recording && !_starting;
  }

  void _onRecordEvent(CameraRecordEvent event) {
    if (_disposed) return;
    switch (event.type) {
      case 'started':
        _recording = true;
        _starting = false;
        _elapsed = Duration.zero;
        _recordingStarted = DateTime.now();
        _statusText = null;
        _screenHeld = true;
        _emit();
        unawaited(ScreenOn.setKeepScreenOn(true));
        unawaited(HapticFeedback.mediumImpact());
        onAnnounce?.call('开始录像');
        if (_saveWithoutReview) unawaited(stopRecording());
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (_disposed || _recordingStarted == null) return;
          _elapsed = CameraFlowPolicy.elapsed(_recordingStarted!, DateTime.now());
          _emit();
        });
      case 'stopped':
        _stateUnknown = false;
        _ticker?.cancel();
        _screenHeld = false;
        onAnnounce?.call('录像已停止，正在生成水印版');
        _recording = false;
        _starting = false;
        _statusText = _saveWithoutReview
            ? '视频已保存，正在生成水印版'
            : (event.autoStopped ? '已录满 60 秒，正在生成水印版' : '录像已停止，正在生成水印版');
        _emit();
        final path = event.path;
        if (path != null) {
          final pending = PendingMediaRender(
            video: true,
            sourcePath: path,
            watermark: _recordingWatermark ?? _watermark,
            fix: _fix,
            durationMs: event.durationMs ?? 0,
            review: !_saveWithoutReview,
          );
          _recordingWatermark = null;
          unawaited(_completeRender(pending));
        }
      case 'reached_limit':
        onAnnounce?.call('已达 60 秒上限，正在保存');
        setStatusText('已达 60 秒上限，正在保存…');
      case 'error':
        _recordingWatermark = null;
        unawaited(reconcileRecording(event.message));
      case 'watermark_progress':
        if (event.taskId != _processingTaskId) break;
        final progress = (event.progress ?? 0).clamp(0.0, 1.0);
        _processingProgress = progress;
        setStatusText('正在生成水印版 ${(progress * 100).round()}%');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(SystemChrome.setPreferredOrientations(const []));
    _subscription?.cancel();
    _ticker?.cancel();
    if (_screenHeld) unawaited(ScreenOn.setKeepScreenOn(false));
    final pending = _pendingRender;
    if (pending != null) {
      unawaited(CameraBridge.deleteLocalFile(pending.sourcePath));
    }
    super.dispose();
  }
}
