import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import '../services/screen_on.dart';
import '../services/storage_service.dart';

import '../models/models.dart';
import '../services/camera_bridge.dart';
import '../services/settings.dart';
import '../services/watermark_settings.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'media_gallery_page.dart';
import 'media_review_page.dart';
import '../services/media_capture_service.dart';

/// 拍摄模式：拍照 / 录像分开，避免同一个快门同时承担点击与长按
/// —— 戴厚手套时一次迟疑的按压会被误判成录像。
/// Shared capture rules keep freshness and storage decisions independently testable.
class CameraFlowPolicy {
  static bool locationExpired(
    LocationFix? fix,
    DateTime? received,
    DateTime now,
  ) =>
      fix == null ||
      received == null ||
      fix.ageMs + now.difference(received).inMilliseconds > 300000;
  static int minimumBytes(bool video) => (video ? 200 : 20) * 1024 * 1024;
  static Duration elapsed(DateTime started, DateTime now) =>
      now.isBefore(started) ? Duration.zero : now.difference(started);
}

enum _CaptureMode { photo, video }

class _PendingRender {
  final bool video;
  final String sourcePath;
  final WatermarkPayload watermark;
  final LocationFix? fix;
  final int durationMs;
  final bool review;

  const _PendingRender({
    required this.video,
    required this.sourcePath,
    required this.watermark,
    required this.fix,
    this.durationMs = 0,
    this.review = true,
  });
}

enum _PendingRenderChoice { retry, discard }

/// 水印相机页。
///
/// 现场约束（已按 UX 审查修正）：
/// - 拍照与录像用显式模式切换，不再依赖长按手势
/// - 每次拍摄前重新生成水印快照，保证「烧进像素的时间 = 入库时间」
/// - 录像中返回会二次确认并等待保存完成，避免产生找不到的孤儿文件
/// - 没有关联警情时明确提示，不再静默写入空 incident_id
class CameraPage extends StatefulWidget {
  final AppController controller;

  const CameraPage({super.key, required this.controller});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  StreamSubscription<CameraRecordEvent>? _subscription;

  WatermarkPayload _watermark = const WatermarkPayload();
  WatermarkPayload? _recordingWatermark;
  CameraPermissionState _permissions = CameraPermissionState.denied;
  LocationFix? _fix;
  bool _permissionDenied = false;
  bool _ready = false;
  bool _locating = false;
  bool _recording = false;
  bool _starting = false;
  bool _capturing = false;
  bool _processing = false;
  bool _torch = false;
  _CaptureMode _mode = _CaptureMode.photo;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  DateTime? _recordingStarted;
  DateTime? _fixReceived;
  Future<void>? _locationWork;
  bool _saveWithoutReview = false;
  bool _stateUnknown = false;
  bool _screenHeld = false;
  CameraCaptureOrientation _captureOrientation =
      CameraCaptureOrientation.landscape;

  /// 已确认可以离开：置位后放开 PopScope，再执行真正的 pop。
  bool _leaving = false;

