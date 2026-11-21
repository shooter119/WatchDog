import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/incident_force.dart';

/// 参战力量新增/编辑结果。
@immutable
class IncidentForceEditResult {
  const IncidentForceEditResult({
    required this.stationName,
    required this.vehicleCount,
    required this.personnelCount,
    required this.vehicleCountKnown,
    required this.personnelCountKnown,
    required this.saveCommon,
  });

  final String stationName;
  final int vehicleCount;
  final int personnelCount;
  final bool vehicleCountKnown;
  final bool personnelCountKnown;
  final bool saveCommon;
}

/// 弹出基于 [CommandSheet] 的参战力量登记/编辑抽屉。
Future<IncidentForceEditResult?> showIncidentForceEditSheet(
  BuildContext context, {
  IncidentForce? force,
  List<String> stationNames = const <String>[],
}) {
  return showModalBottomSheet<IncidentForceEditResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext _) =>
        _IncidentForceEditSheet(force: force, stationNames: stationNames),
  );
}

/// 同名消防站力量冲突时的合并确认抽屉（不累加原数量，直接采用本次输入）。
Future<IncidentForce?> showIncidentForceMergeSheet(
  BuildContext context, {
  required IncidentForce source,
  required List<IncidentForce> candidates,
  required String targetName,
  required String vehiclesText,
  required String peopleText,
}) {
  if (candidates.isEmpty) return Future<IncidentForce?>.value(null);
  return showModalBottomSheet<IncidentForce>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext _) => _IncidentForceMergeSheet(
      source: source,
      candidates: candidates,
      targetName: targetName,
      vehiclesText: vehiclesText,
      peopleText: peopleText,
    ),
  );
}

class _IncidentForceEditSheet extends StatefulWidget {
  const _IncidentForceEditSheet({
    this.force,
    required this.stationNames,
  });

  final IncidentForce? force;
  final List<String> stationNames;

  @override
  State<_IncidentForceEditSheet> createState() =>
      _IncidentForceEditSheetState();
}

class _IncidentForceEditSheetState extends State<_IncidentForceEditSheet> {
  late final List<String> _names;
  late String _selected;
  late bool _custom;
  bool _saveCommon = false;
  String? _validationError;

  late final TextEditingController _customStationCtrl;
  late final TextEditingController _vehiclesCtrl;
  late final TextEditingController _peopleCtrl;

  @override
  void initState() {
    super.initState();
    final set = <String>{
      ...widget.stationNames.where((String s) => s.trim().isNotEmpty),
      if (widget.force != null && widget.force!.stationName.trim().isNotEmpty)
        widget.force!.stationName.trim(),
    };
    _names = set.toList();
    _selected = widget.force?.stationName ?? (_names.isEmpty ? '' : _names.first);
    _custom = _names.isEmpty || !_names.contains(_selected);
    _customStationCtrl = TextEditingController(
      text: _custom ? (widget.force?.stationName ?? '') : '',
    );
    _vehiclesCtrl = TextEditingController(
      text: widget.force != null && widget.force!.vehicleCountKnown
          ? '${widget.force!.vehicleCount}'
          : '',
    );
    _peopleCtrl = TextEditingController(
      text: widget.force != null && widget.force!.personnelCountKnown
          ? '${widget.force!.personnelCount}'
          : '',
    );
  }

