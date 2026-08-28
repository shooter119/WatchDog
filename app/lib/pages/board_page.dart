import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'entry_detail_page.dart';
import 'report_pressure_sheet.dart';

/// 危险等级：超时(0) → 报警(1) → 注意(2) → 安全(3)
int _severity(String status) => switch (status) {
  'timeout' => 0,
  'alarm' => 1,
  'warn' => 2,
  _ => 3,
};

/// 剩余时间格式（MM:SS / 已超时）
String _fmtRemaining(int ms) {
  if (ms <= 0) return '已超时';
  final m = (ms / 60000).floor();
  final s = (ms % 60000) ~/ 1000;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 看板仪表盘：在场人员 + 倒计时 + 状态分级（规范 5.1）
class BoardPage extends StatefulWidget {
  final AppController controller;
  final VoidCallback? onGoVoice;

  const BoardPage({super.key, required this.controller, this.onGoVoice});

  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  @override
  Widget build(BuildContext context) {
    final cfg = widget.controller.calcConfig;
    String statusOf(Entry e) =>
        e.statusAt(warnMin: cfg.warnMin, alarmMin: cfg.alarmMin);
    // 显式危险等级排序：超时 → 报警 → 注意 → 安全，同等级按剩余时间升序
    final active = widget.controller.entries.where((e) => e.isActive).toList()
      ..sort((a, b) {
        final sa = _severity(statusOf(a));
        final sb = _severity(statusOf(b));
        return sa != sb ? sa.compareTo(sb) : a.exitAt.compareTo(b.exitAt);
      });
    final danger = active.where((e) => statusOf(e) != 'normal').toList();
    final compactHeader =
        MediaQuery.sizeOf(context).width < 400 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: compactHeader
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('管控看板', style: AppTextStyles.h1),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: ConnectionStatus(
                          connected: !widget.controller.connectionLost,
                          syncing: widget.controller.syncing,
                          syncError: widget.controller.syncError,
                          onRetry: widget.controller.refreshNow,
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      const Text('管控看板', style: AppTextStyles.h1),
                      const Spacer(),
                      ConnectionStatus(
                        connected: !widget.controller.connectionLost,
                        syncing: widget.controller.syncing,
                        syncError: widget.controller.syncError,
                        onRetry: widget.controller.refreshNow,
                      ),
                    ],
                  ),
          ),

          // 断线时显示具体错误原因
          if (widget.controller.connectionLost &&
              widget.controller.syncError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                widget.controller.syncError!,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.alarm,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OverviewBanner(entries: active, config: cfg),
                if (danger.isNotEmpty)
                  _DangerAlertBar(entries: danger, config: cfg),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: active.isEmpty
                ? _EmptyBoard(onGoVoice: widget.onGoVoice)
                : RefreshIndicator(
                    onRefresh: _onRefresh,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      // 中央语音按钮向内容区悬浮，保留足够尾部空间，
                      // 确保最后一张人员卡片可完整滚动到按钮上方。
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                      itemCount: active.length,
                      itemBuilder: (context, i) => _EntryCard(
                        entry: active[i],
                        config: cfg,
                        onTap: () => _openDetail(active[i]),
                        onReport: () => _openReportSheet(active[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 下拉刷新：等待实际同步完成；失败时明确反馈
  Future<void> _onRefresh() async {
    await widget.controller.refreshNow();
    if (!mounted) return;
    if (widget.controller.syncError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('同步失败，当前使用本地数据'),
          backgroundColor: AppColors.caution,
        ),
      );
    }
  }

  void _openDetail(Entry e) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            EntryDetailPage(controller: widget.controller, entryId: e.id),
      ),
    );
  }

  void _openReportSheet(Entry e) {
    showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) =>
          ReportPressureSheet(controller: widget.controller, entry: e),
    );
  }
}

/// 顶部概览横幅：在场人数 / 需关注 / 最早到期（规范 4.1）
class _OverviewBanner extends StatelessWidget {
  final List<Entry> entries;
  final CalcConfig config;

  const _OverviewBanner({required this.entries, required this.config});