  /// 关闭流程进行中（含录像确认弹窗），防止连点叉/返回键触发多次 pop。
  bool _closing = false;
  String? _statusText;
  String? _processingTaskId;
  double _processingProgress = 0;
  int _mediaTaskSerial = 0;
  _PendingRender? _pendingRender;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = CameraBridge.events.listen(_onRecordEvent);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    // 离开相机页恢复为不限制方向，避免影响 App 其余页面
    unawaited(SystemChrome.setPreferredOrientations(const []));
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _ticker?.cancel();
    if (_screenHeld) unawaited(ScreenOn.setKeepScreenOn(false));
    final pending = _pendingRender;
    if (pending != null) {
      unawaited(CameraBridge.deleteLocalFile(pending.sourcePath));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        (_recording || _starting)) {
      _saveWithoutReview = true;
      unawaited(_stopRecording());
    }
    if (state == AppLifecycleState.resumed) {
      if (_permissionDenied) unawaited(_bootstrap());
      if (_stateUnknown) unawaited(_reconcileRecording());
    }
  }

  Future<void> _stopRecording() async {
    try {
      unawaited(HapticFeedback.mediumImpact());
      await CameraBridge.stopRecording();
    } catch (_) {
      await _reconcileRecording();
    }
  }

  void _announce(String message) {
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  String _nextMediaTaskId(String kind) =>
      '${kind}_${DateTime.now().microsecondsSinceEpoch}_${_mediaTaskSerial++}';

  Future<String?> _renderWatermarkedCopy({
    required String sourcePath,
    required WatermarkPayload watermark,
    required String taskId,
    required bool video,
  }) async {
    setState(() {
      _processing = true;
      _processingTaskId = taskId;
      _processingProgress = 0;
      _statusText = video ? '正在生成水印版视频…' : '正在生成水印版照片…';
    });
    await ScreenOn.setKeepScreenOn(true);
    final watermarked = await CameraBridge.renderWatermarkedCopy(
      sourcePath: sourcePath,
      watermark: watermark,
      taskId: taskId,
    );
    await ScreenOn.setKeepScreenOn(false);
    if (mounted) {
      setState(() {
        _processing = false;
        _processingTaskId = null;
        _processingProgress = 0;
      });
    }
    return watermarked;
  }

  void _showReviewOutcome(MediaReviewOutcome outcome) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {
      _statusText = switch (outcome) {
        MediaReviewOutcome.saved => '已保存带水印版和无水印版到手机相册',
        MediaReviewOutcome.savedWatermarkedOnly => '旧资料仅保存了带水印版',
        MediaReviewOutcome.shared => '两份已保存，分享菜单已关闭',
        MediaReviewOutcome.sharedWatermarkedOnly => '旧资料已保存带水印版，分享菜单已关闭',
      };
    });
  }

  Future<void> _reconcileRecording([String? message]) async {
    try {
      final active = await CameraBridge.isRecording();
      if (!mounted) return;
      setState(() {
        _recording = active;
        if (active) _mode = _CaptureMode.video;
        _starting = false;
        _stateUnknown = false;
        _statusText = active
            ? '${message ?? '录制异常'}，仍在录像，请点击停止'
            : '${message ?? '录制已结束'}，请到现场资料检查文件';
      });
      if (!active) _ticker?.cancel();
      _screenHeld = active;
      await ScreenOn.setKeepScreenOn(active);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stateUnknown = true;
        _starting = false;
        _statusText = '无法确认录制状态，请点击“重试确认”；确认前请勿退出';
      });
    }
  }

  Future<void> _initialize() async {
    final config = await WatermarkSettings.load();
    if (!mounted) return;
    setState(() => _captureOrientation = config.captureOrientation);
    unawaited(
      SystemChrome.setPreferredOrientations(switch (config.captureOrientation) {
        CameraCaptureOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        CameraCaptureOrientation.portrait => const [
          DeviceOrientation.portraitUp,
        ],
      }),
    );
    await _bootstrap();
  }

  Future<void> _bootstrap() async {
    final permissions = await CameraBridge.requestPermissions();
    if (!mounted) return;
    if (!permissions.camera) {
      setState(() => _permissionDenied = true);
      return;
    }
    setState(() {
      _permissions = permissions;
      _permissionDenied = false;
      _ready = true;
    });
    await _loadWatermark();
  }

  /// 读取水印配置；单位抬头与拍摄单位来自独立设置，未配置时回落到单位名称。
  Future<void> _loadWatermark() async {
    final config = await WatermarkSettings.load();
    final unitName = await Settings.unitName;
    if (!mounted) return;
    setState(() {
      _watermark = WatermarkPayload(
        unitTitle: config.unitTitle.isNotEmpty ? config.unitTitle : unitName,
        department: config.department,
        actorName: config.actorName,
        showTime: config.showTime,
        showWeather: config.showWeather,
        showLocation: config.showLocation,
        showCoordinates: config.showCoordinates,
        showLogo: config.showLogo,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    });
    await CameraBridge.updateWatermark(_watermark);
    await _resolveLocation();
  }

  Future<void> _resolveLocation() => _locationWork ??= _fetchLocation()
      .whenComplete(() => _locationWork = null);

  Future<void> _fetchLocation() async {
    setState(() => _locating = _permissions.location);
    var fix = _permissions.location
        ? await CameraBridge.currentLocation()
        : null;
    final received = DateTime.now();
    if (fix != null && fix.ageMs > 300000) fix = null;
    if (!mounted) return;

    WeatherInfo weather = WeatherInfo.empty;
    final api = widget.controller.api;
    if (fix != null && api != null) {
      weather = await api.fetchWeather(lat: fix.lat, lon: fix.lon);
    }
    if (!mounted) return;
    setState(() {
      _fix = fix;
      _fixReceived = received;
      _locating = false;
      _watermark = WatermarkPayload(
        unitTitle: _watermark.unitTitle,
        department: _watermark.department,
        actorName: _watermark.actorName,
        timestampMs: _watermark.timestampMs,
        showTime: _watermark.showTime,
        showWeather: _watermark.showWeather,
        showLocation: _watermark.showLocation,
        showCoordinates: _watermark.showCoordinates,
        showLogo: _watermark.showLogo,
        address: weather.address?.isNotEmpty == true ? weather.address! : '',
        weather: weather.line ?? '',
        latitude: fix?.lat,
        longitude: fix?.lon,
      );
    });
    await CameraBridge.updateWatermark(_watermark);
  }

  /// 拍摄前刷新水印快照：这是「照片上的时间」与「入库时间」一致的唯一保证。
  Future<WatermarkPayload> _snapshotWatermark() async {
    if (!_permissions.location ||
        CameraFlowPolicy.locationExpired(_fix, _fixReceived, DateTime.now())) {
      if (mounted && _permissions.location) {
        setState(() => _statusText = '定位更新中');
      }
      await _resolveLocation();
      if (mounted) {
        setState(() => _statusText = _fix == null ? '定位不可用，水印不含地点与坐标' : null);
      }
    }
    final snapshot = _watermark.copyWith(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    _watermark = snapshot;
    await CameraBridge.updateWatermark(snapshot);
    return snapshot;
  }

  void _onRecordEvent(CameraRecordEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'started':
        setState(() {
          _recording = true;
          _starting = false;
          _elapsed = Duration.zero;
          _recordingStarted = DateTime.now();
          _statusText = null;
        });
        _screenHeld = true;
        unawaited(ScreenOn.setKeepScreenOn(true));
        unawaited(HapticFeedback.mediumImpact());
        _announce('开始录像');
        if (_saveWithoutReview) unawaited(_stopRecording());
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (!mounted) return;
          setState(
            () => _elapsed = CameraFlowPolicy.elapsed(
              _recordingStarted!,
              DateTime.now(),
            ),
          );
        });
        break;
      case 'stopped':
        _stateUnknown = false;
        _ticker?.cancel();
        _screenHeld = false;
        _announce('录像已停止，正在生成水印版');
        setState(() {
          _recording = false;
          _starting = false;
          _statusText = _saveWithoutReview
              ? '视频已保存，正在生成水印版'
              : (event.autoStopped ? '已录满 60 秒，正在生成水印版' : '录像已停止，正在生成水印版');
        });
        final path = event.path;
        if (path != null) _openReviewForVideo(path, event.durationMs ?? 0);
        break;
      case 'reached_limit':
        _announce('已达 60 秒上限，正在保存');
        setState(() => _statusText = '已达 60 秒上限，正在保存…');
        break;
      case 'error':
        _recordingWatermark = null;
        unawaited(_reconcileRecording(event.message));
        break;
      case 'watermark_progress':
        if (event.taskId != _processingTaskId) break;
        final progress = (event.progress ?? 0).clamp(0.0, 1.0);
        setState(() {
          _processingProgress = progress;
          _statusText = '正在生成水印版 ${(progress * 100).round()}%';
        });
        break;
    }
  }

  Future<bool> _checkStorage(bool video) async {
    final bytes = await StorageService.availableBytes();
    if (!mounted) return false;
    if (bytes == null || bytes < CameraFlowPolicy.minimumBytes(video)) {
      setState(
        () => _statusText = bytes == null
            ? '无法检查存储空间，请重试后拍摄'
            : '存储空间不足，请清理至少 ${video ? 200 : 20} MB 后重试',
      );
      return false;
    }
    return true;
  }

  Future<void> _toggleTorch() async {
    if (_capturing || _starting) return;
    try {
      await CameraBridge.setTorch(!_torch);
      if (mounted) setState(() => _torch = !_torch);
      await HapticFeedback.selectionClick();
    } catch (_) {
      if (mounted) setState(() => _statusText = '手电筒切换失败，请重试');
    }
  }

  Future<void> _takePhoto() async {
    if (_capturing || _processing || _recording || _starting || _stateUnknown) {
      return;
    }
    if (!await _confirmPendingBeforeNewCapture()) return;
    setState(() => _capturing = true);
    try {
      if (!await _checkStorage(false)) return;
      final snapshot = await _snapshotWatermark();
      final sourcePath = await CameraBridge.takePhoto();
      if (!mounted) return;
      if (sourcePath == null) {
        setState(() => _statusText = '拍照失败，请重试');
        return;
      }
      await _finishPhoto(
        _PendingRender(
          video: false,
          sourcePath: sourcePath,
          watermark: snapshot,
          fix: _fix,
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _statusText = error.message ?? '拍照失败');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _finishPhoto(_PendingRender pending) async {
    final taskId = _nextMediaTaskId('photo');
    final path = await _renderWatermarkedCopy(
      sourcePath: pending.sourcePath,
      watermark: pending.watermark,
      taskId: taskId,
      video: false,
    );
    if (!mounted) return;
    if (path == null) {
      setState(() {
        _pendingRender = pending;
        _statusText = '水印照片生成失败，母版已保留，可点击“重新生成水印版”';
      });
      return;
    }
    final media = await MediaCaptureService.registerPhoto(
      incidentId: widget.controller.currentIncident?.id ?? '',
      path: path,
      sourcePath: pending.sourcePath,
      watermark: pending.watermark,
      fix: pending.fix,
    );
    if (!mounted) return;
    setState(() {
      if (_pendingRender?.sourcePath == pending.sourcePath) {
        _pendingRender = null;
      }
      _statusText = '照片已保存';
    });
    final outcome = await Navigator.of(context).push<MediaReviewOutcome>(
      MaterialPageRoute<MediaReviewOutcome>(
        builder: (_) =>
            MediaReviewPage(controller: widget.controller, media: media),
      ),
    );
    if (outcome != null && mounted) {
      // 核对页的 SnackBar 会跨页留在底部，正好盖住左下角水印；回到取景页
      // 就收起它，改在右侧控制区显示状态，保证水印始终完整可见。
      _showReviewOutcome(outcome);
    }
  }

  Future<void> _retryPendingRender() async {
    final pending = _pendingRender;
    if (pending == null || _processing || _capturing || _starting) return;
    if (pending.video) {
      await _finishVideo(pending);
    } else {
      await _finishPhoto(pending);
    }
  }

  Future<void> _discardPendingRender() async {
    final pending = _pendingRender;
    if (pending == null) return;
    if (mounted) {
      setState(() => _pendingRender = null);
    } else {
      _pendingRender = null;
    }
    await CameraBridge.deleteLocalFile(pending.sourcePath);
  }

  Future<bool> _confirmPendingBeforeNewCapture() async {
    final pending = _pendingRender;
    if (pending == null) return true;
    final choice = await showDialog<_PendingRenderChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(pending.video ? '上段视频尚未生成水印版' : '上张照片尚未生成水印版'),
        content: const Text('原始母版仍保留在本机。可先重试生成，或放弃后重新拍摄。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _PendingRenderChoice.discard),
            child: const Text('放弃母版'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _PendingRenderChoice.retry),
            child: const Text('重试生成'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    switch (choice) {
      case _PendingRenderChoice.retry:
        await _retryPendingRender();
        return false;
      case _PendingRenderChoice.discard:
        await _discardPendingRender();
        return true;
      case null:
        return false;
    }
  }

  Future<void> _toggleRecording() async {
    if (_starting || _capturing || _processing || _stateUnknown) return;
    if (_recording) {
      await _stopRecording();
      return;
    }
    if (!await _confirmPendingBeforeNewCapture()) return;
    setState(() {
      _starting = true;
      _saveWithoutReview = false;
      _statusText = null;
    });
    try {
      if (!await _checkStorage(true)) {
        if (mounted) setState(() => _starting = false);
        return;
      }
      _recordingWatermark = await _snapshotWatermark();
      await CameraBridge.startRecording();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _recordingWatermark = null;
        _starting = false;
        _statusText = error.message ?? '无法开始录制';
      });
    }
  }

  Future<void> _openReviewForVideo(String path, int durationMs) async {
    final pending = _PendingRender(
      video: true,
      sourcePath: path,
      watermark: _recordingWatermark ?? _watermark,
      fix: _fix,
      durationMs: durationMs,
      review: !_saveWithoutReview,
    );
    _recordingWatermark = null;
    await _finishVideo(pending);
  }

  Future<void> _finishVideo(_PendingRender pending) async {
    final taskId = _nextMediaTaskId('video');
    final watermarked = await _renderWatermarkedCopy(
      sourcePath: pending.sourcePath,
      watermark: pending.watermark,
      taskId: taskId,
      video: true,
    );
    if (!mounted) return;
    if (watermarked == null) {
      setState(() {
        _pendingRender = pending;
        _statusText = '水印视频生成失败，无水印母版已保留，可点击“重新生成水印版”';
      });
      _announce('水印视频生成失败');
      return;
    }
    final media = await MediaCaptureService.registerVideo(
      incidentId: widget.controller.currentIncident?.id ?? '',
      path: watermarked,
      sourcePath: pending.sourcePath,
      durationMs: pending.durationMs,
      watermark: pending.watermark,
      fix: pending.fix,
    );
    if (!mounted) return;
    setState(() {
      if (_pendingRender?.sourcePath == pending.sourcePath) {
        _pendingRender = null;
      }
      if (!pending.review) {
        _statusText = '视频已生成水印版，可到现场资料查看';
      }
    });
    if (!pending.review) {
      return;
    }
    final outcome = await Navigator.of(context).push<MediaReviewOutcome>(
      MaterialPageRoute<MediaReviewOutcome>(
        builder: (_) => MediaReviewPage(
          controller: widget.controller,
          media: media,
          deriving: true,
        ),
      ),
    );
    if (outcome != null && mounted) {
      _showReviewOutcome(outcome);
    }
  }

  Future<void> _handleClose(BuildContext context) async {
    if (_closing || _leaving) return;
    _closing = true;
    final navigator = Navigator.of(context);
    try {
      if (!await _confirmLeave()) return;
      if (!mounted) return;
      // PopScope 默认 canPop=false 用于拦截系统返回并先做录像确认；
      // 确认完成后必须显式放开并直接 pop，不能再用 maybePop
      //（那会被自己的 PopScope 拦住，表现为点叉无反应）。
      setState(() => _leaving = true);
      navigator.pop();
    } finally {
      // 退出成功后页面即销毁；被取消（正在拍照/仍录像）时允许再次尝试。
      if (!_leaving) _closing = false;
    }
  }

  Future<void> _openGallery() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaGalleryPage(controller: widget.controller),
      ),
    );
  }

  /// 退出前确认：录像中必须先停下来并等文件落盘，否则会出现找不到的孤儿文件。
  Future<bool> _confirmLeave() async {
    if (_processing) {
      setState(() => _statusText = '正在生成水印版，请稍候');
      return false;
    }
    if (_capturing) {
      setState(() => _statusText = '正在保存照片，请稍候');
      return false;
    }
    if (_stateUnknown) {
      await _reconcileRecording();
      return false;
    }
    if (_pendingRender != null) {
      final choice = await showDialog<_PendingRenderChoice>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('水印成片尚未生成'),
          content: const Text('当前原始母版仍保留在本机。继续生成会返回处理流程，退出并删除会放弃这份母版。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, _PendingRenderChoice.discard),
              child: const Text('退出并删除'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, _PendingRenderChoice.retry),
              child: const Text('继续生成'),
            ),
          ],
        ),
      );
      if (!mounted) return false;
      switch (choice) {
        case _PendingRenderChoice.retry:
          await _retryPendingRender();
          return false;
        case _PendingRenderChoice.discard:
          await _discardPendingRender();
          return true;
        case null:
          return false;
      }
    }
    if (!mounted) return false;
    if (!_recording && !_starting) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('正在录像'),
        content: const Text('退出会结束并保存这段视频。确定退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续录制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('结束并退出'),
          ),
        ],
      ),
    );
    if (leave != true) return false;
    _saveWithoutReview = true;
    await _stopRecording();
    // 等待 stopped 事件完成入库，最多 3 秒
    for (var i = 0; i < 30 && _recording; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return !_recording && !_starting;
  }

  String get _timerText {
    final total = _elapsed.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (!CameraBridge.isSupported) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('当前平台暂不支持水印相机', style: TextStyle(color: Colors.white)),
        ),
      );
    }
    if (_permissionDenied) return _permissionScreen();
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 12),
              Text('正在准备相机…', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    final creationParams = <String, Object?>{
      'watermark': _watermark.toMap(),
      'maxDurationMs': CameraBridge.maxRecordingDuration.inMilliseconds,
      'captureOrientation': _captureOrientation.storageValue,
    };

    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 路由已在退场流程中，直接用外层 context 的 Navigator 实例
        await _handleClose(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _captureOrientation == CameraCaptureOrientation.landscape
            ? Row(
                key: const Key('camera-landscape-layout'),
                children: [
                  Expanded(child: _preview(creationParams)),
                  SizedBox(width: 220, child: _bottomBar(vertical: true)),
                ],
              )
            : Column(
                key: const Key('camera-portrait-layout'),
                children: [
                  AspectRatio(
                    key: const Key('camera-portrait-preview'),
                    aspectRatio: 16 / 9,
                    child: _preview(creationParams),
                  ),
                  Expanded(child: _bottomBar()),
                ],
              ),
      ),
    );
  }

  Widget _preview(Map<String, Object?> creationParams) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AndroidView(
          viewType: CameraBridge.viewType,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        ),
        _topBar(),
      ],
    );
  }

  Widget _permissionScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.no_photography_outlined,
                  size: 48,
                  color: Colors.white54,
                ),
                const SizedBox(height: 16),
                const Text(
                  '需要相机权限才能拍摄现场资料',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '拍摄内容只保存在本机，不会自动上传',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 8),
                const Text(
                  '麦克风用于记录现场口述；定位用于在水印标注拍摄地点。未授权时不会填入推测位置。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: CameraBridge.openSystemSettings,
                  child: const Text('去系统设置'),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: () async {
                    final state = await CameraBridge.requestPermissions();
                    if (!mounted) return;
                    if (state.camera) {
                      setState(() {
                        _permissions = state;
                        _permissionDenied = false;
                        _ready = true;
                      });
                      await _loadWatermark();
                    } else {
                      await CameraBridge.openSystemSettings();
                    }
                  },
                  child: const Text('重新授权'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final unlinked = (widget.controller.currentIncident?.id ?? '').isEmpty;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
              child: Row(
                children: [
                  _roundIcon(
                    icon: Icons.close_rounded,
                    tooltip: '关闭',
                    onTap: () => _handleClose(context),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '现场资料',
                    onPressed:
                        (_recording ||
                            _capturing ||
                            _processing ||
                            _starting ||
                            _stateUnknown)
                        ? null
                        : _openGallery,
                    icon: const Icon(
                      Icons.photo_library_outlined,
                      color: Colors.white,
                    ),
                  ),
                  if (_hasPermissionBadges) ...[
                    const SizedBox(width: 4),
                    Flexible(child: _permissionBadges()),
                  ],
                ],
              ),
            ),
            if (!unlinked)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment:
                      _captureOrientation == CameraCaptureOrientation.portrait
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: _incidentChip(unlinked),
                ),
              ),
            if (_recording)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _elapsed.inSeconds >= 50
                        ? const Color(0xFFE65100)
                        : const Color(0xCCD32029),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.fiber_manual_record,
                        size: 12,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$_timerText · 剩 ${(60 - _elapsed.inSeconds).clamp(0, 60)}s',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
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

  /// 当前警情标签：拍摄时始终能看到自己正在为哪一场警情留证。
  /// 水印卡片本身不放警情字段（会让信息卡过高），放在取景页顶部即可。
  Widget _incidentChip(bool unlinked) {
    final title = widget.controller.currentIncident?.title ?? '';
    final label = unlinked || title.isEmpty ? '未关联警情' : title;
    return Container(
      key: const Key('camera-incident-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: unlinked ? const Color(0xFFB26B00) : Colors.white24,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            size: 13,
            color: unlinked ? const Color(0xFFFFB84D) : Colors.white70,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: unlinked ? const Color(0xFFFFD9A3) : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 麦克风/定位被拒时给出可见状态，避免「录了没声音、地址是空的」却毫无解释。
  bool get _hasPermissionBadges =>
      !_permissions.microphone ||
      !_permissions.location ||
      _locating ||
      !_permissions.preciseLocation;

  Widget _permissionBadges() {
    final badges = <Widget>[];
    if (!_permissions.microphone) {
      badges.add(
        _badge('麦克风未授权', Icons.mic_off_rounded, () => _requestAgain()),
      );
    }
    if (!_permissions.location) {
      badges.add(
        _badge('定位未授权', Icons.location_off_rounded, () => _requestAgain()),
      );
    } else if (_locating) {
      badges.add(_badge('定位更新中', Icons.location_searching_rounded, null));
    } else if (!_permissions.preciseLocation) {
      badges.add(_badge('粗略定位', Icons.location_searching_rounded, null));
    }
    if (badges.isEmpty) return const SizedBox.shrink();
    return Wrap(alignment: WrapAlignment.end, children: badges);
  }

  Widget _badge(String label, IconData icon, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: Colors.white70),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _requestAgain() async {
    final state = await CameraBridge.requestPermissions();
    if (!mounted) return;
    setState(() => _permissions = state);
    if (!state.location || _fix == null) await _resolveLocation();
  }

  Widget _roundIcon({
    required IconData icon,
    String? tooltip,
    VoidCallback? onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, color: Colors.white, size: 24),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black38,
        minimumSize: const Size(48, 48),
      ),
    );
  }

  Widget _bottomBar({bool vertical = false}) {
    return Container(
      width: double.infinity,
      padding: vertical
          ? const EdgeInsets.fromLTRB(8, 24, 8, 24)
          : const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101419),
        border: Border(
          top: vertical
              ? BorderSide.none
              : const BorderSide(color: Color(0xFF2A3542)),
          left: vertical
              ? const BorderSide(color: Color(0xFF2A3542))
              : BorderSide.none,
        ),
      ),
      child: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  key: const Key('camera-controls'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_stateUnknown)
                      TextButton(
                        onPressed: _reconcileRecording,
                        child: const Text('重试确认'),
                      ),
                    if (_pendingRender != null && !_processing)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: _retryPendingRender,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('重新生成水印版'),
                      ),
                    if (!vertical) _modeSwitch(),
                    const SizedBox(height: 14),
                    if (_statusText != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _statusText!,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (_processing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: LinearProgressIndicator(
                          value: _processingProgress <= 0
                              ? null
                              : _processingProgress,
                          minHeight: 3,
                          color: const Color(0xFFFF9500),
                          backgroundColor: Colors.white12,
                        ),
                      ),
                    if (vertical) ...[
                      _modeSwitch(),
                      const SizedBox(height: 18),
                      _shutter(),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _roundIcon(
                            icon: _torch ? Icons.flash_on : Icons.flash_off,
                            tooltip: _torch ? '关闭手电筒' : '打开手电筒',
                            onTap: (_capturing || _processing || _starting)
                                ? null
                                : _toggleTorch,
                          ),
                          const SizedBox(width: 12),
                          _roundIcon(
                            icon: Icons.cameraswitch_outlined,
                            tooltip: '切换镜头',
                            onTap:
                                (_recording ||
                                    _starting ||
                                    _capturing ||
                                    _processing ||
                                    _stateUnknown)
                                ? null
                                : CameraBridge.switchCamera,
                          ),
                        ],
                      ),
                    ] else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _roundIcon(
                            icon: _torch ? Icons.flash_on : Icons.flash_off,
                            tooltip: _torch ? '关闭手电筒' : '打开手电筒',
                            onTap: (_capturing || _processing || _starting)
                                ? null
                                : _toggleTorch,
                          ),
                          _shutter(),
                          _roundIcon(
                            icon: Icons.cameraswitch_outlined,
                            tooltip: '切换镜头',
                            onTap:
                                (_recording ||
                                    _starting ||
                                    _capturing ||
                                    _processing ||
                                    _stateUnknown)
                                ? null
                                : CameraBridge.switchCamera,
                          ),
                        ],
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

  /// 拍照 / 录像 显式切换，替代原来「点击拍照、长按录像」的双义手势。
  Widget _modeSwitch() {
    Widget item(_CaptureMode mode, String label, IconData icon) {
      final selected = _mode == mode;
      return Expanded(
        child: Semantics(
          button: true,
          label: '$label模式',
          value: selected ? '已选择' : '未选择',
          selected: selected,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap:
                (_recording ||
                    _starting ||
                    _capturing ||
                    _processing ||
                    _stateUnknown)
                ? null
                : () => setState(() => _mode = mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(vertical: 8),
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF2A3542) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: selected ? AppColors.voice : Colors.white54,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected ? Colors.white : Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          item(_CaptureMode.photo, '拍照', Icons.photo_camera_outlined),
          item(_CaptureMode.video, '录像', Icons.videocam_outlined),
        ],
      ),
    );
  }

  Widget _shutter() {
    final video = _mode == _CaptureMode.video;
    final busy = _capturing || _processing || _starting || _stateUnknown;
    final active = video && _recording;
    return Semantics(
      button: true,
      enabled: !busy,
      value: busy ? '处理中' : (active ? '录制中' : '就绪'),
      label: video ? (active ? '停止录像' : '开始录像') : '拍照',
      child: GestureDetector(
        onTap: busy ? null : (video ? _toggleRecording : _takePhoto),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? const Color(0xFFD32029) : Colors.white,
                border: Border.all(color: Colors.white70, width: 4),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Icon(
                video
                    ? (active ? Icons.stop_rounded : Icons.fiber_manual_record)
                    : Icons.camera_alt_rounded,
                color: active ? Colors.white : Colors.black87,
                size: video ? 32 : 30,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              video ? (active ? '点击停止' : '点击开始录像') : '点击拍照',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
