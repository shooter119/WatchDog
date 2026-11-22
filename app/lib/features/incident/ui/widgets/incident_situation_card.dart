import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../../../services/settings.dart';
import '../../data/models/incident.dart';
import '../../data/models/incident_force.dart';
import 'incident_category_chip.dart';
import 'incident_category_style.dart';
import 'incident_situation_parts.dart';

typedef IncidentExpandedLoader = Future<bool?> Function(String incidentId);
typedef IncidentExpandedSaver =
    Future<void> Function(String incidentId, bool expanded);

/// 基于 DS v3.0 [IncidentHeader] 的警情态势卡。
///
/// 支持折叠记忆、新增在场人员自动收起、改名/退出/归档二次确认、
/// 力量汇总与行操作，以及通过 `keySiteSlot` 注入重点单位关联卡。
class IncidentSituationCard extends StatefulWidget {
  const IncidentSituationCard({
    super.key,
    required this.incident,
    this.forces = const <IncidentForce>[],
    this.hasActiveEntries = false,
    this.highestRiskStatus = DsStatus.neutral,
    this.highestRiskLabel,
    this.connectionState = DsConnectionState.online,
    this.pendingSyncCount = 0,
    this.showConnectionPill = true,
    this.onConnectionTap,
    this.initialExpanded,
    this.onExpandedChanged,
    this.loadExpanded,
    this.saveExpanded,
    this.onRename,
    this.onAddForce,
    this.onImportInfo,
    this.onAdjustIncident,
    this.onDetails,
    this.onEditForce,
    this.onRemoveForce,
    this.onArchive,
    this.onExit,
    this.keySiteSlot,
    this.now,
  });

  final Incident incident;
  final List<IncidentForce> forces;
  final bool hasActiveEntries, showConnectionPill;
  final DsStatus highestRiskStatus;
  final String? highestRiskLabel;
  final DsConnectionState connectionState;
  final int pendingSyncCount;
  final VoidCallback? onConnectionTap;
  final bool? initialExpanded;
  final ValueChanged<bool>? onExpandedChanged;
  final IncidentExpandedLoader? loadExpanded;
  final IncidentExpandedSaver? saveExpanded;
  final Future<void> Function(String newTitle)? onRename;
  final VoidCallback? onAddForce;
  final VoidCallback? onImportInfo;
  final VoidCallback? onAdjustIncident;
  final VoidCallback? onDetails;
  final ValueChanged<IncidentForce>? onEditForce;
  final ValueChanged<IncidentForce>? onRemoveForce;
  final Future<void> Function()? onArchive;
  final Future<void> Function()? onExit;
  final Widget? keySiteSlot;
  final DateTime? now;

  @override
  State<IncidentSituationCard> createState() => _IncidentSituationCardState();
}

class _IncidentSituationCardState extends State<IncidentSituationCard> {
  bool _expanded = false;
  bool _hadActiveEntries = false;
  int _restoreEpoch = 0;

  @override
  void initState() {
    super.initState();
    _hadActiveEntries = widget.hasActiveEntries;
    if (widget.initialExpanded != null) {
      _expanded = widget.initialExpanded!;
    } else {
      _scheduleRestore(widget.incident.id);
    }
  }

