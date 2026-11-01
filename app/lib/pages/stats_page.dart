import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 数据页：消防员进入火场的时长/次数统计，支持时间范围与人员筛选。
/// 汇总卡片 + 每人排行（次数/总时长/平均时长）。
class StatsPage extends StatefulWidget {
  final AppController controller;

  const StatsPage({super.key, required this.controller});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  String _range = '今天'; // 今天 / 本周 / 本月 / 全部
  bool _sortByDuration = false; // false = 按次数排，true = 按时长排

  static const _ranges = ['今天', '本周', '本月', '全部'];

  int? _rangeStartMs() {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      '今天' => dayStart.millisecondsSinceEpoch,
      '本周' =>
        dayStart
            .subtract(Duration(days: now.weekday - 1))
            .millisecondsSinceEpoch,
      '本月' => DateTime(now.year, now.month, 1).millisecondsSinceEpoch,
      _ => null,
    };
  }

  /// 单条记录的实际在场时长：已退场用实际出场时间，未退场按当前时刻累计
  static int _durationMsOf(Entry e, int nowMs) {
    final end = e.exitedAt ?? nowMs;
    final d = end - e.entryAt;
    return d > 0 ? d : 0;
  }

  List<({Entry e, int durationMs})> _filteredEntries() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final start = _rangeStartMs();
    return widget.controller.entries
        .where((e) => start == null || e.entryAt >= start)
        .map((e) => (e: e, durationMs: _durationMsOf(e, nowMs)))
        .toList();
  }

  /// 按人聚合：次数、总时长、平均时长
  List<({String name, int count, int totalMs, int avgMs})> _perPerson() {
    final grouped = <String, ({int count, int totalMs})>{};
    for (final r in _filteredEntries()) {
      final cur = grouped[r.e.name] ?? (count: 0, totalMs: 0);
      grouped[r.e.name] = (
        count: cur.count + 1,
        totalMs: cur.totalMs + r.durationMs,
      );
    }
    final list = grouped.entries
        .map(
          (e) => (
            name: e.key,
            count: e.value.count,
            totalMs: e.value.totalMs,
            avgMs: e.value.count == 0 ? 0 : e.value.totalMs ~/ e.value.count,
          ),
        )
        .toList();
    list.sort((a, b) {
      if (_sortByDuration) {
        return b.totalMs.compareTo(a.totalMs);
      }
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : b.totalMs.compareTo(a.totalMs);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredEntries();
    final totalMs = filtered.fold<int>(0, (sum, r) => sum + r.durationMs);
    final activeCount = widget.controller.entries
        .where((e) => e.isActive)
        .length;
    final people = _perPerson();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('数据统计')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s4,
                AppSpacing.s2,
                AppSpacing.s4,
                0,
              ),
              child: Row(
                children: [
                  ConnectionStatus(
                    connected: !widget.controller.connectionLost,
                    syncing: widget.controller.syncing,
                    syncError: widget.controller.syncError,
                    onRetry: widget.controller.refreshNow,
                  ),
                ],
              ),
            ),
            _buildFilters(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: widget.controller.refreshNow,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.s4,
                    AppSpacing.s3,
                    AppSpacing.s4,
                    100,
                  ),
                  children: [
                    _buildSummary(filtered.length, totalMs, activeCount),
                    const SizedBox(height: 22),
                    SectionTitle(
                      text: _sortByDuration ? '时长排行' : '次数排行',
                      trailing: Semantics(
                        button: true,
                        excludeSemantics: true,
                        label: _sortByDuration ? '当前按总时长排序' : '当前按次数排序',
                        hint: _sortByDuration ? '点击切换为按次数排序' : '点击切换为按总时长排序',
                        onTap: () =>
                            setState(() => _sortByDuration = !_sortByDuration),
                        child: Tooltip(
                          message: _sortByDuration ? '切换为按次数排序' : '切换为按总时长排序',
                          child: InkWell(
                            excludeFromSemantics: true,
                            onTap: () => setState(
                              () => _sortByDuration = !_sortByDuration,
                            ),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _sortByDuration
                                          ? Icons.timer_outlined
                                          : Icons.repeat,
                                      size: 15,
                                      color: AppColors.textTertiary,
                                    ),
                                    const SizedBox(width: AppSpacing.s1),
                                    Text(
                                      _sortByDuration ? '按总时长' : '按次数',
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.textTertiary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (people.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.s10),
                        child: Center(
                          child: AppEmptyState(
                            icon: Icons.bar_chart_outlined,
                            title: '所选范围内暂无进出记录',
                          ),
                        ),
                      )
                    else
                      for (final (i, p) in people.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                          child: _PersonRow(rank: i + 1, person: p),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 时间范围筛选
  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s1,
      ),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<String>(
          segments: [
            for (final r in _ranges)
              ButtonSegment<String>(value: r, label: Text(r)),
          ],
          selected: {_range},
          onSelectionChanged: (newSelection) {
            if (newSelection.isNotEmpty) {
              setState(() => _range = newSelection.first);
            }
          },
          showSelectedIcon: false,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 48)),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return AppColors.actionPrimary;
              }
              return AppColors.surface;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return AppColors.onPrimary;
              }
              return AppColors.textSecondary;
            }),
            textStyle: WidgetStateProperty.resolveWith((states) {
              return AppTextStyles.label.copyWith(
                fontWeight: states.contains(WidgetState.selected)
                    ? FontWeight.w800
                    : FontWeight.w600,
              );
            }),
            side: WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 汇总卡片：当前在场 / 进场人次 / 累计时长
  Widget _buildSummary(int count, int totalMs, int activeCount) {
    final compact =
        MediaQuery.sizeOf(context).width < 400 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    final cards = [
      _SummaryCard(
        icon: Icons.fire_extinguisher,
        color: AppColors.textPrimary,
        label: '当前在场',
        value: '$activeCount 人',
        compact: compact,
      ),
      _SummaryCard(
        icon: Icons.repeat,
        color: AppColors.actionPrimary,
        label: '$_range进场',
        value: '$count 人次',
        compact: compact,
      ),
      _SummaryCard(
        icon: Icons.timer_outlined,
        color: AppColors.textSecondary,
        label: '$_range累计',
        value: _fmtDuration(totalMs),
        compact: compact,
      ),
    ];
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            cards[i],
            if (i < cards.length - 1) const SizedBox(height: AppSpacing.s2),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          Expanded(child: cards[i]),
          if (i < cards.length - 1) const SizedBox(width: AppSpacing.s2),
        ],
      ],
    );
  }

  static String _fmtDuration(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 60) return '$minutes 分钟';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分';
  }
}

