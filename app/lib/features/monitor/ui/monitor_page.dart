import 'package:flutter/material.dart';

import '../../../core/sync/sync_store.dart';
import '../../../design_system/design_system.dart';
import '../data/models/entry.dart';
import '../state/alert_clock_store.dart';
import '../state/monitor_store.dart';
import 'entry_detail_screen.dart';
import 'monitor_stats_screen.dart';
import 'sheets/pressure_report_sheet.dart';
import 'widgets/monitor_risk_bar.dart';
import 'widgets/personnel_countdown_card.dart';

/// 现场监控主页面（Tab 1 空呼安全看板）。
///
/// 架构与性能要点：
/// - 列表层仅监听低频 [MonitorStore]、[SyncStore] 与 [AlertClockStore]（报警音开关）；
/// - 顶部风险概览与每张 [PersonnelCountdownCard] 均独立包在 [RepaintBoundary] 内并监听
///   [AlertClockStore.clockTick]，保证 20 人同屏 1 秒倒计时零全树重建；
/// - 严格遵循 DS v3.0 组件、D6 语义色板与 ≥ 56dp 主操作触控规范。
class MonitorPage extends StatefulWidget {
  const MonitorPage({
    super.key,
    required this.monitorStore,
    required this.alertClockStore,
    this.syncStore,
    this.isGuest = false,
    this.requiresIncident = false,
    this.onRefresh,
    this.onGoVoice,
    this.onRequestIncidentSelection,
    this.nowMs,
  });

  final MonitorStore monitorStore;
  final AlertClockStore alertClockStore;
  final SyncStore? syncStore;
  final bool isGuest;
  final bool requiresIncident;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onGoVoice;
  final VoidCallback? onRequestIncidentSelection;
  final int Function()? nowMs;

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  int _currentNowMs() =>
      widget.nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  DsConnectionState _resolveConnectionState() {
    final sync = widget.syncStore;
    if (sync == null || widget.isGuest) return DsConnectionState.online;
    if (sync.syncing) return DsConnectionState.reconnecting;
    if (sync.connectionLost) return DsConnectionState.offline;
    return DsConnectionState.online;
  }

