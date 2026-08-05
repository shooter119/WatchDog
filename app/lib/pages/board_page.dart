import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'entry_detail_page.dart';

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

/// 人员状态卡片：整块状态色，倒计时为视觉重心（规范 4.2）
class _EntryCard extends StatelessWidget {
  final Entry entry;
  final CalcConfig config;
  final VoidCallback onTap;

  const _EntryCard({required this.entry, required this.config, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final status = e.statusAt(warnMin: config.warnMin, alarmMin: config.alarmMin);
    final s = EntryStatus.of(status);
    final fg = s.fg;
    final subFg = fg.withValues(alpha: 0.75);

    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: s.color,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
        boxShadow: AppShadow.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  e.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 22, height: 1.25, fontWeight: FontWeight.w800, color: fg),
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(status: status, onColorCard: true),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                if (e.pressureMpa != null) ...[
                  Icon(Icons.speed, size: 14, color: subFg),
                  const SizedBox(width: 4),
                  Text('${e.pressureMpa} MPa', style: TextStyle(color: subFg, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                ],
                Icon(Icons.timer_outlined, size: 14, color: subFg),
                const SizedBox(width: 4),
                Text('${e.durationMin} 分钟上限', style: TextStyle(color: subFg, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Icon(Icons.schedule, size: 14, color: subFg),
                const SizedBox(width: 4),
                Text(_elapsedTime(e), style: TextStyle(color: subFg, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              CountdownText(ms: e.remainingMs, color: fg, size: 56, timeoutText: '已超时'),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('剩余时间', style: TextStyle(color: subFg, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );

    final wrapped = s.danger ? PulseGlow(color: s.color, child: card) : card;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: wrapped,
      ),
    );
  }

  String _elapsedTime(Entry e) {
    final ms = DateTime.now().millisecondsSinceEpoch - e.entryAt;
    final totalSec = ms.clamp(0, 1 << 62) ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')} 已进场'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')} 已进场';
  }
}
