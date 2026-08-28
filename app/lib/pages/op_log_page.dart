import 'package:flutter/material.dart';

import '../services/op_log_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 操作日志：设置页二级页面
/// 展示每次语音操作（录音→转写→解析→确认/出场）的完整步骤日志，
/// 并可手动同步到服务器供开发者调试。
class OpLogPage extends StatefulWidget {
  final AppController controller;
  const OpLogPage({super.key, required this.controller});

  @override
  State<OpLogPage> createState() => _OpLogPageState();
}

class _OpLogPageState extends State<OpLogPage> {
  bool _init = false;

  @override
  void initState() {
    super.initState();
    OpLogService.instance.init().then((_) {
      if (mounted) setState(() => _init = true);
    });
  }

  Future<void> _flush() async {
    await OpLogService.instance.flush(api: widget.controller.api);
    if (mounted) setState(() {});
  }

  Future<void> _toggleSync(bool v) async {
    await OpLogService.instance.setSyncEnabled(v);
    if (mounted) setState(() {});
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空本地操作日志？'),
        content: const Text('仅清除本机日志，服务器上已同步的记录不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await OpLogService.instance.clearLocal();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final svc = OpLogService.instance;
    final logs = svc.logs;
    final groups = _groupByOp(logs);
    return Scaffold(
      appBar: AppBar(title: const Text('操作日志')),
      body: _init
          ? RefreshIndicator(
              onRefresh: _flush,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  _buildSyncCard(svc),
                  const SizedBox(height: 12),
                  if (groups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 120),
                      child: Column(
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,
                            size: 44,
                            color: AppColors.textTertiary,
                          ),
                          SizedBox(height: 14),
                          Text(
                            '暂无操作日志',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            '长按语音按钮进行一次语音录入后，这里会显示完整步骤',
                            style: TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...groups.map((g) => _OpGroupCard(group: g)),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildSyncCard(OpLogService svc) {
    final lastSync = svc.lastSyncedAt;
    final err = svc.lastSyncError;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 8),
      child: Column(
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              '同步到服务器',
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              svc.syncEnabled
                  ? (lastSync == null ? '尚未同步' : '上次同步 ${_fmtTime(lastSync)}')
                  : '已关闭，仅保存在本机',
              style: const TextStyle(fontSize: 11.5),
            ),
            activeThumbColor: AppColors.actionPrimary,
            value: svc.syncEnabled,
            onChanged: _toggleSync,
          ),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    svc.pendingCount > 0
                        ? '待上传 ${svc.pendingCount} 条'
                        : '已全部上传',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: svc.syncing ? null : _flush,
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text(svc.syncing ? '同步中…' : '立即同步'),
              ),
              IconButton(
                onPressed: _clear,
                tooltip: '清空本地日志',
                icon: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 14,
                    color: AppColors.caution,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '上次同步失败：$err',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.caution,
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

  /// 按 opId 分组：最新操作在前，组内步骤按时间正序
  List<_OpGroup> _groupByOp(List<OpLogEntry> logs) {
    final map = <String, List<OpLogEntry>>{};
    for (final e in logs.reversed) {
      map.putIfAbsent(e.opId, () => []).add(e);
    }
    return [
      for (final g in map.entries.toList().reversed)
        _OpGroup(opId: g.key, entries: g.value),
    ];
  }
}

class _OpGroup {
  final String opId;
  final List<OpLogEntry> entries;
  _OpGroup({required this.opId, required this.entries});

  OpLogEntry get first => entries.first;
  OpLogEntry? get end => entries.where((e) => e.stage == 'op_end').firstOrNull;
  int get problemCount => entries.where((e) => e.level != 'info').length;

  String get summary {
    final end = this.end;
    if (end != null) {
      final outcome = (end.data?['outcome'] as String?) ?? '';
      return switch (outcome) {
        'enter_ok' => '进场登记完成',
        'exit_ok' => '出火场登记完成',
        'no_speech' => '未识别到语音',
        'perm_denied' => '缺少麦克风权限',
        'record_error' => '录音失败',
        'error' => '处理出错',
        'exit_none' => '未找到在场人员',
        _ => '操作结束',
      };
    }
    final last = entries.last;
    return last.level == 'info' ? last.msg : last.msg;
  }
}

/// 一次语音操作的完整日志卡片（展开显示每个步骤）
class _OpGroupCard extends StatefulWidget {
  final _OpGroup group;
  const _OpGroupCard({required this.group});

  @override
  State<_OpGroupCard> createState() => _OpGroupCardState();
}

class _OpGroupCardState extends State<_OpGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final hasProblem = g.problemCount > 0;
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: hasProblem
              ? AppColors.caution.withValues(alpha: 0.5)
              : AppColors.border,
        ),
        boxShadow: AppShadow.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            button: true,
            excludeSemantics: true,
            expanded: _expanded,
            label: '${g.summary}，${_expanded ? '已展开' : '已收起'}',
            hint: _expanded ? '点击收起操作详情' : '点击展开操作详情',
            onTap: () => setState(() => _expanded = !_expanded),
            child: InkWell(
              excludeFromSemantics: true,
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasProblem
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 18,
                        color: hasProblem ? AppColors.caution : AppColors.safe,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              g.summary,
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${_fmtDateTime(g.first.ts)} · ${g.entries.length} 步'
                              '${hasProblem ? ' · ${g.problemCount} 处异常' : ''}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: AppColors.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 180),
            crossFadeState: _expanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Column(
              children: [
                const Divider(height: 1, indent: 14, endIndent: 14),
                for (final e in g.entries) _stepRow(e),
              ],
            ),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(OpLogEntry e) {
    final color = switch (e.level) {
      'error' => AppColors.alarm,
      'warn' => AppColors.caution,
      _ => AppColors.textTertiary,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      e.stage,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _fmtTime(e.ts),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  e.msg,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                    height: 1.4,
                  ),
                ),
                if (e.data != null && e.data!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSubtle.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      _prettyJson(e.data!),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: AppColors.textSecondary,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _prettyJson(Map<String, dynamic> data) {
  String str = '';
  data.forEach((k, v) {
    str += '$k: $v\n';
  });
  return str.trimRight();
}

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}

String _fmtDateTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}
