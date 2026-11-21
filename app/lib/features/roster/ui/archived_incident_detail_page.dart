import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'archived_incident_cards.dart';

/// 已归档警情复盘详情页（Design System v3.0）。
///
/// 展示归档身份概要、未确认离场警示、参战力量快照与火场处置时间线，
/// 并通过注入的 [onOpenDetails] 跳转警情资料页，实现零跨 Feature 耦合。
class ArchivedIncidentDetailPage extends StatefulWidget {
  const ArchivedIncidentDetailPage({
    super.key,
    required this.incident,
    required this.gateway,
    this.onOpenDetails,
    this.isOffline = false,
  });

  final ArchivedIncidentView incident;
  final ArchivedIncidentsGateway gateway;
  final Future<void> Function(
    BuildContext context,
    ArchivedIncidentView incident,
  )?
  onOpenDetails;
  final bool isOffline;

  @override
  State<ArchivedIncidentDetailPage> createState() =>
      _ArchivedIncidentDetailPageState();
}

class _ArchivedIncidentDetailPageState
    extends State<ArchivedIncidentDetailPage> {
  List<ArchivedIncidentEventView> _events = const <ArchivedIncidentEventView>[];
  List<ArchivedIncidentForceView> _forces = const <ArchivedIncidentForceView>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final events = await widget.gateway.fetchTimeline(widget.incident.id);
      final forces = await widget.gateway.fetchForces(widget.incident.id);
      if (mounted) {
        setState(() {
          _events = events;
          _forces = forces;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取火场复盘失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(
        title: const Text('火场复盘'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const StatePlaceholder.loading(message: '正在加载火场复盘')
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  DsSpacing.pageMargin,
                  DsSpacing.md,
                  DsSpacing.pageMargin,
                  DsSpacing.xxl,
                ),
                children: <Widget>[
                  ArchivedIncidentIdentityCard(incident: widget.incident),
                  if (widget.onOpenDetails != null) ...<Widget>[
                    const SizedBox(height: DsSpacing.sm),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: CommandButton(
                        label: '警情资料与导入记录',
                        icon: Icons.description_outlined,
                        variant: CommandButtonVariant.ghost,
                        size: CommandButtonSize.standard,
                        onPressed: () => unawaited(
                          widget.onOpenDetails!(context, widget.incident),
                        ),
                      ),
                    ),
                  ],
                  if (widget.incident.unresolvedActiveCount > 0) ...<Widget>[
                    const SizedBox(height: DsSpacing.md),
                    SurfaceCard(
                      accentStatus: DsStatus.caution,
                      backgroundColor: colors
                          .statusColors(DsStatus.caution)
                          .pillBg,
                      padding: const EdgeInsets.all(DsSpacing.md),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.warning_amber_rounded,
                            color: colors.cautionText,
                            size: DsSizes.iconMd,
                          ),
                          const SizedBox(width: DsSpacing.sm),
                          Expanded(
                            child: Text(
                              '归档时有 ${widget.incident.unresolvedActiveCount} 名人员未确认离场',
                              style: context.ds.typography.body.copyWith(
                                color: colors.cautionText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: DsSpacing.xl),
                  ArchivedSectionHeader(
                    icon: Icons.local_fire_department_outlined,
                    title: '参战力量快照',
                    trailing: '${_forces.length} 个站点',
                  ),
                  const SizedBox(height: DsSpacing.sm),
                  _ForceSnapshotCard(forces: _forces),
                  const SizedBox(height: DsSpacing.xl),
                  const ArchivedSectionHeader(
                    icon: Icons.timeline_rounded,
                    title: '火场处置时间线',
                  ),
                  const SizedBox(height: DsSpacing.sm),
                  _ArchivedTimelineCard(events: _events),
                ],
              ),
            ),
    );
  }
}

class _ForceSnapshotCard extends StatelessWidget {
  const _ForceSnapshotCard({required this.forces});

  final List<ArchivedIncidentForceView> forces;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: forces.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(DsSpacing.lg),
              child: Text(
                '未登记参战力量',
                style: typo.body.copyWith(color: colors.textTertiary),
              ),
            )
          : Column(
              children: <Widget>[
                for (var i = 0; i < forces.length; i++) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.lg,
                      vertical: DsSpacing.md,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: colors.surfaceMuted,
                            borderRadius: DsRadius.borderSm,
                          ),
                          child: Icon(
                            Icons.local_fire_department_outlined,
                            size: DsSizes.iconSm,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(width: DsSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                forces[i].stationName,
                                style: typo.body.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: DsSpacing.xs),
                              Wrap(
                                spacing: DsSpacing.md,
                                runSpacing: DsSpacing.xs,
                                children: <Widget>[
                                  Text(
                                    forces[i].vehicleLabel,
                                    style: typo.captionTabular.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    forces[i].personnelLabel,
                                    style: typo.captionTabular.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (i < forces.length - 1)
                    Divider(height: 1, indent: 60, color: colors.border),
                ],
              ],
            ),
    );
  }
}

class _ArchivedTimelineCard extends StatelessWidget {
  const _ArchivedTimelineCard({required this.events});

  final List<ArchivedIncidentEventView> events;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.lg,
        DsSpacing.lg,
        DsSpacing.sm,
      ),
      child: events.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(bottom: DsSpacing.sm),
              child: Text(
                '暂无事件记录',
                style: ds.typography.body.copyWith(color: colors.textTertiary),
              ),
            )
          : Column(
              children: <Widget>[
                for (var i = 0; i < events.length; i++)
                  _ArchivedTimelineRow(
                    event: events[i],
                    isLast: i == events.length - 1,
                  ),
              ],
            ),
    );
  }
}

class _ArchivedTimelineRow extends StatelessWidget {
  const _ArchivedTimelineRow({required this.event, required this.isLast});

  final ArchivedIncidentEventView event;
  final bool isLast;

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

  Color _accentColor(DsColors colors) => switch (event.type) {
    'entry' => colors.safeText,
    'exit' => colors.textSecondary,
    'pressure' => colors.cautionText,
    'incident_archived' => colors.textSecondary,
    _ => colors.brandText,
  };

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final accent = _accentColor(colors);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 32,
            child: Column(
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_icon, size: DsSizes.iconSm, color: accent),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(
                        vertical: DsSpacing.xs,
                      ),
                      color: colors.border,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: DsSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    formatArchiveTime(event.occurredAt, withSeconds: true),
                    style: typo.captionTabular.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    event.text,
                    style: typo.body.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if ((event.actorName?.isNotEmpty ?? false) ||
                      event.source == 'offline' ||
                      event.revisionOf != null) ...<Widget>[
                    const SizedBox(height: DsSpacing.xs),
                    Wrap(
                      spacing: DsSpacing.sm,
                      runSpacing: DsSpacing.xs,
                      children: <Widget>[
                        if (event.actorName?.isNotEmpty ?? false)
                          Text(
                            event.actorName!,
                            style: typo.caption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        if (event.source == 'offline')
                          Text(
                            '离线补传',
                            style: typo.caption.copyWith(
                              color: colors.cautionText,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (event.revisionOf != null)
                          Text(
                            '修订记录',
                            style: typo.caption.copyWith(
                              color: colors.textTertiary,
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
}
