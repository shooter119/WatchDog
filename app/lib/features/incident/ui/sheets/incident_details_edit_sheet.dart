import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import 'incident_basic_info_sheet.dart';

/// 警情基础资料字段标签映射（与后端 `/api/incidents/:id/details` 契约一致）。
const Map<String, String> incidentDetailFieldLabels = <String, String>{
  'location': '事发地点',
  'event_summary': '事件摘要',
  'original_category': '原始分类',
  'level': '等级',
  'specific_type': '具体类型',
  'received_at': '接警时间',
  'administrative_area': '行政区',
  'dispatch_summary': '出动力量',
  'place_type': '场所类型',
  'situation': '现场情况',
  'trapped': '人员被困',
  'injured': '人员受伤',
  'hazardous_materials': '危险物质',
};

/// 弹出基于 [CommandSheet] 的警情详细资料编辑表单。
Future<Map<String, String>?> showIncidentDetailsEditSheet(
  BuildContext context, {
  required Map<String, dynamic> initialData,
  IncidentAddressLocator? onLocateAddress,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<Map<String, String>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext routeContext) => Theme(
      data: capturedTheme,
      child: MediaQuery(
        data: capturedMediaQuery.copyWith(
          viewInsets: MediaQuery.viewInsetsOf(routeContext),
          padding: MediaQuery.paddingOf(routeContext),
          viewPadding: MediaQuery.viewPaddingOf(routeContext),
        ),
        child: _IncidentDetailsEditSheet(
          initialData: initialData,
          onLocateAddress: onLocateAddress,
        ),
      ),
    ),
  );
}

class _IncidentDetailsEditSheet extends StatefulWidget {
  const _IncidentDetailsEditSheet({
    required this.initialData,
    this.onLocateAddress,
  });

  final Map<String, dynamic> initialData;
  final IncidentAddressLocator? onLocateAddress;

  @override
  State<_IncidentDetailsEditSheet> createState() =>
      _IncidentDetailsEditSheetState();
}

class _IncidentDetailsEditSheetState extends State<_IncidentDetailsEditSheet> {
  late final Map<String, TextEditingController> _controllers;
  double? _locatedLatitude;
  double? _locatedLongitude;

  @override
  void initState() {
    super.initState();
    _controllers = <String, TextEditingController>{
      for (final key in incidentDetailFieldLabels.keys)
        key: TextEditingController(
          text: widget.initialData[key]?.toString() ?? '',
        ),
    };
  }

  @override
  void dispose() {
    for (final ctrl in _controllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _close([Map<String, String>? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(value);
  }

  void _save() {
    final result = <String, String>{
      for (final entry in _controllers.entries) entry.key: entry.value.text.trim(),
      if (_locatedLatitude != null && _locatedLongitude != null)
        ...<String, String>{
          'latitude': _locatedLatitude!.toStringAsFixed(6),
          'longitude': _locatedLongitude!.toStringAsFixed(6),
        },
    };
    _close(result);
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
      title: '修改警情资料',
      subtitle: '保存后将按乐观锁版本同步至全队设备',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => _close(),
        ),
        CommandButton(
          key: const Key('incident-details-edit-save-btn'),
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: _save,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final entry in _controllers.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: DsSpacing.md),
              child: entry.key == 'location'
                  ? IncidentAddressFieldSection(
                      controller: entry.value,
                      fieldKey: const Key('incident-detail-field-location'),
                      labelText: incidentDetailFieldLabels[entry.key]!,
                      hintText: '如：示例大道88号工业园',
                      maxLines: 4,
                      onLocateAddress: widget.onLocateAddress,
                      onCoordinatesChanged: (double? lat, double? lon) {
                        _locatedLatitude = lat;
                        _locatedLongitude = lon;
                      },
                    )
                  : TextField(
                      key: Key('incident-detail-field-${entry.key}'),
                      controller: entry.value,
                      minLines: 1,
                      maxLines: 4,
                      style: typo.body.copyWith(color: colors.textPrimary),
                      decoration: InputDecoration(
                        labelText: incidentDetailFieldLabels[entry.key],
                        hintText: entry.key == 'received_at'
                            ? 'YYYY-MM-DDTHH:mm:ss+08:00'
                            : null,
                        filled: true,
                        fillColor: colors.surfaceMuted,
                        border: border,
                        enabledBorder: border,
                        focusedBorder: OutlineInputBorder(
                          borderRadius: DsRadius.borderMd,
                          borderSide: BorderSide(color: colors.brand, width: 1.5),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
