import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../design_system/design_system.dart';
import '../../../services/camera_bridge.dart';
import '../../../services/local_media_store.dart';
import '../../../services/watermark_settings.dart';
import '../state/camera_session_store.dart';
import '../state/media_gateway.dart';
import 'camera_overlay_controls.dart';
import 'camera_permission_view.dart';
import 'media_gallery_page.dart';
import 'media_review_page.dart';

/// 水印相机页（Design System v3.0 重构版）。
///
/// 保持原生 `watchdog/camera_view` 视图、横竖屏 16:9 锁定、拍摄前水印与定位快照、
/// 母版失败保留重试、录像前后台保护及离开确认等全套现场约束。
class CameraPage extends StatefulWidget {
  const CameraPage({
    super.key,
    required this.gateway,
    this.onOpenWatermarkSettings,
    this.onOpenGallery,
    this.onOpenReview,
  });

  final MediaGateway gateway;
  final Future<void> Function(BuildContext context)? onOpenWatermarkSettings;
  final Future<void> Function(BuildContext context)? onOpenGallery;
  final Future<MediaReviewOutcome?> Function(
    BuildContext context,
    LocalMedia media, {
    required bool deriving,
  })?
  onOpenReview;

  @override
  State<CameraPage> createState() => CameraPageState();
}

class CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  late final CameraSessionStore _store;
  bool _leaving = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = CameraSessionStore(
      gateway: widget.gateway,
      onAnnounce: _announce,
      onOpenReview: _openReview,
    )..addListener(_onStoreChanged);
    unawaited(_store.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store
      ..removeListener(_onStoreChanged)
      ..dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _store.handleAppLifecycleState(state);
  }

  void _announce(String message) {
    if (!mounted) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  Future<MediaReviewOutcome?> _openReview(
    LocalMedia media, {
    required bool deriving,
  }) async {
    if (!mounted) return null;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final custom = widget.onOpenReview;
    final MediaReviewOutcome? outcome;
    if (custom != null) {
      outcome = await custom(context, media, deriving: deriving);
    } else {
      outcome = await navigator.push<MediaReviewOutcome>(
        MaterialPageRoute<MediaReviewOutcome>(
          builder: (_) => MediaReviewPage(
            gateway: widget.gateway,
            media: media,
            deriving: deriving,
          ),
        ),
      );
    }
    if (outcome != null && mounted) {
      messenger.hideCurrentSnackBar();
    }
    return outcome;
  }

  Future<void> _openGallery() async {
    final custom = widget.onOpenGallery;
    if (custom != null) {
      await custom(context);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaGalleryPage(gateway: widget.gateway),
      ),
    );
  }

  Future<void> _openWatermarkSettings() async {
    final opener = widget.onOpenWatermarkSettings;
    if (opener == null) return;
    await opener(context);
    if (!mounted) return;
    await _store.reloadWatermarkSettings();
  }

  Future<bool> _confirmPendingBeforeNewCapture() async {
    final pending = _store.pendingRender;
    if (pending == null) return true;
    final choice = await showCommandSheet<PendingRenderChoice>(
      context: context,
      title: pending.video ? '上段视频尚未生成水印版' : '上张照片尚未生成水印版',
      builder: (sheetContext) {
        final ds = sheetContext.ds;
        return Text(
          '原始母版仍保留在本机。可先重试生成，或放弃后重新拍摄。',
          style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
        );
      },
      actionsBuilder: (sheetContext) => [
        CommandButton(
          label: '放弃母版',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () =>
              Navigator.of(sheetContext).pop(PendingRenderChoice.discard),
        ),
        CommandButton(
          label: '重试生成',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () =>
              Navigator.of(sheetContext).pop(PendingRenderChoice.retry),
        ),
      ],
    );
    if (!mounted) return false;
    switch (choice) {
      case PendingRenderChoice.retry:
        await _store.retryPendingRender();
        return false;
      case PendingRenderChoice.discard:
        await _store.discardPendingRender();
        return true;
      case null:
        return false;
    }
  }

  Future<void> _handleShutterTap() async {
    if (_store.mode == CameraCaptureMode.video) {
      if (_store.recording) {
        await _store.toggleRecording();
        return;
      }
      if (!await _confirmPendingBeforeNewCapture()) return;
      await _store.toggleRecording();
      return;
    }
    if (!await _confirmPendingBeforeNewCapture()) return;
    await _store.takePhoto();
  }

  Future<void> _handleClose(BuildContext context) async {
    if (_closing || _leaving) return;
    _closing = true;
    final navigator = Navigator.of(context);
    try {
      if (!await _confirmLeave()) return;
      if (!mounted) return;
      setState(() => _leaving = true);
      navigator.pop();
    } finally {
      if (!_leaving) _closing = false;
    }
  }

  Future<bool> _confirmLeave() async {
    if (_store.processing) {
      _store.setStatusText('正在生成水印版，请稍候');
      return false;
    }
    if (_store.capturing) {
      _store.setStatusText('正在保存照片，请稍候');
      return false;
    }
    if (_store.stateUnknown) {
      await _store.reconcileRecording();
      return false;
    }
    if (_store.pendingRender != null) {
      final choice = await showCommandSheet<PendingRenderChoice>(
        context: context,
        title: '水印成片尚未生成',
        builder: (sheetContext) {
          final ds = sheetContext.ds;
          return Text(
            '当前原始母版仍保留在本机。继续生成会返回处理流程，退出并删除会放弃这份母版。',
            style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
          );
        },
        actionsBuilder: (sheetContext) => [
          CommandButton(
            label: '退出并删除',
            variant: CommandButtonVariant.danger,
            size: CommandButtonSize.large,
            requireConfirmation: false,
            onPressed: () =>
                Navigator.of(sheetContext).pop(PendingRenderChoice.discard),
          ),
          CommandButton(
            label: '继续生成',
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            onPressed: () =>
                Navigator.of(sheetContext).pop(PendingRenderChoice.retry),
          ),
        ],
      );
      if (!mounted) return false;
      switch (choice) {
        case PendingRenderChoice.retry:
          await _store.retryPendingRender();
          return false;
        case PendingRenderChoice.discard:
          await _store.discardPendingRender();
          return true;
        case null:
          return false;
      }
    }
    if (!mounted) return false;
    if (!_store.recording && !_store.starting) return true;
    final leave = await showCommandSheet<bool>(
      context: context,
      title: '正在录像',
      builder: (sheetContext) {
        final ds = sheetContext.ds;
        return Text(
          '退出会结束并保存这段视频。确定退出吗？',
          style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
        );
      },
      actionsBuilder: (sheetContext) => [
        CommandButton(
          label: '继续录制',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          label: '结束并退出',
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    );
    if (leave != true) return false;
    return _store.stopRecordingAndAwaitFinish();
  }

  Widget _buildTopBar() {
    return CameraTopBar(
      store: _store,
      onOpenGallery: _openGallery,
      onClose: () => _handleClose(context),
      onRequestPermissionsAgain: _store.requestOptionalPermissionsAgain,
      onOpenWatermarkSettings: widget.onOpenWatermarkSettings != null
          ? _openWatermarkSettings
          : null,
    );
  }

  Widget _buildPreview({bool withTopBar = true}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AndroidView(
          viewType: CameraBridge.viewType,
          creationParams: _store.creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        ),
        if (withTopBar) Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
      ],
    );
  }

  Widget _buildControls({required bool vertical}) {
    return CameraControlDeck(
      store: _store,
      vertical: vertical,
      onShutterTap: _handleShutterTap,
      onToggleTorch: _store.toggleTorch,
      onSwitchCamera: CameraBridge.switchCamera,
      onRetryPendingRender: _store.retryPendingRender,
      onReconcileRecording: _store.reconcileRecording,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!CameraBridge.isSupported) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            '当前平台暂不支持水印相机',
            style: context.ds.typography.body.copyWith(color: Colors.white),
          ),
        ),
      );
    }
    if (_store.permissionDenied) {
      return CameraPermissionView(
        onClose: () => Navigator.of(context).maybePop(),
        onOpenSettings: CameraBridge.openSystemSettings,
        onRequestAgain: _store.requestPermissionsFromDenied,
      );
    }
    if (!_store.ready) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: DsSpacing.md),
              Text(
                '正在准备相机…',
                style: context.ds.typography.body.copyWith(
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isLandscape =
        _store.captureOrientation == CameraCaptureOrientation.landscape;
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleClose(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: isLandscape
            ? Row(
                key: const Key('camera-landscape-layout'),
                children: [
                  Expanded(child: _buildPreview()),
                  SizedBox(width: 220, child: _buildControls(vertical: true)),
                ],
              )
            : Column(
                key: const Key('camera-portrait-layout'),
                children: [
                  _buildTopBar(),
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        key: const Key('camera-portrait-preview'),
                        aspectRatio: 16 / 9,
                        child: _buildPreview(withTopBar: false),
                      ),
                    ),
                  ),
                  SizedBox(
                    key: const Key('camera-portrait-controls-area'),
                    height: 280,
                    child: _buildControls(vertical: false),
                  ),
                ],
              ),
      ),
    );
  }
}
