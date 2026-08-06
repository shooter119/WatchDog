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
      '本周' => dayStart
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
      grouped[r.e.name] = (count: cur.count + 1, totalMs: cur.totalMs + r.durationMs);
    }
    final list = grouped.entries.map((e) => (
          name: e.key,
          count: e.value.count,
          totalMs: e.value.totalMs,
          avgMs: e.value.count == 0 ? 0 : e.value.totalMs ~/ e.value.count,
        )).toList();
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
    final activeCount =
        widget.controller.entries.where((e) => e.isActive).length;
    final people = _perPerson();
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Text('数据统计', style: AppTextStyles.h1),
                const Spacer(),
                ConnectionStatus(
                  syncing: widget.controller.syncing,
                  offline: widget.controller.syncError != null,
                  onRetry: widget.controller.startSync,
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
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                children: [
                  _buildSummary(filtered.length, totalMs, activeCount),
                  const SizedBox(height: 16),
                  SectionTitle(
                    text: _sortByDuration ? '时长排行（点按切换排序）' : '次数排行（点按切换排序）',
                    trailing: GestureDetector(
                      onTap: () => setState(() => _sortByDuration = !_sortByDuration),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _sortByDuration ? Icons.timer_outlined : Icons.repeat,
                            size: 15,
                            color: AppColors.textTertiary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _sortByDuration ? '按总时长' : '按次数',
                            style: const TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (people.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                          '所选范围内暂无进出记录',
                          style: TextStyle(color: AppColors.textTertiary, fontSize: 14),
                        ),
                      ),
                    )
                  else
                    for (final (i, p) in people.indexed)
                      _PersonRow(rank: i + 1, person: p),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 时间范围筛选
  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final r in _ranges)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(r),
                  selected: _range == r,
                  onSelected: (_) => setState(() => _range = r),
                  showCheckmark: false,
                  selectedColor: AppColors.actionPrimary,
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: _range == r ? FontWeight.w800 : FontWeight.w600,
                    color: _range == r ? Colors.white : AppColors.textSecondary,
                  ),
                  backgroundColor: AppColors.surface,
                  side: BorderSide(color: _range == r ? AppColors.actionPrimary : AppColors.border),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 汇总卡片：当前在场 / 进场人次 / 累计时长
  Widget _buildSummary(int count, int totalMs, int activeCount) {
    return Row(
      children: [
        _SummaryCard(
          icon: Icons.fire_extinguisher,
          color: AppColors.alarm,
          label: '当前在场',
          value: '$activeCount 人',
        ),
        const SizedBox(width: 10),
        _SummaryCard(
          icon: Icons.repeat,
          color: AppColors.actionPrimary,
          label: '$_range进场',
          value: '$count 人次',
        ),
        const SizedBox(width: 10),
        _SummaryCard(
          icon: Icons.timer_outlined,
          color: AppColors.voice,
          label: '$_range累计',
          value: _fmtDuration(totalMs),
        ),
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

  const _SummaryCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 8),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ],
        ),
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
    final isTop = rank <= 3;
    final rankColor = switch (rank) {
      1 => const Color(0xFFF5B301),
      2 => const Color(0xFF9AA5B1),
      3 => const Color(0xFFB77B4A),
      _ => AppColors.textTertiary,
    };
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: rankColor.withValues(alpha: isTop ? 0.18 : 0.08),
            ),
            child: Text(
              '$rank',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: rankColor,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              person.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${person.count} 次 · ${_fmt(person.totalMs)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                '平均 ${_fmt(person.avgMs)}',
                style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
