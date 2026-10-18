import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/camera_bridge.dart';
import '../services/media_capture_service.dart';
import '../services/settings.dart';
import '../services/watermark_settings.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'media_gallery_page.dart';
import 'media_review_page.dart';

/// 水印相机页。
///
/// 设计约束（产品已确认）：
/// - 水印由原生层烧进画面，照片与视频都保留水印，不依赖二次转码
/// - 水印字段：单位、警情、地址、天气、拍摄人、时间（秒）
/// - 单段视频最长 60 秒，到点自动停止
/// - 文件只保存在本机，是否分享由用户逐次决定
class CameraPage extends StatefulWidget {
  final AppController controller;

  const CameraPage({super.key, required this.controller});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  StreamSubscription<CameraRecordEvent>? _subscription;

  WatermarkPayload _watermark = const WatermarkPayload();
  LocationFix? _fix;
  bool _locating = true;
  bool _recording = false;
  bool _capturing = false;
  bool _torch = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  String? _statusText;
  bool _permissionsReady = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = CameraBridge.events.listen(_onRecordEvent);
    _ensurePermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台时结束录制，避免无声继续录导致文件损坏或超长
    if (state != AppLifecycleState.resumed && _recording) {
      CameraBridge.stopRecording();
    }
  }

  /// 相机与麦克风必须运行时申请：应用之前只用系统相机拍照，
  /// 清单里的 CAMERA 权限从未真正被使用过。
  Future<void> _ensurePermissions() async {
    final granted = await CameraBridge.requestPermissions();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _permissionDenied = true;
        _permissionsReady = false;
      });
      return;
    }
    setState(() {
      _permissionsReady = true;
      _permissionDenied = false;
    });
    await _bootstrapWatermark();
  }

  Future<void> _bootstrapWatermark() async {
    // 水印参数来自独立的「水印设置」，与登录身份解耦；
    // 只有未单独配置时才回落到单位名称与实名。
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
    await _resolveLocation();
  }

  Future<void> _resolveLocation() async {
    setState(() => _locating = true);
    final fix = await CameraBridge.currentLocation();
    if (!mounted) return;

    WeatherInfo weather = WeatherInfo.empty;
    final api = widget.controller.api;
    if (fix != null && api != null) {
      weather = await api.fetchWeather(lat: fix.lat, lon: fix.lon);
    }
    if (!mounted) return;

    setState(() {
      _fix = fix;
      _locating = false;
      _watermark = _watermark.copyWith(
        address: weather.address?.isNotEmpty == true ? weather.address! : '',
        weather: weather.line ?? '',
        latitude: fix?.lat,
        longitude: fix?.lon,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    });
    await CameraBridge.updateWatermark(_watermark);
  }

  void _onRecordEvent(CameraRecordEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'started':
        setState(() {
          _recording = true;
          _elapsed = Duration.zero;
          _statusText = null;
        });
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (!mounted) return;
          setState(() => _elapsed += const Duration(milliseconds: 200));
        });
        break;
      case 'stopped':
        _ticker?.cancel();
        setState(() {
          _recording = false;
          _statusText = event.autoStopped ? '已录制满 60 秒，自动保存' : '视频已保存到本机';
        });
        _afterCapture();
        final path = event.path;
        if (path != null) _openReviewForVideo(path, event.durationMs ?? 0);
        break;
      case 'reached_limit':
        setState(() => _statusText = '已达 60 秒上限，正在保存…');
        break;
      case 'error':
        _ticker?.cancel();
        setState(() {
          _recording = false;
          _statusText = event.message ?? '录制失败';
        });
        break;
    }
  }

  void _afterCapture() {
    // 拍摄结束后刷新时间戳，保证下一次拍摄的水印时间是当前时刻
    setState(() {
      _watermark = _watermark.copyWith(
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    });
    CameraBridge.updateWatermark(_watermark);
  }

  /// 录像结束后先入库，再进入核对页；识别与抽帧在核对页里带进度完成。
  Future<void> _openReviewForVideo(String path, int durationMs) async {
    final media = await MediaCaptureService.registerVideo(
      incidentId: widget.controller.currentIncident?.id ?? '',
      path: path,
      durationMs: durationMs,
      watermark: _watermark,
      fix: _fix,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaReviewPage(
          controller: widget.controller,
          media: media,
          deriving: true,
        ),
      ),
    );
  }

  Future<void> _openGallery() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaGalleryPage(controller: widget.controller),
      ),
    );
  }

  Future<void> _takePhoto() async {
    if (_capturing || _recording) return;
    setState(() => _capturing = true);
    try {
      final path = await CameraBridge.takePhoto();
      if (!mounted) return;
      setState(() => _statusText = path == null ? '拍照失败' : '照片已保存到本机');
      _afterCapture();
      if (path != null) {
        final media = await MediaCaptureService.registerPhoto(
          incidentId: widget.controller.currentIncident?.id ?? '',
          path: path,
          watermark: _watermark,
          fix: _fix,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                MediaReviewPage(controller: widget.controller, media: media),
          ),
        );
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _statusText = error.message ?? '拍照失败');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await CameraBridge.stopRecording();
      return;
    }
    setState(() => _statusText = null);
    try {
      await CameraBridge.startRecording();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _statusText = error.message ?? '无法开始录制');
    }
  }

  String get _timerText {
    final total = _elapsed.inSeconds;
    final remain = CameraBridge.maxRecordingDuration.inSeconds - total;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s  剩 ${remain < 0 ? 0 : remain}s';
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
    if (!_permissionsReady) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
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
    };

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AndroidView(
            viewType: CameraBridge.viewType,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
          ),
          _topBar(),
          _bottomBar(),
        ],
      ),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48, color: Colors.white54),
              const SizedBox(height: 16),
              const Text(
                '需要相机权限才能拍摄现场资料',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '拍摄内容只保存在本机，不会自动上传',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: _ensurePermissions,
                child: const Text('重新授权'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
                tooltip: '关闭',
              ),
              const Spacer(),
              IconButton(
                tooltip: '现场资料',
                onPressed: _recording ? null : _openGallery,
                icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
              ),
              if (_recording)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.alarm,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fiber_manual_record,
                          size: 12, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(
                        _timerText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                )
              else
                ActionChip(
                  avatar: Icon(
                    _locating ? Icons.location_searching : Icons.location_on,
                    size: 16,
                    color: Colors.white,
                  ),
                  label: Text(
                    _locating
                        ? '定位中…'
                        : (_fix == null ? '无定位' : '已定位'),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  backgroundColor: Colors.black45,
                  side: BorderSide.none,
                  onPressed: _locating ? null : _resolveLocation,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_statusText != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    _statusText!,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _circleAction(
                    icon: _torch ? Icons.flash_on : Icons.flash_off,
                    onTap: () {
                      setState(() => _torch = !_torch);
                      CameraBridge.setTorch(_torch);
                    },
                  ),
                  _shutter(),
                  _circleAction(
                    icon: Icons.cameraswitch_outlined,
                    onTap: _recording ? null : CameraBridge.switchCamera,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单一主按钮：短按拍照，长按/点击右侧切换为录像状态。
  Widget _shutter() {
    return GestureDetector(
      onTap: _capturing ? null : _takePhoto,
      onLongPress: _toggleRecording,
      onLongPressEnd: (_) {
        if (_recording) _toggleRecording();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _recording ? AppColors.alarm : Colors.white,
              border: Border.all(color: Colors.white70, width: 4),
            ),
            child: Icon(
              _recording ? Icons.stop_rounded : Icons.camera_alt_rounded,
              color: _recording ? Colors.white : Colors.black87,
              size: 30,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _recording ? '长按结束' : '点击拍照 · 长按录像',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _circleAction({required IconData icon, VoidCallback? onTap}) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: Colors.white, size: 26),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black38,
        padding: const EdgeInsets.all(12),
      ),
    );
  }
}
