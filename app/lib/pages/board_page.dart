import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';

/// 看板仪表盘：在场人员 + 倒计时 + 状态分级
class BoardPage extends StatefulWidget {
  final AppController controller;
  const BoardPage({super.key, required this.controller});

  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  @override
  Widget build(BuildContext context) {
    final active = widget.controller.entries.where((e) => e.isActive).toList()
      ..sort((a, b) => a.exitAt.compareTo(b.exitAt));
    final cfg = widget.controller.calcConfig;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Text('火场安全管控看板', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const Spacer(),
                Icon(Icons.local_fire_department, color: Colors.deepOrange.shade300),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _statChip('在场 ${active.length} 人', Colors.white70),
                const SizedBox(width: 8),
                _statChip('最早到期 ${_earliestText(active)}', Colors.amber),
                const Spacer(),
                if (widget.controller.syncing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: active.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.shield_outlined, size: 96, color: Colors.white12),
                        const SizedBox(height: 16),
                        Text('暂无人员在场', style: TextStyle(color: Colors.grey.shade500, fontSize: 18)),
                        const SizedBox(height: 8),
                        Text('切换到「语音录入」登记进入人员', style: TextStyle(color: Colors.grey.shade700, fontSize: 14)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: active.length,
                    itemBuilder: (context, i) => _EntryCard(
                      entry: active[i],
                      config: cfg,
                      onExit: () => _confirmExit(active[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2126),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 13)),
    );
  }

  String _earliestText(List<Entry> active) {
    if (active.isEmpty) return '--';
    final ms = active.first.remainingMs;
    if (ms <= 0) return '已超时!';
    final m = (ms / 60000).ceil();
    return '$m 分钟后';
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
            style: FilledButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认出火场'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.markExited(e.id);
      widget.controller.tts.speak('${e.name} 已登记出火场');
    }
  }
}

class _EntryCard extends StatefulWidget {
  final Entry entry;
  final CalcConfig config;
  final VoidCallback onExit;
  const _EntryCard({required this.entry, required this.config, required this.onExit});

  @override
  State<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends State<_EntryCard> {
  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final status = e.statusAt(warnMin: widget.config.warnMin, alarmMin: widget.config.alarmMin);
    final (Color color, String label) = switch (status) {
      'normal' => (const Color(0xFF2E7D32), '安全'),
      'warn' => (Colors.orange, '注意'),
      'alarm' => (Colors.redAccent, '报警'),
      _ => (Colors.red.shade900, '超时'),
    };

    final ms = e.remainingMs.clamp(0, 1 << 62);
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    final timeText = h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';

    final danger = status == 'alarm' || status == 'timeout';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: danger ? color.withValues(alpha: 0.18) : const Color(0xFF1E2126),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: danger ? color : Colors.white12, width: danger ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: widget.onExit,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(e.name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        if (e.pressureMpa != null)
                          Text('${e.pressureMpa}MPa', style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.timer_outlined, size: 14, color: color),
                        const SizedBox(width: 4),
                        Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 12),
                        Text(
                          '${e.durationMin}分钟上限',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      timeText,
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: danger ? Colors.white : Colors.amber,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text('剩余时间', style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.logout, color: Colors.grey.shade500, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
