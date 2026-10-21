import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:math';

import '../api/api_client.dart';
import '../services/offline_queue.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

class OfflineReviewPage extends StatefulWidget {
  final AppController controller;
  final OfflineQueue? queue;
  const OfflineReviewPage({super.key, required this.controller, this.queue});
  @override
  State<OfflineReviewPage> createState() => _OfflineReviewPageState();
}

class _OfflineReviewPageState extends State<OfflineReviewPage> {
  OfflineQueue get _queue => widget.queue ?? OfflineQueue.instance;
  late final ApiClient? _api = widget.controller.api;
  List<Map<String, Object?>> _rows = [];
  bool _busy = true;
  String? _error;
  bool get _authorized =>
      !widget.controller.needsAuthentication && widget.controller.api == _api;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = [
        ...await _queue.reviewOperations(),
        ...await _queue.legacyOperations(),
      ];
      if (mounted && _authorized) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _payload(Map<String, Object?> row) {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(row['payload'] as String) as Map,
      );
    } catch (_) {
      return {};
    }
  }

  String _description(Map<String, Object?> row) {
    final data = _payload(row);
    final label =
        {
          'entry': '进场',
          'exit': '出场',
          'pressure': '压力复核',
          'note': '随手记',
        }[row['type']] ??
        '现场记录';
    return '$label：${data['name'] ?? ''} ${data['pressure_mpa'] == null ? data['text'] ?? '' : "${data['pressure_mpa']} MPa"}';
  }

  String _result(Map<String, Object?> row) {
    try {
      final data = jsonDecode(row['result'] as String) as Map;
      final current = data['current'];
      return '${data['error'] ?? '请核对后处理'}${current is Map ? "\n服务器：${current['name'] ?? ''} ${current['pressure_mpa'] ?? '未知'} MPa，${current['exited_at'] == null ? '在场' : '已出场'}" : ''}';
    } catch (_) {
      return '请核对后处理';
    }
  }

  Future<void> _claim(Map<String, Object?> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认是本人留下的旧记录？'),
        content: const Text(
          '旧版本没有记录可靠的成员归属。只有确认这是本人在当前单位留下的记录，才可认领并核对。认领不会自动上传。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认本人记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_authorized) return;
    try {
      await _queue.claimLegacy(row['client_op_id'] as String);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _sendPrepared(
    Map<String, Object?> row,
    ApiClient client,
    Map<String, dynamic> request,
  ) async {
    final opId = row['client_op_id'] as String;
    try {
      await client.submitReviewedOperation(
        type: request['type'] as String,
        payload: Map<String, dynamic>.from(request['payload'] as Map),
        originalOpId: opId,
        newOpId: request['op_id'] as String,
        expectedVersion: (request['version'] as num?)?.toInt(),
      );
    } on ApiException catch (error) {
      if (error.statusCode != null &&
          error.statusCode! < 500 &&
          error.code != 'OPERATION_IN_PROGRESS') {
        await _queue.clearReviewRequest(opId);
      }
      rethrow;
    }
    if (!_authorized) return;
    await _queue.resolveReview(
      opId,
      jsonEncode({
        'action': 'resubmitted',
        'new_op_id': request['op_id'],
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> _review(Map<String, Object?> row, bool apply) async {
    if (_busy || !_authorized) return;
    setState(() => _busy = true);
    final opId = row['client_op_id'] as String;
    final client = _api!.forIncident(row['incident_id'] as String);
    try {
      if (apply && row['retry_request'] != null) {
        if (mounted) setState(() => _busy = true);
        await _sendPrepared(
          row,
          client,
          Map<String, dynamic>.from(
            jsonDecode(row['retry_request'] as String) as Map,
          ),
        );
        await _load();
        await widget.controller.sync();
        return;
      }
      final payload = _payload(row);
      if (apply && payload.isEmpty) {
        throw StateError('记录内容损坏，不能重新应用；可保留原记录');
      }
      final type = row['type'] as String;
      int? version;
      String current = '将保留原记录及本次处理结果。';
      if (apply) {
        final incident = await client.fetchIncident(
          row['incident_id'] as String,
        );
        if (!incident.isActive) throw StateError('警情已归档，只能保留记录，不可重新应用');
        if (type == 'pressure' || type == 'exit') {
          final entries = await client.fetchEntries();
          final entry = entries
              .where((e) => e.id == payload['entry_id'])
              .firstOrNull;
          if (entry == null || !entry.isActive) {
            throw StateError('人员不存在或已出场，不能重新应用');
          }
          version = entry.version;
          if (type == 'pressure') {
            payload.remove('name');
            if (entry.consumptionLpm != null) {
              payload['consumption_lpm'] = entry.consumptionLpm;
            }
          }
          current = '服务器：${entry.name}，${entry.pressureMpa ?? "未知"} MPa，在场。';
        }
      }
      if (!mounted || !_authorized) return;
      var pressureText = '';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(apply ? '核对后重新提交' : '保留记录，不应用'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(current),
                const SizedBox(height: 12),
                Text(
                  '本机原记录：${payload['name'] ?? payload['entry_id'] ?? ''} ${payload['pressure_mpa'] ?? payload['text'] ?? type}',
                ),
                if (apply && (type == 'pressure' || type == 'entry')) ...[
                  const SizedBox(height: 12),
                  const Text('请重新核实现场压力。原读数不会自动当作当前值提交。'),
                  TextField(
                    onChanged: (value) => pressureText = value,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '当前现场压力（MPa，0～40）',
                    ),
                  ),
                ],
                if (apply) const Text('确认后以当前状态提交；若其他设备再次修改，仍需重新核对。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      final pressureValue = double.tryParse(pressureText.trim());
      if (confirmed != true || !_authorized || !mounted) return;
      if (apply && (type == 'pressure' || type == 'entry')) {
        if (pressureValue == null ||
            !pressureValue.isFinite ||
            pressureValue <= 0 ||
            pressureValue > 40) {
          throw StateError('请输入有效的当前现场压力');
        }
        payload['pressure_mpa'] = pressureValue;
      }
      setState(() => _busy = true);
      if (apply) {
        final request = <String, dynamic>{
          'type': type,
          'payload': payload,
          'version': version,
          'op_id': base64UrlEncode(
            List<int>.generate(24, (_) => Random.secure().nextInt(256)),
          ),
        };
        final prepared = await _queue.prepareReview(opId, request);
        await _sendPrepared(row, client, prepared);
      } else {
        await _queue.resolveReview(
          opId,
          jsonEncode({
            'action': 'not_applied',
            'at': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      }
      await _load();
      await widget.controller.sync();
    } catch (error) {
      if (mounted && _authorized) {
        await _load();
        if (mounted) setState(() => _error = '$error');
      }
    } finally {
      client.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('离线记录待核对')),
      body: !_authorized
          ? const Center(
              child: AppEmptyState(
                icon: Icons.cloud_off_outlined,
                title: '登录已失效，请返回重新认证',
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text(
                  '这些记录尚未应用到服务器。核对后重新提交，或保留原记录而不应用。退出登录不会删除记录。',
                  style: AppTextStyles.caption.copyWith(
                    fontSize: 12.5,
                    color: AppColors.textTertiary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (!_busy && _rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('没有待核对记录'),
                  ),
                for (final row in _rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: AppCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${DateTime.fromMillisecondsSinceEpoch((row['occurred_at'] as num).toInt()).toLocal()}',
                          ),
                          Text(_description(row)),
                          Text(_result(row)),
                          if (row['owner_member_id'] == '' ||
                              row['owner_unit_id'] == '')
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _busy ? null : () => _claim(row),
                              child: const Text('确认本人旧记录'),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                  ),
                                  onPressed:
                                      _busy || row['retry_request'] != null
                                      ? null
                                      : () => _review(row, false),
                                  child: const Text('保留记录，不应用'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () => _review(row, true),
                                  child: Text(
                                    row['retry_request'] != null
                                        ? '重试已确认的提交'
                                        : '核对后重新提交',
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
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