  Future<void> _onRefresh() async {
    await widget.onRefresh?.call();
    if (!mounted) return;
    final sync = widget.syncStore;
    if (sync != null && sync.syncError != null && !sync.syncing) {
      final ds = context.ds;
      final caution = ds.colors.statusColors(DsStatus.caution);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '同步失败，当前使用本地数据',
            style: TextStyle(color: caution.onFill),
          ),
          backgroundColor: caution.fill,
        ),
      );
    }
  }

  void _openDetail(Entry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EntryDetailScreen(
          monitorStore: widget.monitorStore,
          alertClockStore: widget.alertClockStore,
          entryId: entry.id,
          nowMs: widget.nowMs,
        ),
      ),
    );
  }

  void _openReportSheet(Entry entry) {
    showPressureReportSheet(
      context,
      monitorStore: widget.monitorStore,
      entry: entry,
    );
  }

  void _openStats() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MonitorStatsScreen(
          monitorStore: widget.monitorStore,
          syncStore: widget.syncStore,
          onRefresh: widget.onRefresh,
          isGuest: widget.isGuest,
          nowMs: widget.nowMs,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      widget.monitorStore,
      widget.alertClockStore,
      if (widget.syncStore != null) widget.syncStore!,
    ];

    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (BuildContext context, Widget? _) {
        final now = _currentNowMs();
        final active = widget.monitorStore.sortedActiveEntries(nowMs: now);
        final sync = widget.syncStore;
        final showOffline =
            sync != null &&
            sync.connectionLost &&
            !sync.syncing &&
            !widget.isGuest;
        final showSoundMuted = !widget.alertClockStore.soundEnabled;

        return ColoredBox(
          key: const Key('monitor-page'),
          color: context.ds.colors.canvas,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildHeader(context),
                Padding(
                  padding: DsSpacing.pageHorizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (showOffline) ...<Widget>[
                        MonitorNoticeBanner(
                          status: DsStatus.alarm,
                          icon: DsIcons.connOffline,
                          text: '网络已中断，看板数据可能不是最新',
                          actionLabel: widget.onRefresh == null ? null : '重试',
                          onAction: widget.onRefresh == null
                              ? null
                              : () => _onRefresh(),
                        ),
                        const SizedBox(height: DsSpacing.sm),
                      ],
                      if (showSoundMuted) ...<Widget>[
                        const MonitorNoticeBanner(
                          key: Key('monitor-sound-muted-banner'),
                          status: DsStatus.caution,
                          icon: DsIcons.volumeMute,
                          text: '报警音已关闭',
                        ),
                        const SizedBox(height: DsSpacing.sm),
                      ],
                      RepaintBoundary(
                        child: ValueListenableBuilder<int>(
                          valueListenable: widget.alertClockStore.clockTick,
                          builder: (BuildContext context, int _, Widget? __) {
                            final tickNow = _currentNowMs();
                            final summary = widget.monitorStore.riskSummary(
                              nowMs: tickNow,
                            );
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                MonitorRiskBar(
                                  summary: summary,
                                  nowMs: tickNow,
                                ),
                                if (summary.dangerCount > 0) ...<Widget>[
                                  const SizedBox(height: DsSpacing.sm),
                                  MonitorDangerBanner(
                                    summary: summary,
                                    nowMs: tickNow,
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.md),
                Expanded(
                  child: active.isEmpty
                      ? _buildEmptyState(context)
                      : RefreshIndicator(
                          onRefresh: _onRefresh,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.fromLTRB(
                              DsSpacing.pageMargin,
                              0,
                              DsSpacing.pageMargin,
                              120 + MediaQuery.paddingOf(context).bottom,
                            ),
                            itemCount: active.length,
                            itemBuilder: (BuildContext context, int index) {
                              final entry = active[index];
                              return Padding(
                                padding: const EdgeInsets.only(
                                  bottom: DsSpacing.cardGap,
                                ),
                                child: PersonnelCountdownCard(
                                  entry: entry,
                                  calcConfig: widget.monitorStore.calcConfig,
                                  clockTick: widget.alertClockStore.clockTick,
                                  onTap: () => _openDetail(entry),
                                  onReportPressure: () =>
                                      _openReportSheet(entry),
                                  nowMs: widget.nowMs,
                                ),
                              );
                            },
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

  Widget _buildHeader(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final compactHeader =
        MediaQuery.sizeOf(context).width < 320 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;

    final title = Text(
      '现场监控',
      style: ds.typography.display.copyWith(color: colors.textPrimary),
    );

    final connState = _resolveConnectionState();
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (connState != DsConnectionState.online) ...<Widget>[
          ConnectionPill(
            state: connState,
            onTap: widget.onRefresh == null ? null : () => _onRefresh(),
          ),
          const SizedBox(width: DsSpacing.xs),
        ],
        IconButton(
          key: const Key('monitor-stats-btn'),
          tooltip: '数据统计',
          onPressed: _openStats,
          icon: Icon(DsIcons.stats, color: colors.textPrimary),
          constraints: const BoxConstraints(
            minWidth: DsSizes.touchTarget,
            minHeight: DsSizes.touchTarget,
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.md,
        DsSpacing.sm,
        DsSpacing.sm,
      ),
      child: compactHeader
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                title,
                const SizedBox(height: DsSpacing.xs),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(child: title),
                actions,
              ],
            ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final VoidCallback? action = widget.requiresIncident
        ? widget.onRequestIncidentSelection
        : widget.onGoVoice;
    final String? actionLabel = action == null
        ? null
        : (widget.requiresIncident ? '选择或新建警情' : '去指挥台');

    return SingleChildScrollView(
      key: const Key('monitor-empty-state'),
      child: StatePlaceholder.empty(
        icon: DsIcons.roster,
        message: '暂无人员在场',
        detail: widget.requiresIncident
            ? '选择警情后可登记进场'
            : '按住底部语音按钮登记进场',
        actionLabel: actionLabel,
        onAction: action,
      ),
    );
  }
}
