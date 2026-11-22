import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/sync/sync_store.dart';
import '../../../design_system/design_system.dart';
import '../data/models/entry.dart';
import '../state/monitor_store.dart';

/// 现场监控数据统计页：时间范围筛选（今天/本周/本月/全部）+ 汇总 + 人员次数/时长排行。
class MonitorStatsScreen extends StatefulWidget {
  const MonitorStatsScreen({
    super.key,
    required this.monitorStore,
    this.syncStore,
    this.onRefresh,
    this.isGuest = false,
    this.nowMs,
  });

  final MonitorStore monitorStore;
  final SyncStore? syncStore;
  final Future<void> Function()? onRefresh;
  final bool isGuest;
  final int Function()? nowMs;

  @override
  State<MonitorStatsScreen> createState() => _MonitorStatsScreenState();
}

class _MonitorStatsScreenState extends State<MonitorStatsScreen> {
  static const List<String> _ranges = <String>['今天', '本周', '本月', '全部'];

  String _range = '今天';
  bool _sortByDuration = false;

  int _currentNowMs() =>
      widget.nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  int? _rangeStartMs(int nowMs) {
    final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
    final dayStart = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      '今天' => dayStart.millisecondsSinceEpoch,
      '本周' =>
        dayStart.subtract(Duration(days: now.weekday - 1)).millisecondsSinceEpoch,
      '本月' => DateTime(now.year, now.month, 1).millisecondsSinceEpoch,
      _ => null,
    };
  }

  static int _durationMsOf(Entry entry, int nowMs) {
    final diff = (entry.exitedAt ?? nowMs) - entry.entryAt;
    return diff > 0 ? diff : 0;
  }

  static String _formatDuration(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 60) return '$minutes 分钟';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分';
  }

  List<({Entry entry, int durationMs})> _filteredEntries(int nowMs) {
    final start = _rangeStartMs(nowMs);
    return widget.monitorStore.entries
        .where((e) => start == null || e.entryAt >= start)
        .map((e) => (entry: e, durationMs: _durationMsOf(e, nowMs)))
        .toList();
  }

  List<({String name, int count, int totalMs, int avgMs})> _perPerson(
    List<({Entry entry, int durationMs})> filtered,
  ) {
    final grouped = <String, ({int count, int totalMs})>{};
    for (final row in filtered) {
      final cur = grouped[row.entry.name] ?? (count: 0, totalMs: 0);
      grouped[row.entry.name] = (
        count: cur.count + 1,
        totalMs: cur.totalMs + row.durationMs,
      );
    }
    final list = grouped.entries
        .map(
          (item) => (
            name: item.key,
            count: item.value.count,
            totalMs: item.value.totalMs,
            avgMs: item.value.count == 0
                ? 0
                : item.value.totalMs ~/ item.value.count,
          ),
        )
        .toList();
    list.sort((a, b) {
      if (_sortByDuration) {
        final d = b.totalMs.compareTo(a.totalMs);
        return d != 0 ? d : b.count.compareTo(a.count);
      }
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : b.totalMs.compareTo(a.totalMs);
    });
    return list;
  }

  DsConnectionState _resolveConnectionState() {
    final sync = widget.syncStore;
    if (sync == null || widget.isGuest) return DsConnectionState.online;
    if (sync.syncing) return DsConnectionState.reconnecting;
    if (sync.connectionLost) return DsConnectionState.offline;
    return DsConnectionState.online;
  }

  Future<void> _handleRefresh() async => widget.onRefresh?.call();

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final listenables = <Listenable>[
      widget.monitorStore,
      if (widget.syncStore != null) widget.syncStore!,
    ];

    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (BuildContext context, Widget? _) {
        final now = _currentNowMs();
        final filtered = _filteredEntries(now);
        final totalMs = filtered.fold<int>(0, (sum, r) => sum + r.durationMs);
        final activeCount =
            widget.monitorStore.entries.where((e) => e.isActive).length;
        final people = _perPerson(filtered);

        final connState = _resolveConnectionState();
        return Scaffold(
          backgroundColor: colors.canvas,
          appBar: AppBar(
            title: const Text('数据统计'),
            actions: <Widget>[
              if (widget.syncStore != null && connState != DsConnectionState.online)
                Padding(
                  padding: const EdgeInsets.only(right: DsSpacing.md),
                  child: Center(
                    child: ConnectionPill(
                      state: connState,
                      onTap: widget.onRefresh == null ? null : _handleRefresh,
                    ),
                  ),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildRangeSelector(context),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _handleRefresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                        DsSpacing.pageMargin,
                        DsSpacing.md,
                        DsSpacing.pageMargin,
                        DsSpacing.xxl,
                      ),
                      children: <Widget>[
                        _buildSummaryCards(
                          context,
                          count: filtered.length,
                          totalMs: totalMs,
                          activeCount: activeCount,
                        ),
                        const SizedBox(height: DsSpacing.xl),
                        _buildRankingHeader(context),
                        const SizedBox(height: DsSpacing.sm),
                        if (people.isEmpty)
                          const StatePlaceholder.empty(
                            icon: DsIcons.stats,
                            message: '所选范围内暂无进出记录',
                          )
                        else
                          for (final (i, p) in people.indexed) ...<Widget>[
                            _StatsPersonCard(
                              rank: i + 1,
                              person: p,
                              formatDuration: _formatDuration,
                            ),
                            if (i < people.length - 1)
                              const SizedBox(height: DsSpacing.sm),
                          ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRangeSelector(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.sm,
        DsSpacing.pageMargin,
        DsSpacing.xs,
      ),
      child: SegmentedButton<String>(
        segments: <ButtonSegment<String>>[
          for (final r in _ranges) ButtonSegment<String>(value: r, label: Text(r)),
        ],
        selected: <String>{_range},
        onSelectionChanged: (Set<String> next) {
          if (next.isEmpty) return;
          HapticFeedback.selectionClick();
          setState(() => _range = next.first);
        },
        showSelectedIcon: false,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, DsSizes.touchTarget)),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.selected) ? colors.brand : colors.surface,
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.selected)
                ? colors.onBrand
                : colors.textSecondary,
          ),
          textStyle: WidgetStateProperty.resolveWith<TextStyle>(
            (states) => ds.typography.body.copyWith(
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: colors.border)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: DsRadius.borderMd),
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCards(
    BuildContext context, {
    required int count,
    required int totalMs,
    required int activeCount,
  }) {
    final compact =
        MediaQuery.sizeOf(context).width < 400 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    final cards = <Widget>[
      _SummaryMetricCard(icon: DsIcons.fireExtinguisher, label: '当前在场', value: '$activeCount 人'),
      _SummaryMetricCard(icon: DsIcons.repeat, label: '$_range进场', value: '$count 人次'),
      _SummaryMetricCard(icon: DsIcons.time, label: '$_range累计', value: _formatDuration(totalMs)),
    ];
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < cards.length; i++) ...<Widget>[
            cards[i],
            if (i < cards.length - 1) const SizedBox(height: DsSpacing.sm),
          ],
        ],
      );
    }
    return Row(
      children: <Widget>[
        for (var i = 0; i < cards.length; i++) ...<Widget>[
          Expanded(child: cards[i]),
          if (i < cards.length - 1) const SizedBox(width: DsSpacing.sm),
        ],
      ],
    );
  }

  Widget _buildRankingHeader(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            _sortByDuration ? '时长排行' : '次数排行',
            style: ds.typography.title.copyWith(color: colors.textPrimary),
          ),
        ),
        Semantics(
          button: true,
          label: _sortByDuration ? '当前按总时长排序' : '当前按次数排序',
          hint: _sortByDuration ? '点击切换为按次数排序' : '点击切换为按总时长排序',
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _sortByDuration = !_sortByDuration);
            },
            borderRadius: DsRadius.borderSm,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: DsSizes.touchTarget,
                minHeight: DsSizes.touchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DsSpacing.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      _sortByDuration ? DsIcons.time : DsIcons.repeat,
                      size: DsSizes.iconSm,
                      color: colors.brandText,
                    ),
                    const SizedBox(width: DsSpacing.xs),
                    Text(
                      _sortByDuration ? '按总时长' : '按次数',
                      style: ds.typography.caption.copyWith(
                        color: colors.brandText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryMetricCard extends StatelessWidget {
  const _SummaryMetricCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: DsSizes.iconMd, color: context.ds.colors.brandText),
          const SizedBox(height: DsSpacing.sm),
          MetricReadout(label: label, value: value),
        ],
      ),
    );
  }
}

