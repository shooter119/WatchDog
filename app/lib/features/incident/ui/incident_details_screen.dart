import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/phone_caller.dart';
import '../data/incident_import_repository.dart';
import '../data/models/incident.dart';
import 'sheets/incident_basic_info_sheet.dart';
import 'sheets/incident_details_edit_sheet.dart';
import 'widgets/incident_detail_blocks.dart';
import 'widgets/incident_situation_parts.dart';

/// 警情详细资料页面（Design System v3.0）。
///
/// 完整保留基础字段、号码校验与点击直拨、导入历史、现场录像语音记录、
/// 注入式重点单位卡槽位（零跨 Feature 依赖）以及活动警情的退出/归档二次确认。
class IncidentDetailsScreen extends StatefulWidget {
  const IncidentDetailsScreen({
    super.key,
    required this.incident,
    this.importRepository,
    this.onLocateAddress,
    this.keySiteSlot,
    this.onExitIncident,
    this.onArchiveIncident,
    this.onDetailsUpdated,
    this.phoneLauncher,
  });

  final Incident incident;
  final IncidentImportRepository? importRepository;
  final IncidentAddressLocator? onLocateAddress;
  final Widget? keySiteSlot;
  final Future<void> Function()? onExitIncident;
  final Future<void> Function()? onArchiveIncident;
  final VoidCallback? onDetailsUpdated;
  final PhoneLauncher? phoneLauncher;

  @override
  State<IncidentDetailsScreen> createState() => _IncidentDetailsScreenState();
}

class _IncidentDetailsScreenState extends State<IncidentDetailsScreen> {
  Map<String, dynamic>? _detail;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = widget.importRepository;
    if (repo == null) {
      setState(() {
        _detail = <String, dynamic>{
          'data': Map<String, dynamic>.from(widget.incident.info),
          'version': 0,
          'imports': const <dynamic>[],
          'observations': const <dynamic>[],
        };
        _error = null;
      });
      return;
    }
    try {
      final value = await repo.fetchIncidentDetails();
      if (!mounted) return;
      setState(() {
        _detail = value;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _dialPhone(String rawPhone) async {
    final normalized = PhoneCaller.normalizePhone(rawPhone);
    if (!PhoneCaller.isValidPhoneNumber(normalized)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('号码已脱敏或格式无效，无法拨打')),
        );
      }
      return;
    }
    await PhoneCaller.dial(
      context,
      normalized,
      launcher: widget.phoneLauncher,
    );
  }

