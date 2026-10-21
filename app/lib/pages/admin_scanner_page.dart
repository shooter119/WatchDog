import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../api/api_client.dart';
import '../models/admin_login.dart';
import '../services/screen_on.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

String adminLoginError(Object error) {
  if (error is ApiException) {
    if (error.code == 'ADMIN_CHALLENGE_INVALID') {
      return '二维码已过期、取消或使用，请刷新网页后重新扫描';
    }
    if (error.code == 'ADMIN_FORBIDDEN') return '后台授权已失效，请联系平台管理员';
    if (error.code == 'ADMIN_RATE_LIMITED') return '操作频繁，请稍后重试';
    if (ApiClient.isAuthenticationFailure(error)) return 'App 认证已失效，请重新认证';
  }
  return '确认失败，请检查网络；若已确认，请查看浏览器结果或刷新二维码';
}

class AdminScannerPage extends StatelessWidget {
  final AppController controller;
  final Widget Function(ValueChanged<String>)? scannerBuilder;
  const AdminScannerPage({
    super.key,
    required this.controller,
    this.scannerBuilder,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.canReadKeySites || controller.adminCapability == null) {
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(title: const Text('扫一扫')),
          body: const Center(child: Text('无有效后台授权，请返回后重新认证或联系平台管理员')),
        );
      }
      return _Scanner(
        key: ValueKey((controller.api, controller.protectedDataEpoch)),
        controller: controller,
        scannerBuilder: scannerBuilder,
      );
    },
  );
}

class _Scanner extends StatefulWidget {
  final AppController controller;
  final Widget Function(ValueChanged<String>)? scannerBuilder;
  const _Scanner({super.key, required this.controller, this.scannerBuilder});
  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> with WidgetsBindingObserver {
  late final MobileScannerController? _camera = widget.scannerBuilder != null
      ? null
      : MobileScannerController(
          autoStart: false,
          formats: [BarcodeFormat.qrCode],
          detectionSpeed: DetectionSpeed.noDuplicates,
        );
  AdminLoginCode? _code;
  bool _busy = false, _finished = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_cameraLifecycle(true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_camera == null || !_camera.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed && _code == null && !_busy) {
      unawaited(_cameraLifecycle(true));
    } else if (state != AppLifecycleState.resumed) {
      unawaited(_cameraLifecycle(false));
    }
  }

  Future<void> _cameraLifecycle(bool start) async {
    if (widget.scannerBuilder != null) return;
    try {
      if (start) {
        await _camera?.start();
      } else {
        await _camera?.stop();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '相机启动或停止失败，请返回后重试');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _detect(BarcodeCapture capture) async {
    final values = capture.barcodes.map((b) => b.rawValue ?? '').toList();
    final raw = values.firstWhere(
      (value) => AdminLoginCode.parse(value) != null,
      orElse: () => '',
    );
    await _detectedValue(raw);
  }

  Future<void> _detectedValue(String raw) async {
    if (_busy || _code != null) return;
    final code = AdminLoginCode.parse(raw);
    if (code == null) {
      setState(() => _error = '仅支持本站后台登录二维码，不会打开其它链接');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _cameraLifecycle(false);
    await widget.controller.refreshAdminCapability();
    if (!mounted) return;
    setState(() {
      _code = code;
      _busy = false;
    });
  }

  Future<void> _submit({bool cancel = false}) async {
    final code = _code;
    final api = widget.controller.api;
    final epoch = widget.controller.protectedDataEpoch;
    if (_busy || code == null || api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.refreshAdminCapability();
      if (!mounted ||
          !widget.controller.canReadKeySites ||
          widget.controller.adminCapability == null ||
          api != widget.controller.api ||
          epoch != widget.controller.protectedDataEpoch) {
        return;
      }
      await api.confirmAdminLogin(code, cancel: cancel);
      if (!mounted) return;
      setState(() {
        _finished = true;
        _busy = false;
      });
      if (cancel) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = adminLoginError(error);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.controller.adminCapability!;
    return PopScope(
      canPop: _code == null || _finished,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_busy) unawaited(_submit(cancel: true));
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('扫一扫')),
        body: _finished
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '已确认网页登录\n请回到发起二维码的浏览器继续',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : _code == null
            ? Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '扫描 fireman119.xyz 管理后台登录二维码\n二维码有效期 2 分钟',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Expanded(
                    child:
                        widget.scannerBuilder?.call(
                          (value) => unawaited(_detectedValue(value)),
                        ) ??
                        MobileScanner(
                          controller: _camera,
                          onDetect: _detect,
                          errorBuilder: (context, error) => Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('无法使用相机，请检查相机权限或关闭其它相机页面'),
                                  const SizedBox(height: 12),
                                  OutlinedButton(
                                    onPressed: ScreenOn.openAppSettings,
                                    child: const Text('打开系统设置'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!),
                    ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  const Icon(Icons.desktop_windows_outlined, size: 48),
                  const SizedBox(height: 24),
                  Text(
                    '确认登录网页管理端',
                    style: AppTextStyles.h1.copyWith(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '姓名：${member.name}\n消防单位：${member.unitName}\n后台角色：${member.roleLabel}',
                  ),
                  const SizedBox(height: 24),
                  const Text('仅在本人正在使用的浏览器发起登录时确认。确认后仅发起该二维码的浏览器获得后台会话。'),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_error!),
                    ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('确认登录'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _submit(cancel: true),
                    child: const Text('取消登录'),
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
      ),
    );
  }
}