class _StatsPersonCard extends StatelessWidget {
  const _StatsPersonCard({
    required this.rank,
    required this.person,
    required this.formatDuration,
  });

  final int rank;
  final ({String name, int count, int totalMs, int avgMs}) person;
  final String Function(int ms) formatDuration;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final (Color badgeBg, Color badgeFg) = switch (rank) {
      1 => (colors.cautionFill, colors.onCaution),
      2 => (colors.brand, colors.onBrand),
      3 => (colors.safeFill, colors.onSafe),
      _ => (colors.surfaceMuted, colors.textSecondary),
    };

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final compact =
              constraints.maxWidth < 360 ||
              MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
          final rankBadge = Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: badgeBg,
              borderRadius: DsRadius.borderSm,
            ),
            child: Text(
              '$rank',
              style: DsTypography.tabular(
                ds.typography.body.copyWith(color: badgeFg, fontWeight: FontWeight.w700),
              ),
            ),
          );
          final metrics = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: compact ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${person.count} 次 · ${formatDuration(person.totalMs)}',
                softWrap: true,
                style: DsTypography.tabular(
                  ds.typography.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: DsSpacing.xs),
              Text(
                '平均 ${formatDuration(person.avgMs)}',
                softWrap: true,
                style: DsTypography.tabular(
                  ds.typography.caption.copyWith(color: colors.textSecondary),
                ),
              ),
            ],
          );

          if (compact) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                rankBadge,
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        person.name,
                        softWrap: true,
                        style: ds.typography.title.copyWith(color: colors.textPrimary),
                      ),
                      const SizedBox(height: DsSpacing.xs),
                      metrics,
                    ],
                  ),
                ),
              ],
            );
          }

          return Row(
            children: <Widget>[
              rankBadge,
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: Text(
                  person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typography.title.copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              metrics,
            ],
          );
        },
      ),
    );
  }
}