  Future<void> _edit() async {
    final repo = widget.importRepository;
    if (_busy || repo == null || _detail == null) return;
    final data = Map<String, dynamic>.from(_detail?['data'] as Map? ?? const {});
    final updated = await showIncidentDetailsEditSheet(
      context,
      initialData: data,
      onLocateAddress: widget.onLocateAddress,
    );
    if (updated == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await repo.updateIncidentDetails(
        updated,
        (_detail?['version'] as num?)?.toInt() ?? 0,
        'details-${DateTime.now().microsecondsSinceEpoch}',
      );
      await _load();
      widget.onDetailsUpdated?.call();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmExit() async {
    final onExit = widget.onExitIncident;
    if (onExit == null || _busy) return;
    if (!await showIncidentExitConfirmSheet(context) || !mounted) return;
    setState(() => _busy = true);
    try {
      await onExit();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('退出警情失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmArchive() async {
    final onArchive = widget.onArchiveIncident;
    if (onArchive == null || _busy) return;
    if (!await showIncidentArchiveConfirmSheet(context) || !mounted) return;
    setState(() => _busy = true);
    try {
      await onArchive();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('归档失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatObsTime(dynamic raw) {
    final ms = (raw as num?)?.toInt();
    if (ms == null || ms == 0) return '录像语音';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)} · 录像语音';
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final data = Map<String, dynamic>.from(_detail?['data'] as Map? ?? const {});
    final contacts = _detail == null
        ? const <dynamic>[]
        : (data['contacts'] as List? ?? const <dynamic>[]);
    final observations = _detail?['observations'] as List? ?? const <dynamic>[];
    final imports = _detail?['imports'] as List? ?? const <dynamic>[];
    final basicFields = <MapEntry<String, String>>[
      for (final field in incidentDetailFieldLabels.entries)
        if (data[field.key]?.toString().trim().isNotEmpty == true) field,
    ];

    return CommandScaffold(
      isOffline: _detail?['offline'] == true,
      offlineMessage: '当前显示本机缓存，联网后刷新可获取最新资料。',
      appBar: AppBar(
        title: Text(
          '警情详情',
          style: typo.headline.copyWith(color: colors.textPrimary),
        ),
        actions: <Widget>[
          if (widget.incident.isActive && widget.importRepository != null)
            IconButton(
              key: const Key('incident-details-edit-btn'),
              tooltip: '编辑警情资料',
              constraints: const BoxConstraints(
                minWidth: DsSizes.touchTarget,
                minHeight: DsSizes.touchTarget,
              ),
              onPressed: _busy || _detail == null ? null : _edit,
              icon: const Icon(DsIcons.edit),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(DsSpacing.pageMargin),
        children: <Widget>[
          if (widget.keySiteSlot != null) ...<Widget>[
            widget.keySiteSlot!,
            const SizedBox(height: DsSpacing.md),
          ],
          Text(
            widget.incident.displayName,
            style: typo.headline.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.md),
          if (_error != null) ...<Widget>[
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              backgroundColor: colors.statusColors(DsStatus.alarm).pillBg,
              borderColor: colors.alarmFill.withValues(alpha: 0.35),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _error!,
                      style: typo.caption.copyWith(color: colors.alarmText),
                    ),
                  ),
                  CommandButton(
                    label: '重试',
                    variant: CommandButtonVariant.ghost,
                    size: CommandButtonSize.standard,
                    onPressed: _load,
                  ),
                ],
              ),
            ),
            const SizedBox(height: DsSpacing.md),
          ],
          if (_detail == null && _error == null)
            const StatePlaceholder.loading(message: '正在加载警情资料…'),
          if (_detail != null) ...<Widget>[
            if (basicFields.isEmpty &&
                contacts.isEmpty &&
                observations.isEmpty &&
                imports.isEmpty)
              StatePlaceholder.empty(
                icon: DsIcons.toolTacticalBrief,
                message: widget.importRepository == null
                    ? '当前处于单机模式，暂未连接云端详情接口。'
                    : (widget.incident.isActive
                          ? '尚未补充警情资料，可手动填写或从指挥台导入图片/文字。'
                          : '暂无警情补充资料'),
                actionLabel:
                    widget.incident.isActive && widget.importRepository != null
                    ? '手动填写资料'
                    : null,
                onAction:
                    widget.incident.isActive && widget.importRepository != null
                    ? _edit
                    : null,
              ),
            if (basicFields.isNotEmpty)
              SurfaceCard(
                level: DsSurfaceLevel.outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (var i = 0; i < basicFields.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(height: DsSpacing.md),
                      IncidentDetailFieldBlock(
                        label: basicFields[i].value,
                        value: data[basicFields[i].key].toString(),
                        phoneLauncher: widget.phoneLauncher,
                      ),
                    ],
                  ],
                ),
              ),
            if (contacts.isNotEmpty) ...<Widget>[
              const SizedBox(height: DsSpacing.lg),
              Text(
                '岗位人员与联系方式',
                style: typo.title.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: DsSpacing.sm),
              SurfaceCard(
                level: DsSurfaceLevel.outlined,
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.md,
                  vertical: DsSpacing.xs,
                ),
                child: Column(
                  children: <Widget>[
                    for (var i = 0; i < contacts.length; i++) ...<Widget>[
                      if (i > 0) Divider(height: 1, color: colors.border),
                      IncidentContactItemRow(
                        key: ValueKey<String>('incident-contact-$i'),
                        role: (contacts[i] as Map)['role']?.toString() ?? '',
                        name: (contacts[i] as Map)['name']?.toString() ?? '',
                        phone: (contacts[i] as Map)['phone']?.toString() ?? '',
                        onCall: _dialPhone,
                      ),
                    ],
                  ],
                ),
              ),
            ],
            for (final section in const <MapEntry<String, String>>[
              MapEntry<String, String>('risks', '风险信息'),
              MapEntry<String, String>('to_confirm', '待核实事项'),
              MapEntry<String, String>('vehicles', '车辆明细'),
              MapEntry<String, String>('equipment', '通信装备'),
              MapEntry<String, String>('channels', '通信频道'),
            ])
              if ((data[section.key] as List? ?? const <dynamic>[]).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: DsSpacing.md),
                  child: IncidentExpandableListCard(
                    title: section.value,
                    items: (data[section.key] as List)
                        .map((dynamic e) => e.toString())
                        .toList(),
                  ),
                ),
            if (observations.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: DsSpacing.md),
                child: IncidentExpandableListCard(
                  title: '录像语音记录 (${observations.length})',
                  selectable: true,
                  items: <String>[
                    for (final obs in observations)
                      '${_formatObsTime((obs as Map)['captured_at'])}\n'
                          '${obs['transcript'] ?? ''}',
                  ],
                ),
              ),
            for (final record in imports)
              Padding(
                padding: const EdgeInsets.only(top: DsSpacing.md),
                child: IncidentExpandableListCard(
                  title: (record as Map)['source'] == 'images'
                      ? '图片导入记录'
                      : '文字导入记录',
                  subtitle: '确认人：${record['actor_name'] ?? ''}',
                  selectable: true,
                  items: <String>[
                    for (final page in (record['pages'] as List? ?? const []))
                      '第${(page as Map)['index']}页\n${page['raw_text'] ?? ''}',
                  ],
                ),
              ),
          ],
          if (widget.incident.isActive &&
              (widget.onExitIncident != null ||
                  widget.onArchiveIncident != null)) ...<Widget>[
            const SizedBox(height: DsSpacing.xl),
            Text(
              '警情操作',
              style: typo.title.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: DsSpacing.sm),
            SurfaceCard(
              level: DsSurfaceLevel.outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (widget.onExitIncident != null)
                    CommandButton(
                      key: const Key('details-exit-incident'),
                      label: '退出当前警情',
                      icon: DsIcons.logout,
                      variant: CommandButtonVariant.secondary,
                      size: CommandButtonSize.standard,
                      expanded: true,
                      enabled: !_busy,
                      onPressed: _confirmExit,
                    ),
                  if (widget.onExitIncident != null &&
                      widget.onArchiveIncident != null)
                    const SizedBox(height: DsSpacing.sm),
                  if (widget.onArchiveIncident != null)
                    CommandButton(
                      key: const Key('details-archive-incident'),
                      label: '归档警情',
                      icon: DsIcons.archive,
                      variant: CommandButtonVariant.danger,
                      size: CommandButtonSize.standard,
                      expanded: true,
                      enabled: !_busy,
                      requireConfirmation: false,
                      onPressed: _confirmArchive,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
