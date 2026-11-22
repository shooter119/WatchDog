import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../widgets/incident_address_field_section.dart';
import '../widgets/incident_category_chip.dart';

export '../widgets/incident_address_field_section.dart';

/// 自建警情抽屉输出草稿（全部字段均可选填）。
@immutable
class IncidentCreateDraft {
  const IncidentCreateDraft({
    this.title = '',
    this.location = '',
    this.category = DsIncidentCategory.fire,
    this.categoryExplicitlySelected = false,
    this.latitude,
    this.longitude,
  });

  final String title;
  final String location;
  final DsIncidentCategory category;
  final bool categoryExplicitlySelected;
  final double? latitude;
  final double? longitude;
}

/// 指挥台「编辑警情信息」抽屉输出结果。
@immutable
class IncidentBasicInfoResult {
  const IncidentBasicInfoResult({
    required this.title,
    required this.location,
    this.latitude,
    this.longitude,
  });

  final String title;
  final String location;
  final double? latitude;
  final double? longitude;
}

/// 弹出「新建现场警情」抽屉，支持选填名称、事发地点（带一键定位）与警情大类。
Future<IncidentCreateDraft?> showIncidentCreateSheet(
  BuildContext context, {
  IncidentAddressLocator? onLocateAddress,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<IncidentCreateDraft>(
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
        child: _IncidentCreateSheet(onLocateAddress: onLocateAddress),
      ),
    ),
  );
}

class _IncidentCreateSheet extends StatefulWidget {
  const _IncidentCreateSheet({this.onLocateAddress});

  final IncidentAddressLocator? onLocateAddress;

  @override
  State<_IncidentCreateSheet> createState() => _IncidentCreateSheetState();
}

class _IncidentCreateSheetState extends State<_IncidentCreateSheet> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _locationCtrl = TextEditingController();
  DsIncidentCategory _category = DsIncidentCategory.fire;
  bool _categoryExplicitlySelected = false;
  double? _latitude;
  double? _longitude;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  void _close([IncidentCreateDraft? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(value);
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
      title: '新建现场警情',
      subtitle: '以下信息均可选填；名称留空将自动使用时间戳编号',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => _close(),
        ),
        CommandButton(
          key: const Key('incident-create-confirm-btn'),
          label: '创建并进入',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => _close(
            IncidentCreateDraft(
              title: _titleCtrl.text.trim(),
              location: _locationCtrl.text.trim(),
              category: _category,
              categoryExplicitlySelected: _categoryExplicitlySelected,
              latitude: _latitude,
              longitude: _longitude,
            ),
          ),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const Key('incident-create-title-field'),
            controller: _titleCtrl,
            maxLength: 120,
            style: typo.body.copyWith(color: colors.textPrimary),
            cursorColor: colors.brand,
            decoration: InputDecoration(
              labelText: '警情名称（选填）',
              hintText: '如：示例大道厂房火灾（留空自动编号）',
              hintStyle: typo.body.copyWith(color: colors.textTertiary),
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
          const SizedBox(height: DsSpacing.md),
          IncidentAddressFieldSection(
            controller: _locationCtrl,
            fieldKey: const Key('incident-create-location-field'),
            labelText: '事发地点（选填）',
            hintText: '如：示例大道88号工业园',
            onLocateAddress: widget.onLocateAddress,
            onCoordinatesChanged: (double? lat, double? lon) {
              _latitude = lat;
              _longitude = lon;
            },
          ),
          const SizedBox(height: DsSpacing.md),
          Text(
            '警情大类',
            style: typo.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.sm),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.sm,
            children: <Widget>[
              for (final cat in DsIncidentCategory.values)
                IncidentCategoryChip(
                  key: Key('incident-create-category-${cat.name}'),
                  category: cat,
                  selected: _category == cat,
                  onTap: () => setState(() {
                    _category = cat;
                    _categoryExplicitlySelected = true;
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 弹出「编辑警情信息」抽屉（支持同时修改警情名称与事发地点）。
Future<IncidentBasicInfoResult?> showIncidentBasicInfoSheet(
  BuildContext context, {
  String initialTitle = '',
  String initialLocation = '',
  IncidentAddressLocator? onLocateAddress,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<IncidentBasicInfoResult>(
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
        child: _IncidentBasicInfoSheet(
          initialTitle: initialTitle,
          initialLocation: initialLocation,
          onLocateAddress: onLocateAddress,
        ),
      ),
    ),
  );
}

class _IncidentBasicInfoSheet extends StatefulWidget {
  const _IncidentBasicInfoSheet({
    required this.initialTitle,
    required this.initialLocation,
    this.onLocateAddress,
  });

  final String initialTitle;
  final String initialLocation;
  final IncidentAddressLocator? onLocateAddress;

  @override
  State<_IncidentBasicInfoSheet> createState() =>
      _IncidentBasicInfoSheetState();
}

class _IncidentBasicInfoSheetState extends State<_IncidentBasicInfoSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _locationCtrl;
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _locationCtrl = TextEditingController(text: widget.initialLocation);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  void _close([IncidentBasicInfoResult? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(value);
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
      title: '编辑警情信息',
      subtitle: '名称留空将恢复默认编号；事发地点留空将保留原地址',
      actions: <Widget>[
        CommandButton(
          label: '稍后',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => _close(),
        ),
        CommandButton(
          key: const Key('incident-rename-save-btn'),
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => _close(
            IncidentBasicInfoResult(
              title: _titleCtrl.text.trim(),
              location: _locationCtrl.text.trim(),
              latitude: _latitude,
              longitude: _longitude,
            ),
          ),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const Key('incident-rename-field'),
            controller: _titleCtrl,
            maxLength: 120,
            style: typo.body.copyWith(color: colors.textPrimary),
            cursorColor: colors.brand,
            decoration: InputDecoration(
              labelText: '警情名称',
              hintText: '如：示例小区住宅火灾',
              hintStyle: typo.body.copyWith(color: colors.textTertiary),
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
          const SizedBox(height: DsSpacing.md),
          IncidentAddressFieldSection(
            controller: _locationCtrl,
            fieldKey: const Key('incident-location-field'),
            labelText: '事发地点',
            hintText: '如：示例大道88号工业园',
            onLocateAddress: widget.onLocateAddress,
            onCoordinatesChanged: (double? lat, double? lon) {
              _latitude = lat;
              _longitude = lon;
            },
          ),
        ],
      ),
    );
  }
}