  @override
  void didUpdateWidget(covariant IncidentSituationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incident.id != widget.incident.id) {
      _expanded = widget.initialExpanded ?? false;
      _hadActiveEntries = widget.hasActiveEntries;
      if (widget.initialExpanded == null) {
        _scheduleRestore(widget.incident.id);
      }
      return;
    }
    if (!_hadActiveEntries && widget.hasActiveEntries) {
      _hadActiveEntries = true;
      if (_expanded) {
        _restoreEpoch++;
        _expanded = false;
        _persistExpanded(widget.incident.id, false);
        widget.onExpandedChanged?.call(false);
      }
    } else if (!widget.hasActiveEntries) {
      _hadActiveEntries = false;
    }
  }

  void _scheduleRestore(String incidentId) {
    final epoch = ++_restoreEpoch;
    final loader = widget.loadExpanded ?? Settings.incidentCardExpanded;
    unawaited(
      loader(incidentId).then((bool? saved) {
        if (!mounted ||
            widget.incident.id != incidentId ||
            _restoreEpoch != epoch ||
            saved == null) {
          return;
        }
        if (widget.hasActiveEntries && saved) return;
        if (_expanded != saved) setState(() => _expanded = saved);
      }),
    );
  }

  void _persistExpanded(String incidentId, bool expanded) {
    final saver = widget.saveExpanded ?? Settings.setIncidentCardExpanded;
    unawaited(saver(incidentId, expanded));
  }

  void _toggleExpanded() {
    final next = !_expanded;
    _restoreEpoch++;
    setState(() => _expanded = next);
    _persistExpanded(widget.incident.id, next);
    widget.onExpandedChanged?.call(next);
  }

  Future<void> _handleRename() async {
    if (widget.onRename == null) return;
    final nextTitle = await showIncidentRenameSheet(
      context,
      initialTitle: widget.incident.title ?? '',
    );
    if (nextTitle != null && mounted) await widget.onRename!(nextTitle);
  }

  Future<void> _handleExit() async {
    if (widget.onExit == null) return;
    if (await showIncidentExitConfirmSheet(context) && mounted) {
      await widget.onExit!();
    }
  }

  Future<void> _handleArchive() async {
    if (widget.onArchive == null) return;
    if (await showIncidentArchiveConfirmSheet(context) && mounted) {
      await widget.onArchive!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = IncidentCardViewModel.fromIncident(
      widget.incident,
      now: widget.now,
    );
    final compactForces = IncidentCardViewModel.formatCompactForces(
      widget.forces,
      dispatchSummary: widget.incident.info['dispatch_summary']?.toString(),
    );
    final showPendingForcePill =
        widget.forces.isEmpty && !data.isTerminalStatus;
    final riskLabel =
        widget.highestRiskLabel ??
        (data.officialStatus.isNotEmpty
            ? '状态 · ${data.officialStatus}'
            : (widget.hasActiveEntries ? '内攻在场' : '待命处置'));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        KeyedSubtree(
          key: const Key('toggle-incident-card'),
          child: IncidentHeader(
            incidentName: data.eventTitle,
            category: data.category,
            categoryLabel: data.rawCategoryPill.isNotEmpty
                ? data.rawCategoryPill
                : IncidentCategoryStyle.labelOf(data.category),
            categoryIcon: IncidentCategoryStyle.iconOf(data.category),
            elapsedText: data.timeText,
            highestRiskStatus: widget.highestRiskStatus,
            highestRiskLabel: riskLabel,
            connectionState: widget.connectionState,
            pendingSyncCount: widget.pendingSyncCount,
            showConnectionPill: widget.showConnectionPill,
            onTap: _toggleExpanded,
            onConnectionTap: widget.onConnectionTap,
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md, vertical: DsSpacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildSummaryControlBar(context, data, compactForces),
              if (_expanded)
                _buildExpandedDetails(
                  context,
                  data,
                  showPendingForcePill: showPendingForcePill,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryControlBar(
    BuildContext context,
    IncidentCardViewModel data,
    String compactForces,
  ) {
    final colors = context.ds.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: InkWell(
            key: const Key('incident-collapse-pill'),
            borderRadius: DsRadius.borderSm,
            onTap: _toggleExpanded,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: IncidentCollapsedLocationForces(
                      hasRealLocation: data.hasRealLocation,
                      locationText: data.locationText,
                      expanded: _expanded,
                      compactForces: compactForces,
                    ),
                  ),
                  Icon(
                    _expanded ? DsIcons.chevronUp : DsIcons.chevronDown,
                    size: DsSizes.iconMd,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
        IncidentMoreMenuButton(
          onRename: () => unawaited(_handleRename()),
          onExit: () => unawaited(_handleExit()),
          onArchive: () => unawaited(_handleArchive()),
        ),
      ],
    );
  }

  Widget _buildExpandedDetails(
    BuildContext context,
    IncidentCardViewModel data, {
    required bool showPendingForcePill,
  }) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return Column(
      key: const Key('incident-card-details'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Divider(height: DsSpacing.md, color: colors.border),
        Wrap(
          spacing: DsSpacing.xs,
          runSpacing: DsSpacing.xs,
          children: <Widget>[
            if (data.rawCategoryPill.isNotEmpty)
              IncidentCategoryChip(
                category: data.category,
                label: data.rawCategoryPill,
              ),
            if (data.officialStatus.isNotEmpty)
              StatusPill(
                status: DsStatus.neutral,
                icon: DsIcons.flag,
                label: '官方状态: ${data.officialStatus}',
              ),
            for (final tag in data.extraTags)
              StatusPill(
                status: DsStatus.neutral,
                icon: DsIcons.statusNeutral,
                label: tag,
              ),
            if (widget.forces.isNotEmpty)
              StatusPill(
                status: DsStatus.neutral,
                icon: DsIcons.roster,
                label: '${widget.forces.length}支队伍',
              )
            else if (showPendingForcePill)
              const StatusPill(
                status: DsStatus.caution,
                icon: DsIcons.hourglass,
                label: '力量待登记',
              ),
          ],
        ),
        if (data.extraNotes.isNotEmpty) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Text(
            data.extraNotes.join(' · '),
            style: typo.caption.copyWith(color: colors.textSecondary),
          ),
        ],
        const SizedBox(height: DsSpacing.md),
        IncidentActionStrip(
          onAddForce: widget.onAddForce,
          onImportInfo: widget.onImportInfo,
          onAdjustIncident: widget.onAdjustIncident,
        ),
        if (widget.keySiteSlot != null) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          widget.keySiteSlot!,
        ],
        if (widget.forces.isNotEmpty) ...<Widget>[
          const SizedBox(height: DsSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '参战力量',
                  style: typo.title.copyWith(color: colors.textPrimary),
                ),
              ),
              Text(
                '${widget.forces.length}支队伍',
                style: typo.captionTabular.copyWith(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          for (var i = 0; i < widget.forces.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: DsSpacing.sm),
            IncidentForceItemRow(
              force: widget.forces[i],
              onEdit: widget.onEditForce != null
                  ? () => widget.onEditForce!(widget.forces[i])
                  : null,
              onRemove: widget.onRemoveForce != null
                  ? () => widget.onRemoveForce!(widget.forces[i])
                  : null,
            ),
          ],
        ],
        const SizedBox(height: DsSpacing.sm),
        InkWell(
          key: const Key('open-incident-details'),
          borderRadius: DsRadius.borderSm,
          onTap: widget.onDetails,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '警情详情',
                    style: typo.body.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '查看档案',
                  style: typo.caption.copyWith(
                    color: colors.brandText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(
                  DsIcons.chevronRight,
                  size: DsSizes.iconMd,
                  color: colors.brandText,
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: colors.border),
        InkWell(
          key: const Key('collapse-incident-card-bottom'),
          borderRadius: DsRadius.borderSm,
          onTap: _toggleExpanded,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  DsIcons.chevronUp,
                  size: DsSizes.iconMd,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: DsSpacing.xs),
                Text(
                  '收起详情',
                  style: typo.caption.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
