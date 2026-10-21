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
    return AnimatedBuilder(
      animation: widget.controller.clockTick,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
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
    final requiresIncident = widget.controller.requiresIncident;
    // 真机逻辑宽度约 320dp，标题与紧凑连接状态仍可同排；只有更窄的
    // 视口或明显放大的字体才切换为上下布局，避免状态胶囊占满横向空间。
    final compactHeader =
        MediaQuery.sizeOf(context).width < 300 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s3,
              AppSpacing.s4,
              AppSpacing.s2,
            ),
            child: compactHeader
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('管控看板', style: AppTextStyles.h1),
                      const SizedBox(height: AppSpacing.s2),
                      Align(
                        alignment: Alignment.centerRight,
                        widthFactor: 1,
                        heightFactor: 1,
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
                    crossAxisAlignment: CrossAxisAlignment.start,
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
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s4,
                0,
                AppSpacing.s4,
                AppSpacing.s2,
              ),
              child: Text(
                widget.controller.syncError!,
                style: AppTextStyles.caption.copyWith(color: AppColors.alarm),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OverviewBanner(entries: active, config: cfg),
                if (danger.isNotEmpty)
                  _DangerAlertBar(entries: danger, config: cfg),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Expanded(
            child: active.isEmpty
                ? _EmptyBoard(
                    onGoVoice: requiresIncident
                        ? widget.controller.requestIncidentSelection
                        : widget.onGoVoice,
                    requiresIncident: requiresIncident,
                  )
                : RefreshIndicator(
                    onRefresh: _onRefresh,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      // 中央语音按钮向内容区悬浮，保留足够尾部空间，
                      // 确保最后一张人员卡片可完整滚动到按钮上方。
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.s4,
                        0,
                        AppSpacing.s4,
                        100,
                      ),
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
        SnackBar(
          content: Text(
            '同步失败，当前使用本地数据',
            style: TextStyle(color: AppColors.textPrimary),
          ),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
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

    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      radius: AppRadius.lg,
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
        const SizedBox(height: AppSpacing.s1),
        FittedBox(
          child: Text(
            value,
            style: AppTextStyles.h2.copyWith(
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: color,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textSecondary,
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
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s2),
      child: AppCard(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        radius: AppRadius.md,
        color: color.withValues(alpha: 0.12),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: color,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.s2),
            Expanded(
              child: Text(
                '${entries.length} 人需要关注 · 最早到期 ${_fmtRemaining(earliest.remainingMs)}',
                style: AppTextStyles.label.copyWith(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyBoard extends StatelessWidget {
  final VoidCallback? onGoVoice;
  final bool requiresIncident;

  const _EmptyBoard({this.onGoVoice, this.requiresIncident = false});

  @override
  Widget build(BuildContext context) {
    final voiceGuide = onGoVoice == null
        ? null
        : [
            const SizedBox(height: AppSpacing.s4),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: onGoVoice,
                icon: requiresIncident
                    ? const Icon(Icons.add_circle_outline)
                    : const Icon(Icons.mic_rounded),
                label: Text(requiresIncident ? '选择或新建警情' : '去警情处置'),
              ),
            ),
          ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s6,
          AppSpacing.s4,
          AppSpacing.s6,
          AppSpacing.s8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              label: '当前在场人员 0 人',
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '0',
                      style: AppTextStyles.h2.copyWith(
                        height: 1.0,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s1),
                    Text(
                      '在场',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              '暂无人员在场',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              requiresIncident ? '选择警情后可登记进场' : '按住底部语音按钮登记进场',
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textTertiary,
              ),
            ),
            ...?voiceGuide,
          ],
        ),
      ),
    );
  }
}

/// 人员状态卡片：状态靠色块（左侧色条 + 状态胶囊），数据靠排版（白底大字号对比）
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
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    // 320dp 真机上姓名、状态和更新压力可以自然同排；只在更窄视口或
    // 大字号下确实需要保留可读性时堆叠，不能把正常状态拉成整行。
    final stackedHeader =
        MediaQuery.sizeOf(context).width < 300 || textScale > 1.25;
    final statusAndAction = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s2,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        StatusBadge(
          status: status,
          onColorCard: false,
          fontSize: 13,
          height: 48,
        ),
        _UpdatePressureButton(onPressed: onReport),
      ],
    );
    final nameWithBar = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            color: s.color,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Text(
            e.name,
            maxLines: stackedHeader ? 2 : 1,
            softWrap: stackedHeader,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.h2.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );

    final card = AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      radius: AppRadius.lg,
      color: AppColors.surface,
      side: BorderSide(
        color: status == 'normal'
            ? AppColors.border
            : s.color.withValues(alpha: s.danger ? 0.65 : 0.45),
        width: s.danger ? 1.5 : 1.0,
      ),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stackedHeader) ...[
            nameWithBar,
            const SizedBox(height: AppSpacing.s1),
            Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              heightFactor: 1,
              child: statusAndAction,
            ),
          ] else
            Row(
              children: [
                Expanded(child: nameWithBar),
                const SizedBox(width: AppSpacing.s2),
                statusAndAction,
              ],
            ),
          const SizedBox(height: AppSpacing.s2),
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
                        color: status == 'normal'
                            ? AppColors.textPrimary
                            : s.color,
                        size: 44,
                        timeoutText: '已超时',
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.s1),
                        child: Text(
                          '剩余时间',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Container(
                width: 1,
                height: 28,
                color: AppColors.border,
              ),
              const SizedBox(width: AppSpacing.s3),
              // 持续时长：进入现场内部时长，次指标靠右
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.s1),
                        child: Text(
                          '持续时长',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Text(
                        _elapsedTime(e),
                        style: AppTextStyles.h2.copyWith(
                          fontSize: 26,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                          color: AppColors.textPrimary,
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
    );

    final wrapped = s.danger ? PulseGlow(color: s.color, child: card) : card;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
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

/// 卡片顶行的快速更新压力按钮：至少 48px 触控区，紧凑胶囊，独立响应点击
class _UpdatePressureButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _UpdatePressureButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onPressed,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
              decoration: BoxDecoration(
                color: AppColors.surfaceSubtle,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed, size: 16, color: AppColors.textPrimary),
                  const SizedBox(width: AppSpacing.s1),
                  Text(
                    '更新压力',
                    style: AppTextStyles.label.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
