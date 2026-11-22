import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/network/network.dart';
import '../../../design_system/design_system.dart';
import '../../../services/screen_on.dart';
import '../data/auth_repository.dart';
import '../data/models/admin_login.dart';
import 'auth_ui_parts.dart';

/// 将后台扫码确认/取消接口错误映射为清晰中文提示。
String adminLoginError(Object error) {
  if (error is ApiException) {
    if (error.code == 'ADMIN_CHALLENGE_INVALID') {
      return '二维码已过期、取消或使用，请刷新网页后重新扫描';
    }
    if (error.code == 'ADMIN_FORBIDDEN') return '后台授权已失效，请联系平台管理员';
    if (error.code == 'ADMIN_RATE_LIMITED') return '操作频繁，请稍后重试';
    if (isApiAuthenticationFailure(error)) return 'App 认证已失效，请重新认证';
  }
  return '确认失败，请检查网络；若已确认，请查看浏览器结果或刷新二维码';
}

/// 后台网页端扫码认证网关（零 `AppController` / `ApiClient` / `SessionStore` 耦合）。
///
/// 确认与取消均通过独立 `POST` 认证接口提交（凭据在请求体而非 URL 中）。
class AdminScannerGateway {
  const AdminScannerGateway({
    required this.accessListenable,
    required this.canReadKeySites,
    required this.readAdminCapability,
    required this.readProtectedDataEpoch,
    required this.refreshAdminCapability,
    required this.confirmAdminLogin,
    this.readClientIdentity,
    this.openAppSettings = ScreenOn.openAppSettings,
  });

  factory AdminScannerGateway.fromRepository({
    required Listenable accessListenable,
    required bool Function() canReadKeySites,
    required AdminCapability? Function() readAdminCapability,
    required int Function() readProtectedDataEpoch,
    required Future<void> Function() refreshAdminCapability,
    required AuthRepository? Function() readRepository,
    Future<void> Function() openAppSettings = ScreenOn.openAppSettings,
  }) => AdminScannerGateway(
    accessListenable: accessListenable,
    canReadKeySites: canReadKeySites,
    readAdminCapability: readAdminCapability,
    readProtectedDataEpoch: readProtectedDataEpoch,
    readClientIdentity: readRepository,
    refreshAdminCapability: refreshAdminCapability,
    openAppSettings: openAppSettings,
    confirmAdminLogin: (AdminLoginCode code, {bool cancel = false}) async {
      final repo = readRepository();
      if (repo == null) {
        throw ApiException(
          'App 认证已失效，请重新认证',
          statusCode: 401,
          code: 'SESSION_INVALID',
        );
      }
      await repo.confirmAdminLogin(code, cancel: cancel);
    },
  );

  final Listenable accessListenable;
  final bool Function() canReadKeySites;
  final AdminCapability? Function() readAdminCapability;
  final int Function() readProtectedDataEpoch;
  final Object? Function()? readClientIdentity;
  final Future<void> Function() refreshAdminCapability;
  final Future<void> Function(AdminLoginCode code, {bool cancel})
  confirmAdminLogin;
  final Future<void> Function() openAppSettings;
}

/// Design System v3.0 网页后台扫码登录页。
///
/// 保留 `MobileScanner` 前后台生命周期暂停/恢复、[ScannerOverlayPainter] 扫码框遮罩，
/// 以及受代际（epoch）与授权撤回保护的独立 `POST` 确认/取消认证流程。
class AdminScannerPage extends StatelessWidget {
  const AdminScannerPage({
    super.key,
    required this.gateway,
    this.scannerBuilder,
  });

