import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

String _archiveTime(int ms, {bool withSeconds = false}) {
  if (ms <= 0) return '-';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final minute = '${d.minute}'.padLeft(2, '0');
  final second = withSeconds ? ':${d.second}'.padLeft(3, '0') : '';
  return '${d.year}年${d.month}月${d.day}日 ${d.hour}:$minute$second';
}

String _archiveMethod(Incident incident) =>
    incident.autoArchived ? '自动归档' : '手动归档';

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
      if (mounted) {
        setState(() {
          _incidents = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取归档警情失败：$e')));
      }
    }
  }

  Future<void> _rename(Incident incident) async {
    final input = TextEditingController(text: incident.title ?? '');
    final value = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改警情名称'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: '留空则显示默认警情名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => input.dispose());
    } else {
      input.dispose();
    }
    if (value == null) return;
    try {
      final updated = await widget.controller.renameIncident(incident, value);
      if (mounted) {
        setState(() {
          _incidents = _incidents
              .map((item) => item.id == updated.id ? updated : item)
              .toList();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('修改名称失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('已归档警情'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: _ArchiveSummary(count: _incidents.length),
                    ),
                  ),
                  if (_incidents.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          '暂无归档警情',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
                      sliver: SliverList.separated(
                        itemCount: _incidents.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final incident = _incidents[index];
                          return _ArchivedIncidentCard(
                            incident: incident,
                            onRename: () => _rename(incident),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => IncidentDetailPage(
                                  controller: widget.controller,
                                  incident: incident,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ArchiveSummary extends StatelessWidget {
  final int count;

  const _ArchiveSummary({required this.count});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.voice.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: const Icon(
            Icons.inventory_2_outlined,
            color: AppColors.voice,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '处置档案库',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 3),
              Text(
                '按归档时间查看完整火场复盘',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$count',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 28,
                height: 1,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '份档案',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ArchivedIncidentCard extends StatelessWidget {
  final Incident incident;
  final VoidCallback onRename;
  final VoidCallback onTap;

  const _ArchivedIncidentCard({
    required this.incident,
    required this.onRename,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 8, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.local_fire_department_outlined,
                  size: 19,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      incident.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      incident.title == null
                          ? '默认名称 · ${incident.number}'
                          : incident.number,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '修改名称',
                onPressed: onRename,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 19),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textTertiary),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              _MetaTag(
                icon: Icons.event_outlined,
                text: _archiveTime(incident.archivedAt ?? 0),
              ),
              _MetaTag(
                icon: incident.autoArchived
                    ? Icons.schedule_outlined
                    : Icons.task_alt_outlined,
                text: _archiveMethod(incident),
                accent: incident.autoArchived
                    ? AppColors.caution
                    : AppColors.online,
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 9),
            child: Divider(height: 1),
          ),
          Row(
            children: [
              _StatItem(label: '参战站点', value: '${incident.forceStationCount}'),
              _StatItem(label: '车辆', value: '${incident.vehicleCount}'),
              _StatItem(label: '人员', value: '${incident.personnelCount}'),
              if (incident.unresolvedActiveCount > 0)
                _StatItem(
                  label: '未确认离场',
                  value: '${incident.unresolvedActiveCount}',
                  color: AppColors.caution,
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _MetaTag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? accent;

  const _MetaTag({required this.icon, required this.text, this.accent});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: (accent ?? AppColors.textSecondary).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: accent ?? AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: accent ?? AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatItem({
    required this.label,
    required this.value,
    this.color = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 18,
            height: 1,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
        ),
      ],
    ),
  );
}

class IncidentDetailPage extends StatefulWidget {
  final AppController controller;
  final Incident incident;

  const IncidentDetailPage({
    super.key,
    required this.controller,
    required this.incident,
  });

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
      final forces = await api.fetchIncidentForces(
        forIncidentId: widget.incident.id,
      );
      if (mounted) {
        setState(() {
          _events = events;
          _forces = forces;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取火场复盘失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('火场复盘'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
              children: [
                _IncidentIdentity(incident: widget.incident),
                if (widget.incident.unresolvedActiveCount > 0) ...[
                  const SizedBox(height: 10),
                  _UnresolvedBanner(
                    count: widget.incident.unresolvedActiveCount,
                  ),
                ],
                const SizedBox(height: 20),
                _DetailSectionTitle(
                  icon: Icons.local_fire_department_outlined,
                  title: '参战力量快照',
                  trailing: '${_forces.length} 个站点',
                ),
                const SizedBox(height: 8),
                _ForceSnapshot(forces: _forces),
                const SizedBox(height: 20),
                _DetailSectionTitle(
                  icon: Icons.timeline_rounded,
                  title: '火场处置时间线',
                  trailing: '晚 → 早',
                ),
                const SizedBox(height: 8),
                _TimelineCard(events: _events),
              ],
            ),
          ),
  );
}

class _IncidentIdentity extends StatelessWidget {
  final Incident incident;

  const _IncidentIdentity({required this.incident});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.voice.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Icon(
                Icons.fact_check_outlined,
                color: AppColors.voice,
                size: 19,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '归档档案',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _ArchiveMethodChip(incident: incident),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          incident.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 22,
            height: 1.2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          incident.number,
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            _ArchiveMetric(
              label: '归档时间',
              value: _archiveTime(incident.archivedAt ?? 0),
            ),
            _ArchiveMetric(
              label: '最后活动',
              value: _archiveTime(incident.lastActivityAt),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ArchiveMethodChip extends StatelessWidget {
  final Incident incident;

  const _ArchiveMethodChip({required this.incident});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: (incident.autoArchived ? AppColors.caution : AppColors.online)
          .withValues(alpha: .12),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          incident.autoArchived
              ? Icons.schedule_outlined
              : Icons.task_alt_outlined,
          size: 13,
          color: incident.autoArchived ? AppColors.caution : AppColors.online,
        ),
        const SizedBox(width: 4),
        Text(
          _archiveMethod(incident),
          style: TextStyle(
            color: incident.autoArchived ? AppColors.caution : AppColors.online,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _ArchiveMetric extends StatelessWidget {
  final String label;
  final String value;

  const _ArchiveMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _UnresolvedBanner extends StatelessWidget {
  final int count;

  const _UnresolvedBanner({required this.count});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    decoration: BoxDecoration(
      color: AppColors.caution.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: AppColors.caution.withValues(alpha: .35)),
    ),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_rounded, color: AppColors.caution),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '归档时有 $count 名人员未确认离场',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class _DetailSectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String trailing;

  const _DetailSectionTitle({
    required this.icon,
    required this.title,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: AppColors.voice),
      const SizedBox(width: 6),
      Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
      const Spacer(),
      Text(
        trailing,
        style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
      ),
    ],
  );
}

class _ForceSnapshot extends StatelessWidget {
  final List<IncidentForce> forces;

  const _ForceSnapshot({required this.forces});

  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: forces.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '未登记参战力量',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
            ),
          )
        : Column(
            children: [
              for (var i = 0; i < forces.length; i++) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSubtle,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: const Icon(
                          Icons.local_fire_department_outlined,
                          size: 17,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          forces[i].stationName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${forces[i].vehicleCount}车',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${forces[i].personnelCount}人',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (i < forces.length - 1) const Divider(height: 1, indent: 54),
              ],
            ],
          ),
  );
}

class _TimelineCard extends StatelessWidget {
  final List<IncidentEvent> events;

  const _TimelineCard({required this.events});

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
    child: events.isEmpty
        ? const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '暂无事件记录',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
            ),
          )
        : Column(
            children: [
              for (var i = 0; i < events.length; i++)
                _TimelineEvent(
                  event: events[i],
                  isLast: i == events.length - 1,
                ),
            ],
          ),
  );
}

class _TimelineEvent extends StatelessWidget {
  final IncidentEvent event;
  final bool isLast;

  const _TimelineEvent({required this.event, required this.isLast});

  IconData get _icon => switch (event.type) {
    'entry' => Icons.login_rounded,
    'exit' => Icons.logout_rounded,
    'pressure' => Icons.speed_rounded,
    'force_added' ||
    'force_updated' ||
    'force_removed' => Icons.local_fire_department_outlined,
    'incident_archived' => Icons.archive_outlined,
    _ => Icons.edit_note_rounded,
  };

  Color get _color => switch (event.type) {
    'entry' => AppColors.online,
    'exit' => AppColors.voice,
    'pressure' => AppColors.caution,
    'incident_archived' => AppColors.textSecondary,
    _ => AppColors.actionPrimary,
  };

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 30,
          child: Column(
            children: [
              Container(
                width: 25,
                height: 25,
                decoration: BoxDecoration(
                  color: _color.withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: Icon(_icon, size: 14, color: _color),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: AppColors.border,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _archiveTime(event.occurredAt, withSeconds: true),
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  event.text,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    if (event.actorName?.isNotEmpty == true)
                      Text(
                        event.actorName!,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    if (event.source == 'offline')
                      const Text(
                        '离线补传',
                        style: TextStyle(
                          color: AppColors.caution,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    if (event.revisionOf != null)
                      const Text(
                        '修订记录',
                        style: TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
