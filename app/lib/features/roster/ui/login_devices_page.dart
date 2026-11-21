import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 已登录设备视图模型（隔离 `features/auth/` 跨 Feature 依赖）。
@immutable
class LoginDeviceView {
  const LoginDeviceView({
    required this.id,
    required this.name,
    required this.platform,
    required this.current,
    this.lastSeenAt,
  });

  final String id;
  final String name;
  final String platform;
  final bool current;
  final dynamic lastSeenAt;

  factory LoginDeviceView.fromMap(Map<String, dynamic> map) => LoginDeviceView(
    id: map['id']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    platform: map['platform']?.toString() ?? '',
    current: map['current'] == true,
    lastSeenAt: map['last_seen_at'],
  );
}

/// 登录设备管理页的数据与会话授权网关。
abstract class LoginDevicesGateway {
  Listenable? get changes => null;

  bool get isAuthorized;

  Future<List<LoginDeviceView>> fetchDevices();
  Future<void> revokeDevice(String? deviceId);
}

/// 多端登录设备管理页（Design System v3.0）。
///
/// 展示本机徽标与多设备列表，支持通过 [CommandSheet] 二次确认强制下线单台或全部其他设备，
/// 并在登录失效时立即隐藏全部设备数据。
class LoginDevicesPage extends StatefulWidget {
  const LoginDevicesPage({
    super.key,
    required this.gateway,
    this.isOffline = false,
  });

  final LoginDevicesGateway gateway;
  final bool isOffline;

  @override
  State<LoginDevicesPage> createState() => _LoginDevicesPageState();
}

class _LoginDevicesPageState extends State<LoginDevicesPage> {
  List<LoginDeviceView> _devices = const <LoginDeviceView>[];
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    widget.gateway.changes?.addListener(_onChanged);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LoginDevicesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway) {
      oldWidget.gateway.changes?.removeListener(_onChanged);
      widget.gateway.changes?.addListener(_onChanged);
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    widget.gateway.changes?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final devices = await widget.gateway.fetchDevices();
      if (mounted && widget.gateway.isAuthorized) {
        setState(() {
          _devices = devices;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(String? id) async {
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: id == null ? '退出其他全部设备？' : '退出这台设备？',
      builder: (BuildContext sheetContext) => Text(
        '目标设备的同步和语音连接会中断，需要重新登录。本机继续在线；目标设备未上传的记录会保留在当地。',
        style: sheetContext.ds.typography.body.copyWith(
          color: sheetContext.ds.colors.textSecondary,
        ),
      ),
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          label: '确认退出',
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    );
    if (confirmed != true || !widget.gateway.isAuthorized || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.gateway.revokeDevice(id);
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final authorized = widget.gateway.isAuthorized;
    final hasOtherDevices = _devices.any((device) => !device.current);

    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(title: const Text('登录设备')),
      body: !authorized
          ? const StatePlaceholder.empty(
              icon: Icons.devices_other_outlined,
              message: '登录已失效，请返回重新认证',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                DsSpacing.pageMargin,
                DsSpacing.md,
                DsSpacing.pageMargin,
                DsSpacing.xxl,
              ),
              children: <Widget>[
                Text(
                  '新设备登录不会使其他设备下线。最近活动时间不代表设备此刻在线。',
                  style: typo.caption.copyWith(
                    color: colors.textTertiary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: DsSpacing.md),
                if (_error != null) ...<Widget>[
                  SurfaceCard(
                    accentStatus: DsStatus.alarm,
                    backgroundColor: colors.statusColors(DsStatus.alarm).pillBg,
                    padding: const EdgeInsets.all(DsSpacing.md),
                    child: Text(
                      _error!,
                      style: typo.body.copyWith(
                        color: colors.statusColors(DsStatus.alarm).text,
                      ),
                    ),
                  ),
                  const SizedBox(height: DsSpacing.md),
                ],
                if (_busy) ...<Widget>[
                  LinearProgressIndicator(
                    color: colors.brand,
                    backgroundColor: colors.surfaceMuted,
                  ),
                  const SizedBox(height: DsSpacing.md),
                ],
                for (final device in _devices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: DsSpacing.cardGap),
                    child: _LoginDeviceCard(
                      device: device,
                      busy: _busy,
                      onRevoke: () => _revoke(device.id),
                    ),
                  ),
                const SizedBox(height: DsSpacing.sm),
                CommandButton(
                  label: '退出其他全部设备',
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.standard,
                  expanded: true,
                  enabled: !_busy && hasOtherDevices,
                  onPressed: () => _revoke(null),
                ),
                const SizedBox(height: DsSpacing.sm),
                CommandButton(
                  label: '刷新',
                  variant: CommandButtonVariant.ghost,
                  size: CommandButtonSize.standard,
                  expanded: true,
                  enabled: !_busy,
                  onPressed: _load,
                ),
              ],
            ),
    );
  }
}

class _LoginDeviceCard extends StatelessWidget {
  const _LoginDeviceCard({
    required this.device,
    required this.busy,
    required this.onRevoke,
  });

  final LoginDeviceView device;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${device.name} · ${device.platform}',
            style: typo.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            '最近活动：${_formatDeviceTimestamp(device.lastSeenAt)}',
            style: typo.captionTabular.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: DsSpacing.md),
          if (device.current)
            const StatusPill(
              status: DsStatus.safe,
              icon: Icons.check_circle_outline_rounded,
              label: '当前设备',
            )
          else
            CommandButton(
              label: '退出该设备',
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              enabled: !busy,
              onPressed: onRevoke,
            ),
        ],
      ),
    );
  }
}

String _formatDeviceTimestamp(dynamic raw) {
  if (raw == null) return '--';
  DateTime? d;
  if (raw is num) {
    d = DateTime.fromMillisecondsSinceEpoch(raw.toInt()).toLocal();
  } else if (raw is String) {
    final asNum = num.tryParse(raw);
    if (asNum != null) {
      d = DateTime.fromMillisecondsSinceEpoch(asNum.toInt()).toLocal();
    } else {
      d = DateTime.tryParse(raw)?.toLocal();
    }
  } else if (raw is DateTime) {
    d = raw.toLocal();
  }
  if (d == null) return raw.toString();
  String pad(int v) => v.toString().padLeft(2, '0');
  return '${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)}';
}