class _SummaryCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final bool compact;

  const _SummaryCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      color: AppColors.surfaceSubtle,
      side: BorderSide(color: AppColors.border, width: 1),
      radius: AppRadius.md,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: AppSpacing.s2),
          Builder(
            builder: (context) {
              final text = Text(
                value,
                maxLines: compact ? null : 1,
                overflow: compact
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: AppTextStyles.h2.copyWith(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              );
              // 纵向（compact）布局允许换行，不缩字；横排三卡才按宽度适配
              return compact
                  ? text
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: text,
                    );
            },
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            label,
            maxLines: compact ? null : 1,
            overflow: compact ? TextOverflow.visible : TextOverflow.ellipsis,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 排行行：名次 + 姓名 + 次数/总时长/平均时长
class _PersonRow extends StatelessWidget {
  final int rank;
  final ({String name, int count, int totalMs, int avgMs}) person;

  const _PersonRow({required this.rank, required this.person});

  static String _fmt(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 60) return '$minutes 分钟';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分';
  }

  @override
  Widget build(BuildContext context) {
    final rankColor = switch (rank) {
      1 => AppColors.rankGold,
      2 => AppColors.rankSilver,
      3 => AppColors.rankBronze,
      _ => AppColors.textTertiary,
    };
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 360 ||
                MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
            final rankBadge = Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                color: rankColor,
              ),
              child: Text(
                '$rank',
                style: AppTextStyles.label.copyWith(
                  fontWeight: FontWeight.w800,
                  // 实底徽章按底色亮度选深/浅字，保证 ≥4.5:1
                  color: rankColor.computeLuminance() > 0.18
                      ? AppColors.heroBackground
                      : AppColors.onStatus,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            );
            final metrics = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: compact
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                Text(
                  '${person.count} 次 · ${_fmt(person.totalMs)}',
                  softWrap: true,
                  style: AppTextStyles.label.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: AppSpacing.s1),
                Text(
                  '平均 ${_fmt(person.avgMs)}',
                  softWrap: true,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            );
            if (compact) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  rankBadge,
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          person.name,
                          softWrap: true,
                          style: AppTextStyles.bodyMd.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        metrics,
                      ],
                    ),
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                rankBadge,
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyMd.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                metrics,
              ],
            );
          },
        ),
      ),
    );
  }
}
