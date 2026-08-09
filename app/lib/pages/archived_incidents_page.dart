import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

class ArchivedIncidentsPage extends StatefulWidget {
  final AppController controller;
  const ArchivedIncidentsPage({super.key, required this.controller});

  @override
  State<ArchivedIncidentsPage> createState() => _ArchivedIncidentsPageState();
}

class _ArchivedIncidentsPageState extends State<ArchivedIncidentsPage> {
  List<Incident> _incidents = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.controller.archivedIncidents();
      if (mounted) setState(() { _incidents = items; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取归档警情失败：$e')));
    }
  }

  Future<void> _rename(Incident incident) async {
    final input = TextEditingController(text: incident.title ?? '');
    final value = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改警情名称'),
        content: TextField(controller: input, autofocus: true, maxLength: 120, decoration: const InputDecoration(hintText: '留空则显示警情编号')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(ctx, input.text.trim()), child: const Text('保存'))],
      ),
    );
    input.dispose();
    if (value == null) return;
    try {
      final updated = await widget.controller.renameIncident(incident, value);
      if (mounted) setState(() => _incidents = _incidents.map((e) => e.id == updated.id ? updated : e).toList());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('修改名称失败：$e')));
    }
  }

  String _time(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month}-${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('已归档警情')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: _incidents.isEmpty
                    ? ListView(children: const [SizedBox(height: 180), Center(child: Text('暂无归档警情', style: TextStyle(color: AppColors.textSecondary)))])
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _incidents.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final incident = _incidents[index];
                          return Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                              title: Text(incident.displayName, style: const TextStyle(fontWeight: FontWeight.w800)),
                              subtitle: Text('${incident.number}\n归档：${_time(incident.archivedAt ?? 0)} · ${incident.autoArchived ? '自动归档' : '手动归档'}\n${incident.forceStationCount}个站 · ${incident.vehicleCount}车 · ${incident.personnelCount}人'),
                              isThreeLine: true,
                              trailing: IconButton(tooltip: '修改名称', onPressed: () => _rename(incident), icon: const Icon(Icons.edit_outlined)),
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => IncidentDetailPage(controller: widget.controller, incident: incident))),
                            ),
                          );
                        },
                      ),
              ),
      );
}

class IncidentDetailPage extends StatefulWidget {
  final AppController controller;
  final Incident incident;
  const IncidentDetailPage({super.key, required this.controller, required this.incident});

  @override
  State<IncidentDetailPage> createState() => _IncidentDetailPageState();
}

class _IncidentDetailPageState extends State<IncidentDetailPage> {
  List<IncidentEvent> _events = [];
  List<IncidentForce> _forces = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = widget.controller.api;
      if (api == null) throw StateError('未连接服务器');
      final events = await api.fetchTimeline(widget.incident.id);
      final forces = await api.fetchIncidentForces(forIncidentId: widget.incident.id);
      if (mounted) setState(() { _events = events; _forces = forces; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取火场复盘失败：$e')));
    }
  }

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}-${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('警情详情 / 火场复盘')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(widget.incident.displayName, style: AppTextStyles.h2),
                    const SizedBox(height: 4),
                    Text('${widget.incident.number} · ${widget.incident.autoArchived ? '自动归档' : '手动归档'}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    if (widget.incident.unresolvedActiveCount > 0) ...[
                      const SizedBox(height: 12),
                      Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: AppColors.caution.withValues(alpha: .12), borderRadius: BorderRadius.circular(AppRadius.md)), child: Text('归档时有 ${widget.incident.unresolvedActiveCount} 名人员未确认离场', style: const TextStyle(color: AppColors.caution, fontWeight: FontWeight.w700))),
                    ],
                    const SizedBox(height: 20),
                    const Text('参战力量快照', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    if (_forces.isEmpty) const Text('未登记参战力量', style: TextStyle(color: AppColors.textTertiary)) else ...[
                      for (final f in _forces) ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: const Icon(Icons.local_fire_department_outlined), title: Text(f.stationName), trailing: Text('${f.vehicleCount}车${f.personnelCount}人')),
                    ],
                    const SizedBox(height: 20),
                    const Text('火场日志（晚 → 早）', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    if (_events.isEmpty) const Text('暂无事件', style: TextStyle(color: AppColors.textTertiary)) else ...[
                      for (final event in _events)
                        ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: Text(_time(event.occurredAt), style: const TextStyle(fontSize: 11, color: AppColors.textTertiary)), title: Text(event.text), subtitle: Text([if (event.actorName?.isNotEmpty == true) event.actorName!, if (event.source == 'offline') '离线补传'].join(' · '), style: const TextStyle(fontSize: 11))),
                    ],
                  ],
                ),
              ),
      );
}
