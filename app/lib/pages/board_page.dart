import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'entry_detail_page.dart';
import 'report_pressure_sheet.dart';

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
    final active = widget.controller.entries.where((e) => e.isActive).toList()
      ..sort((a, b) => a.exitAt.compareTo(b.exitAt));
    final cfg = widget.controller.calcConfig;
    final offline = widget.controller.syncError != null;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                const Text('火场安全管控看板', style: AppTextStyles.h1),
                const Spacer(),
                ConnectionStatus(
                  syncing: widget.controller.syncing,
                  offline: offline,
                  onRetry: () => widget.controller.startSync(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _OverviewBanner(entries: active, config: cfg),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: active.isEmpty
                ? _EmptyBoard(onGoVoice: widget.onGoVoice)
                : RefreshIndicator(
                    onRefresh: () async => widget.controller.startSync(),
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
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

  void _openDetail(Entry e) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EntryDetailPage(controller: widget.controller, entryId: e.id),
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
      builder: (_) => ReportPressureSheet(controller: widget.controller, entry: e),
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
        .where((e) => e.statusAt(warnMin: config.warnMin, alarmMin: config.alarmMin) != 'normal')
        .length;
    final earliest = entries.isEmpty ? null : entries.first;
    final earliestStatus = earliest?.statusAt(warnMin: config.warnMin, alarmMin: config.alarmMin);

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

  Widget _metric({required String value, required String label, required IconData icon, required Color color}) {
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
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11, letterSpacing: 0.5)),
      ],
    );
  }

  String _earliestText(Entry e) {
    final ms = e.remainingMs;
    if (ms <= 0) return '已超时';
    final m = (ms / 60000).floor();
    final s = (ms % 60000) ~/ 1000;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
                label: const Text('去语音录入'),
              ),
            ),
          ];
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
            ),
            child: const Icon(Icons.shield_outlined, size: 44, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 20),
          const Text('暂无人员在场', style: TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('可通过语音录入完成进场登记', style: TextStyle(color: AppColors.textTertiary, fontSize: 13)),
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

  const _EntryCard({required this.entry, required this.config, required this.onTap, required this.onReport});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final status = e.statusAt(warnMin: config.warnMin, alarmMin: config.alarmMin);
    final s = EntryStatus.of(status);
    final fg = s.fg;
    final subFg = fg.withValues(alpha: 0.75);

    final card = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: s.color,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
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
              Row(
                children: [
                  Flexible(
                    child: Text(
                      e.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 20, height: 1.25, fontWeight: FontWeight.w800, color: fg),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusBadge(status: status, onColorCard: true, fontSize: 11, height: 34),
                  const SizedBox(width: 8),
                  _UpdatePressureButton(fg: fg, onPressed: onReport),
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
                          CountdownText(ms: e.remainingMs, color: fg, size: 44, timeoutText: '已超时'),
                          const SizedBox(width: 6),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('剩余时间', style: TextStyle(color: subFg, fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(width: 1, height: 30, color: subFg.withValues(alpha: 0.4)),
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
                            child: Text('持续时长', style: TextStyle(color: subFg, fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _elapsedTime(e),
                            style: TextStyle(
                              fontSize: 26,
                              height: 1.0,
                              fontWeight: FontWeight.w800,
                              fontFeatures: const [FontFeature.tabularFigures()],
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: wrapped,
    );
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

/// 卡片顶行的快速更新压力按钮：紧凑胶囊，独立响应点击（父子手势由 InkWll 优先胜出）
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
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.speed, size: 16, color: fg),
              const SizedBox(width: 4),
              Text(
                '更新压力',
                style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
