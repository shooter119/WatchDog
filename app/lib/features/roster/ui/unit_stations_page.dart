import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/roster_repository.dart';

/// 单位常用队伍管理页（Design System v3.0）。
///
/// 通过同 Feature 内的 [RosterRepository] 读取和增改单位常用队伍列表，
/// 离线或权限接口异常时仍保留已缓存名录可读、管理编辑自动禁用。
class UnitStationsPage extends StatefulWidget {
  const UnitStationsPage({
    super.key,
    required this.repository,
    this.isOffline = false,
  });

  final RosterRepository repository;
  final bool isOffline;

  @override
  State<UnitStationsPage> createState() => _UnitStationsPageState();
}

class _UnitStationsPageState extends State<UnitStationsPage> {
  List<Map<String, dynamic>> _stations = const <Map<String, dynamic>>[];
  String? _error;
  bool _canManage = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final list = await widget.repository.fetchUnitStations(
        includeInactive: true,
      );
      Map<String, dynamic> access = const <String, dynamic>{};
      try {
        access = await widget.repository.unitStationAccess();
      } catch (_) {
        // 缓存名录在离线时仍可读，管理编辑保持禁用。
      }
      if (mounted) {
        setState(() {
          _stations = list;
          _canManage = access['can_manage'] == true;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? station]) async {
    final nameController = TextEditingController(
      text: station?['name']?.toString() ?? '',
    );
    final aliasesController = TextEditingController(
      text: (station?['aliases'] as List? ?? const <Object?>[]).join('\n'),
    );
    final activeNotifier = ValueNotifier<bool>(station?['active'] != false);
    final errorNotifier = ValueNotifier<String?>(null);

    final saved = await showCommandSheet<bool>(
      context: context,
      title: station == null ? '新增常用队伍' : '维护常用队伍',
      builder: (BuildContext sheetContext) => _StationFormBody(
        isEditing: station != null,
        nameController: nameController,
        aliasesController: aliasesController,
        activeNotifier: activeNotifier,
        errorNotifier: errorNotifier,
      ),
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () {
            if (nameController.text.trim().isEmpty) {
              errorNotifier.value = '请填写队伍名称';
              return;
            }
            Navigator.of(sheetContext).pop(true);
          },
        ),
      ],
    );

    if (saved == true && mounted) {
      try {
        if (station == null) {
          await widget.repository.addUnitStation(nameController.text.trim());
        } else {
          await widget.repository.updateUnitStation(station['id'].toString(), {
            'name': nameController.text.trim(),
            'aliases': aliasesController.text
                .split('\n')
                .map((item) => item.trim())
                .where((item) => item.isNotEmpty)
                .toList(),
            'active': activeNotifier.value,
            'expected_version': station['version'],
          });
        }
        await _load();
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
      aliasesController.dispose();
      activeNotifier.dispose();
      errorNotifier.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(
        title: const Text('单位常用队伍'),
        actions: <Widget>[
          IconButton(
            tooltip: '新增常用队伍',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: _busy ? null : () => _edit(),
            icon: const Icon(DsIcons.add, size: DsSizes.iconLg),
          ),
        ],
      ),
      body: RefreshIndicator(
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
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              borderColor: colors.border,
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.sm,
              ),
              child: Text(
                '仅管理员可编辑；修改不影响历史警情',
                style: typo.caption.copyWith(
                  color: colors.textSecondary,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: DsSpacing.md),
            if (_busy) ...<Widget>[
              LinearProgressIndicator(
                color: colors.brand,
                backgroundColor: colors.surfaceMuted,
              ),
              const SizedBox(height: DsSpacing.sm),
            ],
            if (_error != null) ...<Widget>[
              _StationErrorCard(error: _error!, onRetry: _load),
              const SizedBox(height: DsSpacing.sm),
            ],
            for (final station in _stations)
              Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                child: _StationRowCard(
                  station: station,
                  canManage: _canManage,
                  onTap: _canManage ? () => _edit(station) : null,
                ),
              ),
            if (!_busy && _stations.isEmpty)
              const StatePlaceholder.empty(
                icon: DsIcons.stations,
                message: '暂无常用队伍',
                detail: '可在此新增，也可导入警情时保存。',
              ),
          ],
        ),
      ),
    );
  }
}

class _StationFormBody extends StatelessWidget {
  const _StationFormBody({
    required this.isEditing,
    required this.nameController,
    required this.aliasesController,
    required this.activeNotifier,
    required this.errorNotifier,
  });

  final bool isEditing;
  final TextEditingController nameController;
  final TextEditingController aliasesController;
  final ValueNotifier<bool> activeNotifier;
  final ValueNotifier<String?> errorNotifier;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final alarmPair = colors.statusColors(DsStatus.alarm);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: nameController,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '队伍名称'),
        ),
        if (isEditing) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          TextField(
            controller: aliasesController,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '别名，每行一项',
              helperText: '仅填写确认属于同一队伍的简称',
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          ValueListenableBuilder<bool>(
            valueListenable: activeNotifier,
            builder: (BuildContext context, bool active, Widget? child) {
              return SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('可用于后续登记'),
                value: active,
                onChanged: (bool value) => activeNotifier.value = value,
              );
            },
          ),
        ],
        ValueListenableBuilder<String?>(
          valueListenable: errorNotifier,
          builder: (BuildContext context, String? error, Widget? child) {
            if (error == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: DsSpacing.sm),
              child: Text(
                error,
                style: context.ds.typography.caption.copyWith(
                  color: alarmPair.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _StationErrorCard extends StatelessWidget {
  const _StationErrorCard({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final alarmPair = ds.colors.statusColors(DsStatus.alarm);
    return SurfaceCard(
      accentStatus: DsStatus.alarm,
      backgroundColor: alarmPair.pillBg,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Row(
        children: <Widget>[
          Icon(
            DsIcons.warning,
            color: alarmPair.text,
            size: DsSizes.iconMd,
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              error,
              style: ds.typography.body.copyWith(color: alarmPair.text),
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          CommandButton(
            label: '重试',
            variant: CommandButtonVariant.ghost,
            size: CommandButtonSize.standard,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _StationRowCard extends StatelessWidget {
  const _StationRowCard({
    required this.station,
    required this.canManage,
    required this.onTap,
  });

  final Map<String, dynamic> station;
  final bool canManage;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final isInactive = station['active'] == false;
    final aliases = (station['aliases'] as List? ?? const <Object?>[])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();

    return SurfaceCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.md,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    station['name']?.toString() ?? '',
                    style: typo.title.copyWith(color: colors.textPrimary),
                  ),
                  if (isInactive || aliases.isNotEmpty) ...<Widget>[
                    const SizedBox(height: DsSpacing.xs),
                    Wrap(
                      spacing: DsSpacing.sm,
                      runSpacing: DsSpacing.xs,
                      children: <Widget>[
                        if (isInactive)
                          const StatusPill(
                            status: DsStatus.neutral,
                            icon: DsIcons.forbid,
                            label: '已停用',
                          ),
                        for (final alias in aliases)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: DsSpacing.sm,
                              vertical: DsSpacing.xs,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surfaceMuted,
                              borderRadius: DsRadius.borderPill,
                            ),
                            child: Text(
                              alias,
                              style: typo.caption.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (canManage) ...<Widget>[
              const SizedBox(width: DsSpacing.sm),
              Icon(
                DsIcons.edit,
                size: DsSizes.iconMd,
                color: colors.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