  @override
  Widget build(BuildContext context) {
    final dangerCount = entries
        .where(
          (e) =>
              e.statusAt(warnMin: config.warnMin, alarmMin: config.alarmMin) !=
              'normal',
        )
        .length;
    // 最早到期 = 剩余时间最短者（与排序无关）
    final earliest = entries.isEmpty
        ? null
        : entries.reduce((a, b) => a.exitAt <= b.exitAt ? a : b);
    final earliestStatus = earliest?.statusAt(
      warnMin: config.warnMin,
      alarmMin: config.alarmMin,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.card,
      ),
      child: Row(
        children: [
          Expanded(
            child: _metric(
              value: '${entries.length}',
              label: '在场人员',
              icon: Icons.people_outline,
              color: AppColors.textPrimary,
            ),
          ),
          Container(width: 1, height: 40, color: AppColors.border),
          Expanded(
            child: _metric(
              value: '$dangerCount',
              label: '需关注',
              icon: Icons.warning_amber_rounded,
              color: AppColors.textPrimary,
            ),
          ),
          Container(width: 1, height: 40, color: AppColors.border),
          Expanded(
            child: _metric(
              value: earliest == null ? '--' : _earliestText(earliest),
              label: '最早到期',
              icon: Icons.timer_outlined,
              color: earliestStatus == null
                  ? AppColors.textPrimary
                  : switch (earliestStatus) {
                      'warn' => AppColors.caution,
                      'alarm' => AppColors.alarm,
                      'timeout' => AppColors.timeout,
                      _ => AppColors.textPrimary,
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric({
    required String value,
    required String label,
    required IconData icon,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, size: 18, color: AppColors.textTertiary),
        const SizedBox(height: 4),
        FittedBox(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  String _earliestText(Entry e) => _fmtRemaining(e.remainingMs);
}

/// 危险提示条：有人处于 注意/报警/超时 时，在概览卡下高优先级提示（颜色取最严重状态）
class _DangerAlertBar extends StatelessWidget {
  final List<Entry> entries;
  final CalcConfig config;

  const _DangerAlertBar({required this.entries, required this.config});

  @override
  Widget build(BuildContext context) {
    final statuses = entries
        .map(
          (e) => e.statusAt(warnMin: config.warnMin, alarmMin: config.alarmMin),
        )
        .toList();
    final worst = statuses.reduce(
      (a, b) => _severity(a) <= _severity(b) ? a : b,
    );
    final color = switch (worst) {
      'timeout' => AppColors.timeout,
      'alarm' => AppColors.alarm,
      _ => AppColors.caution,
    };
    final earliest = entries.reduce((a, b) => a.exitAt <= b.exitAt ? a : b);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: AppShadow.card,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${entries.length} 人需要关注 · 最早到期 ${_fmtRemaining(earliest.remainingMs)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyBoard extends StatelessWidget {
  final VoidCallback? onGoVoice;

  const _EmptyBoard({this.onGoVoice});

  @override
  Widget build(BuildContext context) {
    final voiceGuide = onGoVoice == null
        ? null
        : [
            const SizedBox(height: 20),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: onGoVoice,
                icon: const Icon(Icons.mic_rounded),
                label: const Text('去警情处置'),
              ),
            ),
          ];
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Semantics(
            container: true,
            label: '当前在场人员 0 人',
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '0',
                    style: TextStyle(
                      fontSize: 36,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
                      color: AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '在场',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '暂无人员在场',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '按住底部语音按钮登记进场',
            style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
          ),
          ...?voiceGuide,
        ],
      ),
    );
  }
}

/// 人员状态卡片：整块状态色，第一层只保留 姓名/状态/剩余时间/持续时长/更新压力
/// 两个时间左右式同排：剩余时间为视觉重心（大字号），持续时长在右侧（小一号）
/// 单卡约 110dp 高，一屏可容纳 4 名同时进场的队员
class _EntryCard extends StatelessWidget {
  final Entry entry;
  final CalcConfig config;
  final VoidCallback onTap;
  final VoidCallback onReport;

  const _EntryCard({
    required this.entry,
    required this.config,
    required this.onTap,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final status = e.statusAt(
      warnMin: config.warnMin,
      alarmMin: config.alarmMin,
    );
    final s = EntryStatus.of(status);
    final fg = s.fg;
    final subFg = fg.withValues(alpha: 0.75);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final stackedHeader =
        MediaQuery.sizeOf(context).width < 360 || textScale > 1.25;
    final statusAndAction = Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        StatusBadge(
          status: status,
          onColorCard: true,
          fontSize: 13,
          height: 48,
        ),
        _UpdatePressureButton(fg: fg, onPressed: onReport),
      ],
    );
    final name = Text(
      e.name,
      maxLines: stackedHeader ? 2 : 1,
      softWrap: stackedHeader,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 20,
        height: 1.25,
        fontWeight: FontWeight.w800,
        color: fg,
      ),
    );

    final card = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: s.color,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.4),
          width: 1,
        ),
        boxShadow: AppShadow.card,
      ),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stackedHeader) ...[
                name,
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerLeft, child: statusAndAction),
              ] else
                Row(
                  children: [
                    Expanded(child: name),
                    const SizedBox(width: 8),
                    statusAndAction,
                  ],
                ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 剩余时间：主指标，大字号靠左
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          CountdownText(
                            ms: e.remainingMs,
                            color: fg,
                            size: 44,
                            timeoutText: '已超时',
                          ),
                          const SizedBox(width: 6),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '剩余时间',
                              style: TextStyle(
                                color: subFg,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 1,
                    height: 30,
                    color: subFg.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 10),
                  // 持续时长：进入现场内部时长，次指标靠右
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '持续时长',
                              style: TextStyle(
                                color: subFg,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _elapsedTime(e),
                            style: TextStyle(
                              fontSize: 26,
                              height: 1.0,
                              fontWeight: FontWeight.w800,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: fg,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final wrapped = s.danger ? PulseGlow(color: s.color, child: card) : card;
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: wrapped);
  }

  /// 进入现场后的持续时长（MM:SS / H:MM:SS）
  String _elapsedTime(Entry e) {
    final ms = DateTime.now().millisecondsSinceEpoch - e.entryAt;
    final totalSec = ms.clamp(0, 1 << 62) ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// 卡片顶行的快速更新压力按钮：至少 48px 触控区，紧凑胶囊，独立响应点击
class _UpdatePressureButton extends StatelessWidget {
  final Color fg;
  final VoidCallback onPressed;

  const _UpdatePressureButton({required this.fg, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fg.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onPressed,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.speed, size: 16, color: fg),
              const SizedBox(width: 4),
              Text(
                '更新压力',
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
