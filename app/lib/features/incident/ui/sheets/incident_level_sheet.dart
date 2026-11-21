import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/incident.dart';
import '../widgets/incident_category_chip.dart';
import '../widgets/incident_category_style.dart';

/// 警情等级与分类调整结果。
@immutable
class IncidentLevelResult {
  const IncidentLevelResult({
    required this.level,
    required this.disasterCategory,
  });

  final String level;
  final String disasterCategory;
}

/// 弹出基于 [CommandSheet] 的警情大类与灾情等级调整抽屉。
Future<IncidentLevelResult?> showIncidentLevelSheet(
  BuildContext context, {
  required Incident incident,
}) {
  return showModalBottomSheet<IncidentLevelResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext _) => _IncidentLevelSheet(incident: incident),
  );
}

class _IncidentLevelSheet extends StatefulWidget {
  const _IncidentLevelSheet({required this.incident});

  final Incident incident;

  @override
  State<_IncidentLevelSheet> createState() => _IncidentLevelSheetState();
}

class _IncidentLevelSheetState extends State<_IncidentLevelSheet> {
  late final TextEditingController _controller;
  late DsIncidentCategory _selectedCategory;

  static final RegExp _levelPrefixRe = RegExp(r'^[一二三四五六七八九十]+级');

  @override
  void initState() {
    super.initState();
    final info = widget.incident.info;
    final currentCategory = info['original_category']?.toString().trim();
    final initialText = currentCategory?.isNotEmpty == true
        ? currentCategory!
        : (info['level']?.toString().trim() ?? '');
    _controller = TextEditingController(text: initialText);
    _selectedCategory = IncidentCategoryStyle.classify(
      disasterCategory: info['disaster_category']?.toString(),
      category: initialText,
      specificType: info['specific_type']?.toString() ?? '',
      situation: info['situation']?.toString() ?? '',
      title: widget.incident.displayName,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<String> _buildLevelOptions(String text) {
    final trimmed = text.trim();
    final prefix = _levelPrefixRe.firstMatch(trimmed);
    final suffix = prefix == null
        ? trimmed
        : trimmed.substring(prefix.end).trim();
    if (suffix.isEmpty) {
      return const <String>['一级', '二级', '三级', '四级'];
    }
    return <String>[
      '一级$suffix',
      '二级$suffix',
      '三级$suffix',
      '四级$suffix',
    ];
  }

  void _selectCategory(DsIncidentCategory cat) {
    final currentTrimmed = _controller.text.trim();
    final prefix = _levelPrefixRe.firstMatch(currentTrimmed)?.group(0);
    final defaultName = IncidentCategoryStyle.defaultCategoryNameOf(cat);
    final nextText = prefix != null ? '$prefix$defaultName' : defaultName;
    setState(() {
      _selectedCategory = cat;
      _controller.text = nextText;
      _controller.selection = TextSelection.collapsed(offset: nextText.length);
    });
  }

  void _selectLevelOption(String option) {
    setState(() {
      _controller.text = option;
      _controller.selection = TextSelection.collapsed(offset: option.length);
      _selectedCategory = IncidentCategoryStyle.classify(category: option);
    });
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(
      IncidentLevelResult(
        level: value,
        disasterCategory: _selectedCategory.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final options = _buildLevelOptions(_controller.text);
    final canSave = _controller.text.trim().isNotEmpty;

    return CommandSheet(
      title: '警情调整',
      subtitle: '切换警情大类或修改灾情等级，实时同步全队',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CommandButton(
          key: const Key('incident-level-save'),
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          enabled: canSave,
          onPressed: canSave ? _submit : null,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
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
                  key: Key('incident-category-chip-${cat.name}'),
                  category: cat,
                  selected: _selectedCategory == cat,
                  onTap: () => _selectCategory(cat),
                ),
            ],
          ),
          const SizedBox(height: DsSpacing.lg),
          Text(
            '修改灾情等级',
            style: typo.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.sm),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.sm,
            children: <Widget>[
              for (final option in options)
                _LevelOptionChip(
                  label: option,
                  selected: _controller.text.trim() == option,
                  onTap: () => _selectLevelOption(option),
                ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          TextField(
            key: const Key('incident-level-field'),
            controller: _controller,
            maxLength: 80,
            style: typo.body.copyWith(color: colors.textPrimary),
            onChanged: (String value) {
              setState(() {
                _selectedCategory = IncidentCategoryStyle.classify(
                  category: value.trim(),
                );
              });
            },
            decoration: InputDecoration(
              labelText: '灾情等级',
              hintText: '如：一级火灾扑救',
              filled: true,
              fillColor: colors.surfaceMuted,
              border: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.brand, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelOptionChip extends StatelessWidget {
  const _LevelOptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? colors.brand : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderPill,
          side: BorderSide(
            color: selected ? colors.brand : colors.border,
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: DsRadius.borderPill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: DsSizes.touchTarget,
              minWidth: DsSizes.touchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.sm,
              ),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: ds.typography.caption.copyWith(
                    color: selected ? colors.onBrand : colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