  @override
  void dispose() {
    _customStationCtrl.dispose();
    _vehiclesCtrl.dispose();
    _peopleCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final stationName = _custom ? _customStationCtrl.text.trim() : _selected;
    if (stationName.isEmpty) {
      setState(() => _validationError = '请填写或选择消防站名称');
      return;
    }
    final rawVehicles = _vehiclesCtrl.text.trim();
    final rawPeople = _peopleCtrl.text.trim();
    final parsedVehicles = rawVehicles.isEmpty ? 0 : int.tryParse(rawVehicles);
    final parsedPeople = rawPeople.isEmpty ? 0 : int.tryParse(rawPeople);
    if (parsedVehicles == null ||
        parsedVehicles < 0 ||
        parsedVehicles > 999 ||
        parsedPeople == null ||
        parsedPeople < 0 ||
        parsedPeople > 999) {
      setState(() => _validationError = '车辆和人员数量须为0至999的整数，未知请留空');
      return;
    }
    Navigator.of(context).pop(
      IncidentForceEditResult(
        stationName: stationName,
        vehicleCount: parsedVehicles,
        personnelCount: parsedPeople,
        vehicleCountKnown: rawVehicles.isNotEmpty,
        personnelCountKnown: rawPeople.isNotEmpty,
        saveCommon: _saveCommon,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final inputBorder = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );

    return CommandSheet(
      title: widget.force == null ? '添加参战力量' : '编辑参战力量',
      subtitle: '车辆与人数未知时可留空，后续随时补充',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CommandButton(
          key: const Key('force-edit-save-btn'),
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!_custom && _names.isNotEmpty)
            DropdownButtonFormField<String>(
              key: const Key('force-station-dropdown'),
              initialValue: _selected,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: '消防站名称',
                filled: true,
                fillColor: colors.surfaceMuted,
                border: inputBorder,
                enabledBorder: inputBorder,
              ),
              items: _names
                  .map(
                    (String name) => DropdownMenuItem<String>(
                      value: name,
                      child: Text(name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (String? value) {
                if (value == null) return;
                setState(() {
                  _selected = value;
                  _validationError = null;
                });
              },
            )
          else
            TextField(
              key: const Key('force-station-custom-field'),
              controller: _customStationCtrl,
              autofocus: true,
              style: typo.body.copyWith(color: colors.textPrimary),
              onChanged: (_) {
                if (_validationError != null) {
                  setState(() => _validationError = null);
                }
              },
              decoration: InputDecoration(
                labelText: '消防站名称',
                hintText: '如：示例路站',
                filled: true,
                fillColor: colors.surfaceMuted,
                border: inputBorder,
                enabledBorder: inputBorder,
              ),
            ),
          if (_names.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: CommandButton(
                key: const Key('force-toggle-custom-btn'),
                label: _custom ? '返回名录选择' : '现场新增消防站',
                icon: Icons.edit_location_alt_outlined,
                variant: CommandButtonVariant.ghost,
                size: CommandButtonSize.standard,
                onPressed: () => setState(() => _custom = !_custom),
              ),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              '保存到本单位常用队伍',
              style: typo.caption.copyWith(color: colors.textPrimary),
            ),
            value: _saveCommon,
            onChanged: (bool? value) =>
                setState(() => _saveCommon = value == true),
          ),
          const SizedBox(height: DsSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('force-vehicles-field'),
                  controller: _vehiclesCtrl,
                  keyboardType: TextInputType.number,
                  style: typo.bodyTabular.copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: '车辆数',
                    hintText: '留空待补充',
                    filled: true,
                    fillColor: colors.surfaceMuted,
                    border: inputBorder,
                    enabledBorder: inputBorder,
                  ),
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: TextField(
                  key: const Key('force-people-field'),
                  controller: _peopleCtrl,
                  keyboardType: TextInputType.number,
                  style: typo.bodyTabular.copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: '人员数',
                    hintText: '留空待补充',
                    filled: true,
                    fillColor: colors.surfaceMuted,
                    border: inputBorder,
                    enabledBorder: inputBorder,
                  ),
                ),
              ),
            ],
          ),
          if (_validationError != null) ...<Widget>[
            const SizedBox(height: DsSpacing.md),
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              backgroundColor: colors.statusColors(DsStatus.alarm).pillBg,
              borderColor: colors.alarmFill.withValues(alpha: 0.35),
              padding: const EdgeInsets.all(DsSpacing.sm),
              child: Text(
                _validationError!,
                style: typo.caption.copyWith(
                  color: colors.alarmText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _IncidentForceMergeSheet extends StatefulWidget {
  const _IncidentForceMergeSheet({
    required this.source,
    required this.candidates,
    required this.targetName,
    required this.vehiclesText,
    required this.peopleText,
  });

  final IncidentForce source;
  final List<IncidentForce> candidates;
  final String targetName;
  final String vehiclesText;
  final String peopleText;

  @override
  State<_IncidentForceMergeSheet> createState() =>
      _IncidentForceMergeSheetState();
}

class _IncidentForceMergeSheetState extends State<_IncidentForceMergeSheet> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    for (final candidate in widget.candidates) {
      if (candidate.stationName == widget.targetName) {
        _selectedId = candidate.id;
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final vLabel = widget.vehiclesText.trim().isEmpty
        ? '车辆待补充'
        : '${widget.vehiclesText.trim()}车';
    final pLabel = widget.peopleText.trim().isEmpty
        ? '人数待补充'
        : '${widget.peopleText.trim()}人';

    return CommandSheet(
      title: '确认合并力量',
      subtitle: '检测到同名消防站，可合并为一条记录',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CommandButton(
          key: const Key('force-merge-confirm-btn'),
          label: '确认合并',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          enabled: _selectedId != null,
          onPressed: _selectedId == null
              ? null
              : () {
                  final target = widget.candidates.firstWhere(
                    (IncidentForce f) => f.id == _selectedId,
                  );
                  Navigator.of(context).pop(target);
                },
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SurfaceCard(
            level: DsSurfaceLevel.flat,
            padding: const EdgeInsets.all(DsSpacing.md),
            child: Text(
              '源记录：${widget.source.stationName} · ${widget.source.quantityLabel}',
              style: typo.body.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          DropdownButtonFormField<String>(
            key: const Key('force-merge-target-dropdown'),
            initialValue: _selectedId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: '合并到已登记队伍',
              filled: true,
              fillColor: colors.surfaceMuted,
              border: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.border),
              ),
            ),
            items: <DropdownMenuItem<String>>[
              for (final f in widget.candidates)
                DropdownMenuItem<String>(
                  value: f.id,
                  child: Text(
                    '${f.stationName} · ${f.quantityLabel}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (String? value) => setState(() => _selectedId = value),
          ),
          const SizedBox(height: DsSpacing.md),
          Text(
            '最终采用本次输入：$vLabel，$pLabel。不累加原数量。',
            style: typo.body.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            '源记录将合并到目标记录，保留目标名称及合并历史。',
            style: typo.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