  final AdminScannerGateway gateway;
  final Widget Function(ValueChanged<String> onDetected)? scannerBuilder;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: gateway.accessListenable,
      builder: (BuildContext context, _) {
        if (!gateway.canReadKeySites() ||
            gateway.readAdminCapability() == null) {
          return CommandScaffold(
            appBar: AppBar(title: const Text('扫一扫')),
            body: const StatePlaceholder.empty(
              icon: DsIcons.qrScan,
              message: '无有效后台授权',
              detail: '请返回后重新认证或联系平台管理员',
            ),
          );
        }
        return _AdminScannerSession(
          key: ValueKey<Object>((
            gateway.readClientIdentity?.call(),
            gateway.readProtectedDataEpoch(),
          )),
          gateway: gateway,
          scannerBuilder: scannerBuilder,
        );
      },
    );
  }
}

class _AdminScannerSession extends StatefulWidget {
  const _AdminScannerSession({
    super.key,
    required this.gateway,
    this.scannerBuilder,
  });

  final AdminScannerGateway gateway;
  final Widget Function(ValueChanged<String> onDetected)? scannerBuilder;

  @override
  State<_AdminScannerSession> createState() => _AdminScannerSessionState();
}

class _AdminScannerSessionState extends State<_AdminScannerSession>
    with WidgetsBindingObserver {
  late final MobileScannerController? _camera = widget.scannerBuilder != null
      ? null
      : MobileScannerController(
          autoStart: false,
          formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
          detectionSpeed: DetectionSpeed.noDuplicates,
        );

  AdminLoginCode? _code;
  bool _busy = false;
  bool _finished = false;
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
    final raw = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere(
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
    await widget.gateway.refreshAdminCapability();
    if (!mounted) return;
    setState(() {
      _code = code;
      _busy = false;
    });
  }

  Future<void> _submit({bool cancel = false}) async {
    final code = _code;
    final identity = widget.gateway.readClientIdentity?.call();
    final epoch = widget.gateway.readProtectedDataEpoch();
    if (_busy || code == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.gateway.refreshAdminCapability();
      if (!mounted ||
          !widget.gateway.canReadKeySites() ||
          widget.gateway.readAdminCapability() == null ||
          identity != widget.gateway.readClientIdentity?.call() ||
          epoch != widget.gateway.readProtectedDataEpoch()) {
        return;
      }
      await widget.gateway.confirmAdminLogin(code, cancel: cancel);
      if (!mounted) return;
      setState(() {
        _finished = true;
        _busy = false;
      });
      if (cancel) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = adminLoginError(error);
          _busy = false;
        });
      }
    }
  }

  Widget _buildScanView(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(DsSpacing.pageMargin),
          child: SurfaceCard(
            level: DsSurfaceLevel.flat,
            borderColor: colors.border,
            padding: const EdgeInsets.all(DsSpacing.md),
            child: Text(
              '在电脑打开管理后台\nhttps://fireman119.xyz/admin/\n扫描登录二维码，有效期 2 分钟',
              textAlign: TextAlign.center,
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              widget.scannerBuilder?.call(
                    (value) => unawaited(_detectedValue(value)),
                  ) ??
                  MobileScanner(
                    controller: _camera,
                    onDetect: _detect,
                    errorBuilder: (_, _) => StatePlaceholder.error(
                      icon: DsIcons.videoOff,
                      title: '无法使用相机',
                      reason: '请检查相机权限或关闭其它相机页面',
                      retryLabel: '打开系统设置',
                      onRetry: () => unawaited(widget.gateway.openAppSettings()),
                    ),
                  ),
              const IgnorePointer(
                child: CustomPaint(painter: ScannerOverlayPainter()),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(DsSpacing.pageMargin),
            child: AuthNoticeBanner(
              key: const Key('admin-scanner-error'),
              message: _error!,
            ),
          ),
      ],
    );
  }

  Widget _buildConfirmView(BuildContext context, AdminCapability member) {
    final ds = context.ds;
    final colors = ds.colors;
    Widget line(String k, String v) => Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: k,
            style: ds.typography.caption.copyWith(color: colors.textTertiary),
          ),
          TextSpan(
            text: v,
            style: ds.typography.body.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.lg,
        DsSpacing.pageMargin,
        DsSpacing.xxl,
      ),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const AuthHeaderBadgeRow(
                  icon: DsIcons.computer,
                  pillLabel: '本站管理端认证',
                  pillIcon: DsIcons.verified,
                  pillStatus: DsStatus.safe,
                ),
                const SizedBox(height: DsSpacing.lg),
                Text(
                  '确认登录网页管理端',
                  style: ds.typography.display.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
                SurfaceCard(
                  level: DsSurfaceLevel.outlined,
                  padding: const EdgeInsets.all(DsSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      line('姓名：', member.name),
                      const SizedBox(height: DsSpacing.sm),
                      line('消防单位：', member.unitName),
                      const SizedBox(height: DsSpacing.sm),
                      line('后台角色：', member.roleLabel),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.md),
                SurfaceCard(
                  level: DsSurfaceLevel.flat,
                  borderColor: colors.border,
                  padding: const EdgeInsets.all(DsSpacing.md),
                  child: Text(
                    '仅在本人正在使用的浏览器发起登录时确认。确认后仅发起该二维码的浏览器获得后台会话。',
                    style: ds.typography.caption.copyWith(
                      color: colors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: DsSpacing.md),
                  AuthNoticeBanner(
                    key: const Key('admin-scanner-error'),
                    message: _error!,
                  ),
                ],
                const SizedBox(height: DsSpacing.xl),
                CommandButton(
                  key: const Key('admin-confirm-login'),
                  label: '确认登录',
                  icon: DsIcons.checkCircle,
                  variant: CommandButtonVariant.primary,
                  size: CommandButtonSize.large,
                  expanded: true,
                  isLoading: _busy,
                  enabled: !_busy,
                  onPressed: () => unawaited(_submit()),
                ),
                const SizedBox(height: DsSpacing.md),
                CommandButton(
                  key: const Key('admin-cancel-login'),
                  label: '取消登录',
                  icon: DsIcons.close,
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.large,
                  expanded: true,
                  enabled: !_busy,
                  onPressed: () => unawaited(_submit(cancel: true)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.gateway.readAdminCapability()!;
    return PopScope(
      canPop: _code == null || _finished,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && !_busy) unawaited(_submit(cancel: true));
      },
      child: CommandScaffold(
        appBar: AppBar(title: const Text('扫一扫')),
        body: _finished
            ? const StatePlaceholder.empty(
                icon: DsIcons.checkCircle,
                message: '已确认网页登录',
                detail: '请回到发起二维码的浏览器继续',
              )
            : _code == null
            ? _buildScanView(context)
            : _buildConfirmView(context, member),
      ),
    );
  }
}

/// 扫码页居中正方形取景框与四角高亮线绘制器。
class ScannerOverlayPainter extends CustomPainter {
  const ScannerOverlayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final s = math.min(size.width, size.height) * 0.68;
    final r = Rect.fromLTWH((size.width - s) / 2, (size.height - s) / 2, s, s);
    canvas.drawPath(
      Path()
        ..addRect(Offset.zero & size)
        ..addRect(r)
        ..fillType = PathFillType.evenOdd,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.52)
        ..style = PaintingStyle.fill,
    );
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final c = math.min(28.0, s * 0.16);
    void corner(double x1, double y1, double x2, double y2, double x3, double y3) {
      canvas.drawPath(Path()..moveTo(x1, y1)..lineTo(x2, y2)..lineTo(x3, y3), p);
    }
    corner(r.left, r.top + c, r.left, r.top, r.left + c, r.top);
    corner(r.right - c, r.top, r.right, r.top, r.right, r.top + c);
    corner(r.left, r.bottom - c, r.left, r.bottom, r.left + c, r.bottom);
    corner(r.right - c, r.bottom, r.right, r.bottom, r.right, r.bottom - c);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
