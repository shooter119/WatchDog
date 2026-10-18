import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
enum _CaptureMode { photo, video }

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
  CameraPermissionState _permissions = CameraPermissionState.denied;
  LocationFix? _fix;
  bool _permissionDenied = false;
  bool _ready = false;
  bool _locating = false;
  bool _recording = false;
  bool _starting = false;
  bool _capturing = false;
  bool _torch = false;
  _CaptureMode _mode = _CaptureMode.photo;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  String? _statusText;

  @override
  void initState() {
    super.initState();
    // 现场拍小视频习惯横握手机，固定横屏可以避免成片方向来回翻转，
    // 也能保证水印版式在成片里始终是横向的。
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    WidgetsBinding.instance.addObserver(this);
    _subscription = CameraBridge.events.listen(_onRecordEvent);
    _bootstrap();
  }

  @override
  void dispose() {
    // 离开相机页恢复为不限制方向，避免影响 App 其余页面
    unawaited(SystemChrome.setPreferredOrientations(const []));
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台/锁屏时主动结束录制：原生侧 Finalize 仍会落盘，
    // 我们的订阅在后台可能收不到事件，由恢复时的补登记兜底。
    if (state != AppLifecycleState.resumed && _recording) {
      CameraBridge.stopRecording();
    }
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

  Future<void> _resolveLocation() async {
    if (!_permissions.location) return;
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
      );
    });
    await CameraBridge.updateWatermark(_watermark);
  }

  /// 拍摄前刷新水印快照：这是「照片上的时间」与「入库时间」一致的唯一保证。
  Future<WatermarkPayload> _snapshotWatermark() async {
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
          _starting = false;
          _statusText = event.autoStopped ? '已录满 60 秒，自动保存' : '视频已保存到本机';
        });
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
          _starting = false;
          _statusText = event.message ?? '录制失败';
        });
        break;
    }
  }

  Future<void> _takePhoto() async {
    if (_capturing || _recording || _starting) return;
    setState(() => _capturing = true);
    try {
      final snapshot = await _snapshotWatermark();
      final path = await CameraBridge.takePhoto();
      if (!mounted) return;
      if (path == null) {
        setState(() => _statusText = '拍照失败，请重试');
        return;
      }
      final media = await MediaCaptureService.registerPhoto(
        incidentId: widget.controller.currentIncident?.id ?? '',
        path: path,
        watermark: snapshot,
        fix: _fix,
      );
      if (!mounted) return;
      setState(() => _statusText = '照片已保存');
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              MediaReviewPage(controller: widget.controller, media: media),
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _statusText = error.message ?? '拍照失败');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _toggleRecording() async {
    if (_starting) return;
    if (_recording) {
      await CameraBridge.stopRecording();
      return;
    }
    setState(() {
      _starting = true;
      _statusText = null;
    });
    try {
      await _snapshotWatermark();
      await CameraBridge.startRecording();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _statusText = error.message ?? '无法开始录制';
      });
    }
  }

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

  Future<void> _handleClose(BuildContext context) async {
    final navigator = Navigator.of(context);
    if (await _confirmLeave()) {
      if (mounted) navigator.maybePop();
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
    if (!_recording && !_starting) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('正在录像'),
        content: const Text('退出会结束并保存这段视频。确定退出吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续录制')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('结束并退出')),
        ],
      ),
    );
    if (leave != true) return false;
    await CameraBridge.stopRecording();
    // 等待 stopped 事件完成入库，最多 3 秒
    for (var i = 0; i < 30 && _recording; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
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

    final landscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 路由已在退场流程中，直接用外层 context 的 Navigator 实例
        await _handleClose(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: landscape
            ? Row(
                children: [
                  Expanded(child: _preview(creationParams)),
                  SizedBox(width: 180, child: _bottomBar(vertical: true)),
                ],
              )
            : Column(
                children: [
                // 取景区与控制区分开：水印固定在画面左下角，
                // 若控件浮在画面上就会压住水印，现场核对时反而看不清。
                Expanded(child: _preview(creationParams)),
                _bottomBar(),
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
                    onPressed: _recording ? null : _openGallery,
                    icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
                  ),
                  const SizedBox(width: 4),
                  _permissionBadges(),
                ],
              ),
            ),
            if (unlinked)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xE6B26B00),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '未关联警情：拍摄的文件只在本机，加入警情后才能写入记录',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            if (_recording)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xCCD32029),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fiber_manual_record, size: 12, color: Colors.white),
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

  /// 麦克风/定位被拒时给出可见状态，避免「录了没声音、地址是空的」却毫无解释。
  Widget _permissionBadges() {
    final badges = <Widget>[];
    if (!_permissions.microphone) {
      badges.add(_badge('麦克风未授权', Icons.mic_off_rounded, () => _requestAgain()));
    }
    if (!_permissions.location) {
      badges.add(_badge('定位未授权', Icons.location_off_rounded, () => _requestAgain()));
    } else if (!_permissions.preciseLocation) {
      badges.add(_badge('粗略定位', Icons.location_searching_rounded, null));
    } else if (_locating) {
      badges.add(_badge('定位中', Icons.location_searching_rounded, null));
    }
    if (badges.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: badges);
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
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
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
    if (state.location && _fix == null) await _resolveLocation();
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
          top: vertical ? BorderSide.none : const BorderSide(color: Color(0xFF2A3542)),
          left: vertical ? const BorderSide(color: Color(0xFF2A3542)) : BorderSide.none,
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: vertical
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            if (!vertical) _modeSwitch(),
              const SizedBox(height: 14),
              if (_statusText != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _statusText!,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
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
                      tooltip: '手电筒',
                      onTap: () {
                        setState(() => _torch = !_torch);
                        CameraBridge.setTorch(_torch);
                      },
                    ),
                    const SizedBox(width: 12),
                    _roundIcon(
                      icon: Icons.cameraswitch_outlined,
                      tooltip: '切换镜头',
                      onTap: (_recording || _starting)
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
                      tooltip: '手电筒',
                      onTap: () {
                        setState(() => _torch = !_torch);
                        CameraBridge.setTorch(_torch);
                      },
                    ),
                    _shutter(),
                    _roundIcon(
                      icon: Icons.cameraswitch_outlined,
                      tooltip: '切换镜头',
                      onTap: (_recording || _starting)
                          ? null
                          : CameraBridge.switchCamera,
                    ),
                  ],
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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: (_recording || _starting)
              ? null
              : () => setState(() => _mode = mode),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 40,
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF2A3542) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
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
    final busy = _capturing || _starting;
    final active = video && _recording;
    return Semantics(
      button: true,
      label: video ? (active ? '停止录像' : '开始录像') : '拍照',
      child: GestureDetector(
        onTap: busy
            ? null
            : (video ? _toggleRecording : _takePhoto),
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
                  BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 3)),
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
