import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/op_log_service.dart';
import 'op_log_group_card.dart';

/// 操作日志二级页（Design System v3.0）。
///
/// 按 `opId` 分组展示每次操作步骤，支持手动上传、同步开关切换，
/// 以及通过 `CommandSheet` 二次确认清空本地日志。
class OpLogPage extends StatefulWidget {
  const OpLogPage({
    super.key,
    this.service,
    this.onFlush,
  });

  final OpLogService? service;
  final Future<void> Function()? onFlush;

  @override
  State<OpLogPage> createState() => _OpLogPageState();
}

class _OpLogPageState extends State<OpLogPage> {
  bool _initialized = false;

  OpLogService get _service => widget.service ?? OpLogService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(
      _service.init().then((_) {
        if (mounted) setState(() => _initialized = true);
      }),
    );
  }

  Future<void> _flush() async {
    await widget.onFlush?.call();
    if (mounted) setState(() {});
  }

  Future<void> _toggleSync(bool value) async {
    await _service.setSyncEnabled(value);
    if (mounted) setState(() {});
  }

  Future<void> _clearConfirmed() async {
    final pending = _service.clearLocal();
    if (mounted) setState(() {});
    await pending;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final svc = _service;
    final groups = OpLogGroup.groupEntries(svc.logs);

    return CommandScaffold(
      appBar: AppBar(title: const Text('操作日志')),
      body: _initialized
          ? RefreshIndicator(
              onRefresh: _flush,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  DsSpacing.pageMargin,
                  DsSpacing.md,
                  DsSpacing.pageMargin,
                  DsSpacing.xxl,
                ),
                children: <Widget>[
                  _buildSyncCard(context, svc),
                  const SizedBox(height: DsSpacing.md),
                  if (groups.isEmpty)
                    const StatePlaceholder.empty(
                      icon: Icons.receipt_long_outlined,
                      message: '暂无操作日志',
                      detail: '长按底部语音按钮录一次，这里会显示完整步骤',
                    )
                  else
                    for (final group in groups) OpLogGroupCard(group: group),
                  _buildDangerZone(context),
                ],
              ),
            )
          : const StatePlaceholder.loading(message: '正在加载操作日志…'),
    );
  }

  Widget _buildSyncCard(BuildContext context, OpLogService svc) {
    final ds = context.ds;
    final colors = ds.colors;
    final lastSync = svc.lastSyncedAt;
    final err = svc.lastSyncError;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.xs,
        DsSpacing.sm,
        DsSpacing.sm,
      ),
      child: Column(
        children: <Widget>[
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '同步到服务器',
              style: ds.typography.body.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            subtitle: Text(
              svc.syncEnabled
                  ? (lastSync == null
                        ? '尚未同步'
                        : '上次同步 ${formatOpLogTime(lastSync)}')
                  : '已关闭，仅保存在本机',
              style: ds.typography.captionTabular.copyWith(
                color: colors.textSecondary,
              ),
            ),
            activeThumbColor: colors.brand,
            activeTrackColor: colors.brand.withValues(alpha: 0.28),
            value: svc.syncEnabled,
            onChanged: (v) => unawaited(_toggleSync(v)),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: DsSpacing.xs),
                  child: Text(
                    svc.pendingCount > 0 ? '待上传 ${svc.pendingCount} 条' : '已全部上传',
                    style: ds.typography.captionTabular.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(
                    DsSizes.touchTarget,
                    DsSizes.touchTarget,
                  ),
                ),
                onPressed: svc.syncing ? null : () => unawaited(_flush()),
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text(svc.syncing ? '同步中…' : '立即同步'),
              ),
            ],
          ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DsSpacing.xs,
                0,
                DsSpacing.xs,
                DsSpacing.xs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.error_outline, size: 14, color: colors.cautionText),
                  const SizedBox(width: DsSpacing.xs + 2),
                  Expanded(
                    child: Text(
                      '上次同步失败：$err',
                      style: ds.typography.caption.copyWith(
                        color: colors.cautionText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDangerZone(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: DsSpacing.lg),
        Divider(height: 1, color: colors.border),
        const SizedBox(height: DsSpacing.lg),
        Text(
          '危险区',
          style: ds.typography.caption.copyWith(
            color: colors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        CommandButton(
          key: const Key('op-log-clear-button'),
          label: '清空本地日志',
          icon: Icons.delete_outline,
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          expanded: true,
          confirmTitle: '清空本地操作日志？',
          confirmMessage: '仅清除本机日志，服务器上已同步的记录不受影响。',
          confirmActionLabel: '清空',
          cancelActionLabel: '取消',
          onPressed: () => unawaited(_clearConfirmed()),
        ),
      ],
    );
  }
}
