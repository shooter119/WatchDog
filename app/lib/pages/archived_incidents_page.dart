import 'package:flutter/material.dart';

import '../models/models.dart';
import 'incident_details_page.dart';
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
      backgroundColor: AppColors.background,
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
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.s4,
                        AppSpacing.s3,
                        AppSpacing.s4,
                        0,
                      ),
                      child: _ArchiveSummary(count: _incidents.length),
                    ),
                  ),
                  if (_incidents.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          '暂无归档警情',
                          style: AppTextStyles.bodyMd.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.s4,
                        AppSpacing.s3,
                        AppSpacing.s4,
                        100,
                      ),
                      sliver: SliverList.separated(
                        itemCount: _incidents.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppSpacing.s3),
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
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s4,
      vertical: AppSpacing.s3,
    ),
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.voice.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(
            Icons.inventory_2_outlined,
            color: AppColors.voice,
            size: 22,
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Text(
            '处置档案库',
            style: AppTextStyles.h2.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$count',
              style: AppTextStyles.h1.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              '份档案',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textTertiary,
              ),
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
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s3,
        AppSpacing.s2,
        AppSpacing.s3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  Icons.local_fire_department_outlined,
                  size: 20,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      incident.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyLg.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s1),
                    Text(
                      incident.title == null
                          ? '默认名称 · ${incident.number}'
                          : incident.number,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textTertiary,
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
              Icon(Icons.chevron_right, color: AppColors.textTertiary),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s1,
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
            padding: EdgeInsets.symmetric(vertical: AppSpacing.s3),
            child: Divider(height: 1),
          ),
          Row(
            children: [
              _StatItem(label: '参战站点', value: '${incident.forceStationCount}'),
              _StatItem(
                label: incident.unknownVehicleStationCount > 0 ? '已知车辆' : '车辆',
                value:
                    '${incident.vehicleCount}${incident.unknownVehicleStationCount > 0 ? '+' : ''}',
              ),
              _StatItem(
                label: incident.unknownPersonnelStationCount > 0
                    ? '已知人员'
                    : '人员',
                value:
                    '${incident.personnelCount}${incident.unknownPersonnelStationCount > 0 ? '+' : ''}',
              ),
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
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s2,
      vertical: AppSpacing.s1,
    ),
    decoration: BoxDecoration(
      color: (accent ?? AppColors.textSecondary).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: accent ?? AppColors.textSecondary),
        const SizedBox(width: AppSpacing.s1),
        Text(
          text,
          style: AppTextStyles.caption.copyWith(
            color: accent ?? AppColors.textSecondary,
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
  final Color? color;

  const _StatItem({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: AppTextStyles.h2.copyWith(
            color: color ?? AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textTertiary,
          ),
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
    backgroundColor: AppColors.background,
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
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s4,
                AppSpacing.s3,
                AppSpacing.s4,
                100,
              ),
              children: [
                _IncidentIdentity(incident: widget.incident),
                const SizedBox(height: AppSpacing.s1),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: widget.controller.api == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => IncidentDetailsPage(
                                controller: widget.controller,
                                api: widget.controller.api!,
                                incident: widget.incident,
                              ),
                            ),
                          ),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s3,
                      ),
                      textStyle: AppTextStyles.label.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('警情资料与导入记录'),
                  ),
                ),
                if (widget.incident.unresolvedActiveCount > 0) ...[
                  const SizedBox(height: AppSpacing.s2),
                  _UnresolvedBanner(
                    count: widget.incident.unresolvedActiveCount,
                  ),
                ],
                const SizedBox(height: 22),
                _DetailSectionTitle(
                  icon: Icons.local_fire_department_outlined,
                  title: '参战力量快照',
                  trailing: '${_forces.length} 个站点',
                ),
                const SizedBox(height: AppSpacing.s2),
                _ForceSnapshot(forces: _forces),
                const SizedBox(height: 22),
                _DetailSectionTitle(
                  icon: Icons.timeline_rounded,
                  title: '火场处置时间线',
                ),
                const SizedBox(height: AppSpacing.s2),
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
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.all(AppSpacing.s4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.voice.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(
                Icons.fact_check_outlined,
                color: AppColors.voice,
                size: 20,
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Text(
                '归档档案',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _ArchiveMethodChip(incident: incident),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        Text(
          incident.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.h2.copyWith(
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          incident.number,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textTertiary,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Divider(height: 1),
        ),
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
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s2,
      vertical: AppSpacing.s1,
    ),
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
          size: 14,
          color: incident.autoArchived ? AppColors.caution : AppColors.online,
        ),
        const SizedBox(width: AppSpacing.s1),
        Text(
          _archiveMethod(incident),
          style: AppTextStyles.caption.copyWith(
            color: incident.autoArchived ? AppColors.caution : AppColors.online,
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
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.label.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
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
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s3,
      vertical: AppSpacing.s3,
    ),
    decoration: BoxDecoration(
      color: AppColors.caution.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: AppColors.caution.withValues(alpha: .35)),
    ),
    child: Row(
      children: [
        Icon(Icons.warning_amber_rounded, color: AppColors.caution, size: 20),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Text(
            '归档时有 $count 名人员未确认离场',
            style: AppTextStyles.label.copyWith(
              color: AppColors.textPrimary,
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
  final String? trailing;

  const _DetailSectionTitle({
    required this.icon,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: AppColors.voice),
      const SizedBox(width: AppSpacing.s2),
      Text(
        title,
        style: AppTextStyles.bodyLg.copyWith(
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        ),
      ),
      if (trailing != null) ...[
        const Spacer(),
        Text(
          trailing!,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textTertiary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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
        ? Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Text(
              '未登记参战力量',
              style: AppTextStyles.label.copyWith(
                color: AppColors.textTertiary,
              ),
            ),
          )
        : Column(
            children: [
              for (var i = 0; i < forces.length; i++) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4,
                    vertical: AppSpacing.s3,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 32),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceSubtle,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Icon(
                            Icons.local_fire_department_outlined,
                            size: 18,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: Text(
                            forces[i].stationName,
                            style: AppTextStyles.bodyMd.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          forces[i].vehicleLabel,
                          style: AppTextStyles.label.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Text(
                          forces[i].personnelLabel,
                          style: AppTextStyles.label.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (i < forces.length - 1) const Divider(height: 1, indent: 60),
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
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.s4,
      AppSpacing.s4,
      AppSpacing.s4,
      AppSpacing.s2,
    ),
    child: events.isEmpty
        ? Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: Text(
              '暂无事件记录',
              style: AppTextStyles.label.copyWith(
                color: AppColors.textTertiary,
              ),
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
          width: 32,
          child: Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _color.withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: Icon(_icon, size: 15, color: _color),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
                    color: AppColors.border,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _archiveTime(event.occurredAt, withSeconds: true),
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: AppSpacing.s1),
                Text(
                  event.text,
                  style: AppTextStyles.bodyMd.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (event.actorName?.isNotEmpty == true ||
                    event.source == 'offline' ||
                    event.revisionOf != null) ...[
                  const SizedBox(height: AppSpacing.s1),
                  Wrap(
                    spacing: AppSpacing.s2,
                    children: [
                      if (event.actorName?.isNotEmpty == true)
                        Text(
                          event.actorName!,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      if (event.source == 'offline')
                        Text(
                          '离线补传',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.caution,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (event.revisionOf != null)
                        Text(
                          '修订记录',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
