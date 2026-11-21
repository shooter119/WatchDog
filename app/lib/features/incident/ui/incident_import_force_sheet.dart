import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/incident_force.dart';
import '../state/incident_import_store.dart';

/// 弹出 DS v3.0 `CommandSheet` 核对/编辑警情导入识别到的单支参战力量。
Future<Map<String, dynamic>?> showIncidentImportForceSheet(
  BuildContext context, {
  required Map<String, dynamic> force,
  required List<IncidentForce> existingForces,
  required List<ImportStationOption> stationOptions,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext _) => _IncidentImportForceSheet(
      force: force,
      existingForces: existingForces,
      stationOptions: stationOptions,
    ),
  );
}

class _IncidentImportForceSheet extends StatefulWidget {
  const _IncidentImportForceSheet({
    required this.force,
    required this.existingForces,
    required this.stationOptions,
  });

  final Map<String, dynamic> force;
  final List<IncidentForce> existingForces;
  final List<ImportStationOption> stationOptions;

  @override
  State<_IncidentImportForceSheet> createState() =>
      _IncidentImportForceSheetState();
}

class _IncidentImportForceSheetState extends State<_IncidentImportForceSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _vehiclesController;
  late final TextEditingController _peopleController;
  late final List<Map<String, dynamic>> _candidates;
  String? _choice;
  bool _saveCommon = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    final force = widget.force;
    _nameController = TextEditingController(
      text: force['station_name']?.toString() ?? '',
    );
    _vehiclesController = TextEditingController(
      text: force['vehicle_count']?.toString() ?? '',
    );
    _peopleController = TextEditingController(
      text: force['personnel_count']?.toString() ?? '',
    );
    _saveCommon = force['save_common'] == true;

    _candidates = <Map<String, dynamic>>[
      for (final f in widget.existingForces)
        <String, dynamic>{
          'key': 'force:${f.id}',
          'name': f.stationName,
          'target_force_id': f.id,
          'expected_version': f.version,
          'station_id': f.stationId,
        },
      for (final s in widget.stationOptions)
        <String, dynamic>{
          'key': s.isUnitStation ? 'unit:${s.id}' : 'system:${s.id}',
          'name': s.name,
          if (s.isUnitStation) 'unit_station_id': s.id else 'station_id': s.id,
        },
    ];

    String? initial;
    if (force['target_force_id'] != null) {
      initial = 'force:${force['target_force_id']}';
    } else if (force['unit_station_id'] != null) {
      initial = 'unit:${force['unit_station_id']}';
    } else if (force['station_id'] != null) {
      initial = 'system:${force['station_id']}';
    }
    if (_candidates.any((c) => c['key'] == initial)) {
      _choice = initial;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _vehiclesController.dispose();
    _peopleController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final rawVehicles = _vehiclesController.text.trim();
    final rawPeople = _peopleController.text.trim();
    final v = int.tryParse(rawVehicles);
    final p = int.tryParse(rawPeople);

    if (name.isEmpty ||
        (rawVehicles.isNotEmpty && (v == null || v < 0 || v > 999)) ||
        (rawPeople.isNotEmpty && (p == null || p < 0 || p > 999))) {
      setState(() => _validationError = '请填写队伍名称和0至999的整数，未知数量留空');
      return;
    }

    final candidate = _choice == null
        ? const <String, dynamic>{}
        : _candidates.firstWhere((c) => c['key'] == _choice);

    Navigator.of(context).pop(<String, dynamic>{
      ...widget.force,
      'station_name': name,
      'vehicle_count': v,
      'personnel_count': p,
      'save_common': _saveCommon,
      'target_force_id': candidate['target_force_id'],
      'expected_version': candidate['expected_version'],
      'unit_station_id': candidate['unit_station_id'],
      'station_id': candidate['station_id'],
      'matched_name': candidate['name'],
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );

    return CommandSheet(
      title: '核对出动力量',
      subtitle: '可关联已登记队伍或单位名录，未知数量留空待补充',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CommandButton(
          key: const Key('import-force-save-btn'),
          label: '确定',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DropdownButtonFormField<String>(
            key: const Key('import-force-match-dropdown'),
            initialValue: _choice ?? '',
            isExpanded: true,
            decoration: InputDecoration(
              labelText: '匹配已有队伍',
              filled: true,
              fillColor: colors.surfaceMuted,
              border: border,
              enabledBorder: border,
            ),
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem<String>(
                value: '',
                child: Text('作为新队伍登记', overflow: TextOverflow.ellipsis),
              ),
              for (final c in _candidates)
                DropdownMenuItem<String>(
                  value: c['key'] as String,
                  child: Text(
                    '${c['name']} · ${(c['key'] as String).startsWith('force:') ? '已登记' : '名录'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (String? value) {
              setState(() {
                _choice = (value == null || value.isEmpty) ? null : value;
                _validationError = null;
                if (_choice != null) {
                  _nameController.text = _candidates
                      .firstWhere((c) => c['key'] == _choice)['name']
                      .toString();
                }
              });
            },
          ),
          const SizedBox(height: DsSpacing.md),
          TextField(
            key: const Key('import-force-name-field'),
            controller: _nameController,
            style: typo.body.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              labelText: '队伍名称',
              filled: true,
              fillColor: colors.surfaceMuted,
              border: border,
              enabledBorder: border,
            ),
            onChanged: (_) => setState(() {
              _choice = null;
              _validationError = null;
            }),
          ),
          const SizedBox(height: DsSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('import-force-vehicles-field'),
                  controller: _vehiclesController,
                  keyboardType: TextInputType.number,
                  style: typo.bodyTabular.copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: '车辆数',
                    hintText: '留空待补充',
                    filled: true,
                    fillColor: colors.surfaceMuted,
                    border: border,
                    enabledBorder: border,
                  ),
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: TextField(
                  key: const Key('import-force-people-field'),
                  controller: _peopleController,
                  keyboardType: TextInputType.number,
                  style: typo.bodyTabular.copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: '人数',
                    hintText: '留空待补充',
                    filled: true,
                    fillColor: colors.surfaceMuted,
                    border: border,
                    enabledBorder: border,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xs),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              '保存到本单位常用队伍',
              style: typo.body.copyWith(color: colors.textPrimary),
            ),
            value: _saveCommon,
            onChanged: (bool? v) => setState(() => _saveCommon = v == true),
          ),
          if (_validationError != null) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            SurfaceCard(
              key: const Key('import-force-validation-error'),
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
