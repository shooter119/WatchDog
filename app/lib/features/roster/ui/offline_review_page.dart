import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../design_system/design_system.dart';
import '../../../services/offline_queue.dart';
import 'offline_review_widgets.dart';

export 'offline_review_widgets.dart'
    show OfflineReviewEntrySnapshot, OfflineReviewGateway;

/// 离线冲突记录复核页（Design System v3.0）。
///
/// 保留旧记录人工认领、服务端版本对比、压力重新核实输入、持久化 `retry_request`
/// 幂等重试以及登录失效即时隐藏等全部核心不变量。
class OfflineReviewPage extends StatefulWidget {
  const OfflineReviewPage({
    super.key,
    required this.gateway,
    this.queue,
    this.isOffline = false,
  });

  final OfflineReviewGateway gateway;
  final OfflineQueue? queue;
  final bool isOffline;

  @override
  State<OfflineReviewPage> createState() => _OfflineReviewPageState();
}

class _OfflineReviewPageState extends State<OfflineReviewPage> {
  OfflineQueue get _queue => widget.queue ?? OfflineQueue.instance;
  List<Map<String, Object?>> _rows = const <Map<String, Object?>>[];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.gateway.changes?.addListener(_onChanged);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant OfflineReviewPage oldWidget) {
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
      final rows = <Map<String, Object?>>[
        ...await _queue.reviewOperations(),
        ...await _queue.legacyOperations(),
      ];
      if (mounted && widget.gateway.isAuthorized) {
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
      return <String, dynamic>{};
    }
  }

  String _description(Map<String, Object?> row) {
    final data = _payload(row);
    final label =
        const <String, String>{
          'entry': '进场',
          'exit': '出场',
          'pressure': '压力复核',
          'note': '随手记',
        }[row['type']] ??
        '现场记录';
    final detail = data['pressure_mpa'] == null
        ? '${data['text'] ?? ''}'
        : '${data['pressure_mpa']} MPa';
    return '$label：${data['name'] ?? ''} $detail';
  }

  String _result(Map<String, Object?> row) {
    try {
      final data = jsonDecode(row['result'] as String) as Map;
      final current = data['current'];
      final currentText = current is Map
          ? "\n服务器：${current['name'] ?? ''} ${current['pressure_mpa'] ?? '未知'} MPa，${current['exited_at'] == null ? '在场' : '已出场'}"
          : '';
      return '${data['error'] ?? '请核对后处理'}$currentText';
    } catch (_) {
      return '请核对后处理';
    }
  }

  Future<void> _claim(Map<String, Object?> row) async {
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: '确认是本人留下的旧记录？',
      builder: (BuildContext sheetContext) => Text(
        '旧版本没有记录可靠的成员归属。只有确认这是本人在当前单位留下的记录，才可认领并核对。认领不会自动上传。',
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
          label: '确认本人记录',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    );
    if (confirmed != true || !widget.gateway.isAuthorized) return;
    try {
      await _queue.claimLegacy(row['client_op_id'] as String);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _sendPrepared(
    Map<String, Object?> row,
    Map<String, dynamic> request,
  ) async {
    final opId = row['client_op_id'] as String;
    final incidentId = row['incident_id'] as String;
    try {
      await widget.gateway.submitReviewedOperation(
        incidentId: incidentId,
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
    if (!widget.gateway.isAuthorized) return;
    await _queue.resolveReview(
      opId,
      jsonEncode(<String, Object?>{
        'action': 'resubmitted',
        'new_op_id': request['op_id'],
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> _review(Map<String, Object?> row, bool apply) async {
    if (_busy || !widget.gateway.isAuthorized) return;
    setState(() => _busy = true);
    final opId = row['client_op_id'] as String;
    final incidentId = row['incident_id'] as String;

    try {
      if (apply && row['retry_request'] != null) {
        await _sendPrepared(
          row,
          Map<String, dynamic>.from(
            jsonDecode(row['retry_request'] as String) as Map,
          ),
        );
        await _load();
        await widget.gateway.syncAfterReview();
        return;
      }

      final payload = _payload(row);
      if (apply && payload.isEmpty) {
        throw StateError('记录内容损坏，不能重新应用；可保留原记录');
      }

      final type = row['type'] as String;
      int? version;
      var currentSummary = '将保留原记录及本次处理结果。';
      if (apply) {
        final active = await widget.gateway.isIncidentActive(incidentId);
        if (!active) {
          throw StateError('警情已归档，只能保留记录，不可重新应用');
        }
        if (type == 'pressure' || type == 'exit') {
          final entry = await widget.gateway.fetchEntrySnapshot(
            incidentId: incidentId,
            entryId: payload['entry_id']?.toString() ?? '',
          );
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
          currentSummary =
              '服务器：${entry.name}，${entry.pressureMpa ?? "未知"} MPa，在场。';
        }
      }

      if (!mounted || !widget.gateway.isAuthorized) return;
      final pressureController = TextEditingController();
      final needsPressure = apply && (type == 'pressure' || type == 'entry');
      final confirmed = await showCommandSheet<bool>(
        context: context,
        title: apply ? '核对后重新提交' : '保留记录，不应用',
        builder: (BuildContext sheetContext) {
          final sheetDs = sheetContext.ds;
          final colors = sheetDs.colors;
          final typo = sheetDs.typography;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                currentSummary,
                style: typo.body.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: DsSpacing.md),
              Text(
                '本机原记录：${payload['name'] ?? payload['entry_id'] ?? ''} ${payload['pressure_mpa'] ?? payload['text'] ?? type}',
                style: typo.body.copyWith(color: colors.textSecondary),
              ),
              if (needsPressure) ...<Widget>[
                const SizedBox(height: DsSpacing.md),
                Text(
                  '请重新核实现场压力。原读数不会自动当作当前值提交。',
                  style: typo.caption.copyWith(color: colors.cautionText),
                ),
                const SizedBox(height: DsSpacing.sm),
                TextField(
                  controller: pressureController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '当前现场压力（MPa，0～40）',
                  ),
                ),
              ],
              if (apply) ...<Widget>[
                const SizedBox(height: DsSpacing.sm),
                Text(
                  '确认后以当前状态提交；若其他设备再次修改，仍需重新核对。',
                  style: typo.caption.copyWith(color: colors.textTertiary),
                ),
              ],
            ],
          );
        },
        actionsBuilder: (BuildContext sheetContext) => <Widget>[
          CommandButton(
            label: '取消',
            variant: CommandButtonVariant.secondary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(sheetContext).pop(false),
          ),
          CommandButton(
            label: '确认',
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(sheetContext).pop(true),
          ),
        ],
      );
      final pressureText = pressureController.text.trim();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => pressureController.dispose(),
      );

      if (confirmed != true || !widget.gateway.isAuthorized || !mounted) return;
      if (needsPressure) {
        final pressureValue = double.tryParse(pressureText);
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
        await _sendPrepared(row, prepared);
      } else {
        await _queue.resolveReview(
          opId,
          jsonEncode(<String, Object?>{
            'action': 'not_applied',
            'at': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      }
      await _load();
      await widget.gateway.syncAfterReview();
    } catch (error) {
      if (mounted && widget.gateway.isAuthorized) {
        await _load();
        if (mounted) setState(() => _error = '$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(title: const Text('离线记录待核对')),
      body: !widget.gateway.isAuthorized
          ? const StatePlaceholder.empty(
              icon: DsIcons.connOffline,
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
                  '这些记录尚未应用到服务器。核对后重新提交，或保留原记录而不应用。退出登录不会删除记录。',
                  style: typo.caption.copyWith(
                    color: colors.textTertiary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: DsSpacing.md),
                if (_busy) ...<Widget>[
                  LinearProgressIndicator(
                    color: colors.brand,
                    backgroundColor: colors.surfaceMuted,
                  ),
                  const SizedBox(height: DsSpacing.md),
                ],
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
                if (!_busy && _rows.isEmpty)
                  const StatePlaceholder.empty(
                    icon: DsIcons.taskCheck,
                    message: '没有待核对记录',
                  ),
                for (final row in _rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: DsSpacing.cardGap),
                    child: OfflineReviewRecordCard(
                      timestamp: formatOfflineReviewTime(
                        (row['occurred_at'] as num).toInt(),
                      ),
                      description: _description(row),
                      result: _result(row),
                      isLegacy:
                          row['owner_member_id'] == '' ||
                          row['owner_unit_id'] == '',
                      hasRetryRequest: row['retry_request'] != null,
                      busy: _busy,
                      onClaim: () => _claim(row),
                      onDiscard: () => _review(row, false),
                      onApply: () => _review(row, true),
                    ),
                  ),
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
