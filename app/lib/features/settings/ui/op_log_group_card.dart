import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/op_log_service.dart';

/// 按 `opId` 聚合的单次操作日志组。
class OpLogGroup {
  const OpLogGroup({required this.opId, required this.entries});

  final String opId;
  final List<OpLogEntry> entries;

  OpLogEntry get first => entries.first;
  OpLogEntry? get end => entries.where((e) => e.stage == 'op_end').firstOrNull;
  int get problemCount => entries.where((e) => e.level != 'info').length;

  String get summary {
    final endEntry = end;
    if (endEntry != null) {
      final outcome = (endEntry.data?['outcome'] as String?) ?? '';
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
    return entries.last.msg;
  }

  /// 按 `opId` 分组：最新操作在前，组内步骤按时间正序。
  static List<OpLogGroup> groupEntries(List<OpLogEntry> logs) {
    final map = <String, List<OpLogEntry>>{};
    for (final e in logs.reversed) {
      map.putIfAbsent(e.opId, () => <OpLogEntry>[]).add(e);
    }
    return <OpLogGroup>[
      for (final g in map.entries.toList().reversed)
        OpLogGroup(opId: g.key, entries: g.value),
    ];
  }
}

/// 一次操作的分组展开卡片（默认收起，点击展开全部步骤）。
class OpLogGroupCard extends StatefulWidget {
  const OpLogGroupCard({super.key, required this.group});

  final OpLogGroup group;

  @override
  State<OpLogGroupCard> createState() => _OpLogGroupCardState();
}

class _OpLogGroupCardState extends State<OpLogGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final g = widget.group;
    final hasProblem = g.problemCount > 0;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: SurfaceCard(
        padding: EdgeInsets.zero,
        borderRadius: DsRadius.borderMd,
        borderColor: hasProblem
            ? colors.cautionFill.withValues(alpha: 0.55)
            : colors.border,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
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
                borderRadius: DsRadius.borderMd,
                onTap: () => setState(() => _expanded = !_expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: DsSizes.touchTarget,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.lg,
                      vertical: DsSpacing.md,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          hasProblem
                              ? DsIcons.warning
                              : DsIcons.checkCircle,
                          size: 18,
                          color: hasProblem
                              ? colors.cautionText
                              : colors.safeText,
                        ),
                        const SizedBox(width: DsSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                g.summary,
                                style: ds.typography.body.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${formatOpLogDateTime(g.first.ts)} · ${g.entries.length} 步'
                                '${hasProblem ? ' · ${g.problemCount} 处异常' : ''}',
                                style: ds.typography.captionTabular.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: colors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: DsSpacing.sm),
                        Icon(
                          _expanded ? DsIcons.chevronUp : DsIcons.chevronDown,
                          size: DsSizes.iconMd,
                          color: colors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (disableAnimations)
              if (_expanded)
                _buildSteps(colors, g)
              else
                const SizedBox.shrink()
            else
              AnimatedCrossFade(
                duration: DsMotion.resolve(context, DsMotion.fast),
                crossFadeState: _expanded
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                firstChild: _buildSteps(colors, g),
                secondChild: const SizedBox(width: double.infinity),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSteps(DsColors colors, OpLogGroup g) => Column(
    children: <Widget>[
      Divider(
        height: 1,
        indent: DsSpacing.lg,
        endIndent: DsSpacing.lg,
        color: colors.border,
      ),
      for (final entry in g.entries) _StepRow(entry: entry),
    ],
  );
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.entry});

  final OpLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final levelColor = switch (entry.level) {
      'error' => colors.alarmText,
      'warn' => colors.cautionText,
      _ => colors.textTertiary,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.lg,
        vertical: DsSpacing.sm + 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: entry.level == 'error' ? 2 : 4),
            child: entry.level == 'error'
                ? Icon(DsIcons.statusAlarm, size: 12, color: colors.alarmText)
                : Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: levelColor,
                    ),
                  ),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        entry.stage,
                        style: ds.typography.caption.copyWith(
                          fontWeight: FontWeight.w700,
                          color: levelColor,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Text(
                      formatOpLogTime(entry.ts),
                      style: ds.typography.captionTabular.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.msg,
                  style: ds.typography.body.copyWith(
                    fontSize: 13,
                    color: colors.textPrimary,
                  ),
                ),
                if (entry.data != null && entry.data!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: DsSpacing.xs + 2),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(DsSpacing.sm),
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: DsRadius.borderSm,
                    ),
                    child: Text(
                      _prettyData(entry.data!),
                      style: ds.typography.captionTabular.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.textSecondary,
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

String _prettyData(Map<String, dynamic> data) {
  final buffer = StringBuffer();
  data.forEach((k, v) {
    buffer.writeln('$k: $v');
  });
  return buffer.toString().trimRight();
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

String formatOpLogTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${_twoDigits(d.hour)}:${_twoDigits(d.minute)}:${_twoDigits(d.second)}';
}

String formatOpLogDateTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${_twoDigits(d.month)}-${_twoDigits(d.day)} ${_twoDigits(d.hour)}:${_twoDigits(d.minute)}';
}
