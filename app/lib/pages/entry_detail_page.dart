import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 在场人员详情页：实时倒计时 + 气瓶信息 + 进出场记录 + 出场操作（规范 5.3）
class EntryDetailPage extends StatefulWidget {
  final AppController controller;
  final String entryId;

  const EntryDetailPage({super.key, required this.controller, required this.entryId});

  @override
  State<EntryDetailPage> createState() => _EntryDetailPageState();
}
class _EntryDetailPageState extends State<EntryDetailPage> {
  Entry? _find() {
    for (final e in widget.controller.entries) {
      if (e.id == widget.entryId) return e;
    }
    return null;
  }

  Future<void> _confirmExit(Entry e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认「${e.name}」已出火场？'),
        content: const Text('登记后将停止倒计时并取消提醒'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认出火场'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.controller.markExited(e.id);
    try {
      await widget.controller.addActionLog(
        names: [e.name],
        action: '出场',
        category: NoteCategory.withdraw,
        opId: 'manual-exit-note-${e.id}-${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已登记出场，但火场日志写入失败：$error')),
        );
      }
    }
    widget.controller.tts.speak('${e.name} 已登记出火场');
    if (mounted) Navigator.pop(context);
  }

  String _fmt(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final e = _find();
          final exited = e == null || !e.isActive;
          return SafeArea(
            child: Column(
              children: [
                _header(exited),
                Expanded(
                  child: exited
                      ? _goneView(e?.name)
                      : SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Column(
                            children: [
                              _statusBanner(e),
                              const SizedBox(height: 16),
                              _countdownCard(e),
                              const SizedBox(height: 16),
                              const SectionTitle(text: '气瓶与记录'),
                              _infoGrid(e),
                              if (e.rawText != null && e.rawText!.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                _transcriptCard(e.rawText!),
                              ],
                            ],
                          ),
                        ),
                ),
                if (!exited) _exitBar(e),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(bool exited) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => Navigator.pop(context),
          ),
          const Text('人员详情', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const Spacer(),
          Icon(
            exited ? Icons.logout : Icons.person_outline,
            color: exited ? AppColors.textTertiary : AppColors.actionPrimary,
            size: 22,
          ),
        ],
      ),
    );
  }

  /// 大面积状态色块 + 状态标签（规范 5.3 视觉规则）
  Widget _statusBanner(Entry e) {
    final status = e.statusAt(
      warnMin: widget.controller.calcConfig.warnMin,
      alarmMin: widget.controller.calcConfig.alarmMin,
    );
    final s = EntryStatus.of(status);

    final banner = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: s.color,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
        boxShadow: AppShadow.card,
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.fg.withValues(alpha: 0.16),
            ),
            child: Text(
              e.name.isNotEmpty ? e.name.characters.first : '?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: s.fg),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: s.fg),
                ),
                const SizedBox(height: 8),
                StatusBadge(status: status, onColorCard: true),
              ],
            ),
          ),
        ],
      ),
    );

    return s.danger ? PulseGlow(color: s.color, child: banner) : banner;
  }

  Widget _countdownCard(Entry e) {
    final status = e.statusAt(
      warnMin: widget.controller.calcConfig.warnMin,
      alarmMin: widget.controller.calcConfig.alarmMin,
    );
    final s = EntryStatus.of(status);
    final danger = s.danger;
    final countdownColor = danger ? s.color : AppColors.textPrimary;

    final totalMs = e.durationMin * 60000;
    final progress = totalMs > 0 ? (e.remainingMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return AppCard(
      radius: AppRadius.lg,
      child: Column(
        children: [
          SizedBox(
            width: 190,
            height: 190,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 190,
                  height: 190,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 10,
                    strokeCap: StrokeCap.round,
                    backgroundColor: AppColors.surfaceSubtle,
                    color: s.color,
                  ),
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CountdownText(
                      ms: e.remainingMs,
                      color: countdownColor,
                      size: 42,
                      timeoutText: '已超时',
                    ),
                    const SizedBox(height: 4),
                    const Text('剩余时间', style: TextStyle(color: AppColors.textTertiary, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(
                      '预计 ${_fmt(e.exitAt)} 到期',
                      style: TextStyle(
                        color: danger ? s.color : AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.timer_outlined, size: 14, color: s.color),
              const SizedBox(width: 5),
              Text('${e.durationMin} 分钟上限', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              const SizedBox(width: 16),
              if (e.pressureMpa != null) ...[
                Icon(Icons.speed, size: 14, color: s.color),
                const SizedBox(width: 5),
                Text('${e.pressureMpa} MPa', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoGrid(Entry e) {
    final cfg = widget.controller.calcConfig;
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              _infoTile(Icons.login, '进场时间', _fmt(e.entryAt)),
              _infoTile(Icons.logout, '预计出场', _fmt(e.exitAt)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _infoTile(Icons.speed, '气瓶压力', e.pressureMpa != null ? '${e.pressureMpa} MPa' : '--'),
              _infoTile(Icons.local_fire_department_outlined, '气瓶容量', '${cfg.cylinderVolL} L'),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _infoTile(Icons.water_drop_outlined, '消耗率', '${cfg.consumptionLpm} L/min'),
              _infoTile(
                Icons.local_fire_department_outlined,
                '实测消耗率',
                e.consumptionActualLpm != null ? '${e.consumptionActualLpm!.toStringAsFixed(1)} L/min' : '--',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _infoTile(Icons.timer_outlined, '分钟上限', '${e.durationMin} 分钟'),
              _infoTile(
                Icons.mic_none,
                '来源',
                e.source == 'voice' ? '语音录入' : '手动',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoTile(IconData icon, String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppColors.textTertiary),
              const SizedBox(width: 5),
              Text(label, style: const TextStyle(color: AppColors.textTertiary, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _transcriptCard(String raw) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, size: 15, color: AppColors.voice),
              const SizedBox(width: 6),
              const Text('原始语音转写', style: TextStyle(color: AppColors.textTertiary, fontSize: 12, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 8),
          Text(raw, style: const TextStyle(fontSize: 15, height: 1.4, color: AppColors.textPrimary)),
        ],
      ),
    );
  }

  Widget _goneView(String? name) {
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
            child: const Icon(Icons.logout, size: 42, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 20),
          Text(
            name == null ? '该记录已不存在' : '「$name」已出火场',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回看板'),
          ),
        ],
      ),
    );
  }

  Widget _exitBar(Entry e) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            onPressed: () => _confirmExit(e),
            icon: const Icon(Icons.logout),
            label: Text('确认「${e.name}」已出火场'),
          ),
        ),
      ),
    );
  }
}
