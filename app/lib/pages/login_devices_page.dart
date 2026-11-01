import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_controller.dart';
import '../theme/app_dialogs.dart';
import '../theme/app_widgets.dart';

class LoginDevicesPage extends StatefulWidget {
  final AppController controller;
  const LoginDevicesPage({super.key, required this.controller});
  @override
  State<LoginDevicesPage> createState() => _LoginDevicesPageState();
}

class _LoginDevicesPageState extends State<LoginDevicesPage> {
  late final ApiClient? _api = widget.controller.api;
  List<Map<String, dynamic>> _devices = [];
  String? _error;
  bool _busy = true;
  bool get _authorized =>
      !widget.controller.needsAuthentication && widget.controller.api == _api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final devices = await _api!.fetchLoginDevices();
      if (mounted && _authorized) {
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
    final confirmed = await showAppConfirmDialog(
      context,
      title: id == null ? '退出其他全部设备？' : '退出这台设备？',
      message: '目标设备的同步和语音连接会中断，需要重新登录。本机继续在线；目标设备未上传的记录会保留在当地。',
      confirmLabel: '确认退出',
      cancelLabel: '取消',
      destructive: true,
    );
    if (confirmed != true || !_authorized || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api!.revokeLoginDevice(id);
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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('登录设备')),
      body: !_authorized
          ? const Center(
              child: AppEmptyState(
                icon: Icons.devices_other_outlined,
                title: '登录已失效，请返回重新认证',
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text(
                  '新设备登录不会使其他设备下线。最近活动时间不代表设备此刻在线。',
                  style: AppTextStyles.caption.copyWith(
                    fontSize: 13,
                    color: AppColors.textTertiary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: AppNotice(kind: AppNoticeKind.error, text: _error!),
                  ),
                if (_busy) const LinearProgressIndicator(),
                for (final device in _devices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: AppCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${device['name']} · ${device['platform']}',
                            style: AppTextStyles.bodyMd.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '最近活动：${_fmtTimestamp(device['last_seen_at'])}',
                            style: AppTextStyles.caption.copyWith(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (device['current'] == true)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceSubtle,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.pill,
                                ),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle_outline,
                                    size: 14,
                                    color: AppColors.textPrimary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '当前设备',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _revoke(device['id'] as String),
                              child: const Text('退出该设备'),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _busy || !_devices.any((d) => d['current'] != true)
                      ? null
                      : () => _revoke(null),
                  child: const Text('退出其他全部设备'),
                ),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy ? null : _load,
                  child: const Text('刷新'),
                ),
              ],
            ),
    ),
  );
}

String _fmtTimestamp(dynamic raw) {
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
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final min = d.minute.toString().padLeft(2, '0');
  final ss = d.second.toString().padLeft(2, '0');
  return '$mm-$dd $hh:$min:$ss';
}
