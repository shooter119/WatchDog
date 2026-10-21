import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_controller.dart';
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(id == null ? '退出其他全部设备？' : '退出这台设备？'),
        content: const Text('目标设备的同步和语音连接会中断，需要重新登录。本机继续在线；目标设备未上传的记录会保留在当地。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认退出'),
          ),
        ],
      ),
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
                    fontSize: 12.5,
                    color: AppColors.textTertiary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
                          Text(
                            '最近活动：${DateTime.fromMillisecondsSinceEpoch((device['last_seen_at'] as num).toInt()).toLocal()}',
                          ),
                          if (device['current'] == true)
                            const Text('当前设备')
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
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _busy || !_devices.any((d) => d['current'] != true)
                      ? null
                      : () => _revoke(null),
                  child: const Text('退出其他全部设备'),
                ),
                TextButton(
                  onPressed: _busy ? null : _load,
                  child: const Text('刷新'),
                ),
              ],
            ),
    ),
  );
}
