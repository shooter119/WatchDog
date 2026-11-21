import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design_system/design_system.dart';
import '../../state/voice_draft_person.dart';

/// 单名待确认进场人员编辑卡。
///
/// 包含姓名联想（名单匹配）、非名单留空提醒、在场同名冲突提示、
/// 气瓶压力输入、6.8L / 9L 容积切换芯片与等宽可用时长预览。
class VoicePersonEditorCard extends StatefulWidget {
  const VoicePersonEditorCard({
    super.key,
    required this.index,
    required this.draft,
    required this.calcParams,
    required this.onNameChanged,
    required this.onPressureChanged,
    required this.onVolumeChanged,
    this.rosterNames = const <String>[],
    this.isDuplicateActive = false,
    this.showHeader = true,
    this.enabled = true,
    this.onRemove,
  });

  final int index;
  final VoiceDraftPerson draft;
  final VoiceCalcParams calcParams;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onPressureChanged;
  final ValueChanged<double> onVolumeChanged;
  final List<String> rosterNames;
  final bool isDuplicateActive;
  final bool showHeader;
  final bool enabled;
  final VoidCallback? onRemove;

  @override
  State<VoicePersonEditorCard> createState() => _VoicePersonEditorCardState();
}

class _VoicePersonEditorCardState extends State<VoicePersonEditorCard> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _pressureCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.draft.name);
    _pressureCtrl = TextEditingController(text: widget.draft.pressureText);
  }

  @override
  void didUpdateWidget(covariant VoicePersonEditorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idChanged = widget.draft.id != oldWidget.draft.id;
    if (idChanged || widget.draft.name != _nameCtrl.text) {
      _syncController(_nameCtrl, widget.draft.name);
    }
    if (idChanged || widget.draft.pressureText != _pressureCtrl.text) {
      _syncController(_pressureCtrl, widget.draft.pressureText);
    }
  }

  void _syncController(TextEditingController ctrl, String nextText) {
    if (ctrl.text == nextText) return;
    ctrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pressureCtrl.dispose();
    super.dispose();
  }

  List<String> _buildRosterSuggestions() {
    if (widget.rosterNames.isEmpty) return const <String>[];
    final query = widget.draft.trimmedName;
    if (query.isEmpty) {
      if (!widget.draft.hasUnmatchedSourceName) return const <String>[];
      return widget.rosterNames
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .take(4)
          .toList(growable: false);
    }
    if (widget.rosterNames.contains(query)) return const <String>[];
    return widget.rosterNames
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e.contains(query) && e != query)
        .take(4)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final suggestions = _buildRosterSuggestions();

    return SurfaceCard(
      key: Key('voice-person-card-${widget.index}'),
      level: DsSurfaceLevel.outlined,
      accentStatus: widget.isDuplicateActive ? DsStatus.caution : null,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.showHeader) ...<Widget>[
            _buildHeader(context),
            const SizedBox(height: DsSpacing.sm),
          ],
          _buildInputFields(context),
          if (suggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            _buildSuggestionsRow(context, suggestions),
          ],
          if (draft.hasUnmatchedSourceName) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            _buildNoticeBox(
              context,
              icon: Icons.info_outline_rounded,
              text: '「${draft.sourceName}」不在名单内，已清空姓名栏，请手动补全正确姓名',
            ),
          ],
          if (widget.isDuplicateActive &&
              draft.trimmedName.isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            _buildNoticeBox(
              context,
              icon: Icons.warning_amber_rounded,
              text: '「${draft.trimmedName}」已在火场内，确认时将弹窗选择：重新倒计时 / 另建记录',
            ),
          ],
          const SizedBox(height: DsSpacing.sm),
          if (draft.hasValidPressure)
            _buildCapacityAndDuration(context, draft.pressureMpa!)
          else
            _buildNoticeBox(
              context,
              icon: Icons.info_outline_rounded,
              text: '未识别到气瓶压力，请手动填写（如 20）',
            ),
          if (!widget.showHeader && widget.onRemove != null) ...<Widget>[
            const SizedBox(height: DsSpacing.xs),
            Align(
              alignment: Alignment.centerRight,
              child: _buildRemoveButton(context),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRemoveButton(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return TextButton.icon(
      onPressed: widget.enabled ? widget.onRemove : null,
      icon: Icon(Icons.close_rounded, size: DsSizes.iconSm, color: colors.textSecondary),
      label: Text(
        '移除该人员',
        style: ds.typography.caption.copyWith(color: colors.textSecondary, fontWeight: FontWeight.w600),
      ),
      style: TextButton.styleFrom(
        minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
        padding: const EdgeInsets.symmetric(horizontal: DsSpacing.sm),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: DsSpacing.sm,
      runSpacing: DsSpacing.xs,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: colors.brand),
              child: Text(
                '${widget.index + 1}',
                style: DsTypography.tabular(ds.typography.caption)
                    .copyWith(color: colors.onBrand, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: DsSpacing.sm),
            Text('队员 ${widget.index + 1}', style: ds.typography.title.copyWith(color: colors.textPrimary)),
          ],
        ),
        if (widget.onRemove != null) _buildRemoveButton(context),
      ],
    );
  }

  Widget _buildInputFields(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final compact =
            constraints.maxWidth < 280 ||
            MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
        final nameField = TextField(
          key: Key('voice-person-name-${widget.index}'),
          controller: _nameCtrl,
          enabled: widget.enabled,
          onChanged: widget.onNameChanged,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '姓名',
            prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
          ),
          style: ds.typography.title.copyWith(color: colors.textPrimary),
        );
        final pressureField = TextField(
          key: Key('voice-person-pressure-${widget.index}'),
          controller: _pressureCtrl,
          enabled: widget.enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: widget.onPressureChanged,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '压力',
            suffixText: 'MPa',
          ),
          style: DsTypography.tabular(
            ds.typography.title,
          ).copyWith(color: colors.textPrimary),
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              nameField,
              const SizedBox(height: DsSpacing.sm),
              pressureField,
            ],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(child: nameField),
            const SizedBox(width: DsSpacing.sm),
            SizedBox(width: 116, child: pressureField),
          ],
        );
      },
    );
  }

  Widget _buildSuggestionsRow(BuildContext context, List<String> suggestions) {
    final ds = context.ds;
    final colors = ds.colors;
    return Wrap(
      spacing: DsSpacing.sm,
      runSpacing: DsSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '名单建议',
          style: ds.typography.caption.copyWith(color: colors.textSecondary),
        ),
        for (final candidate in suggestions)
          Material(
            color: colors.surfaceMuted,
            shape: RoundedRectangleBorder(
              borderRadius: DsRadius.borderMd,
              side: BorderSide(color: colors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.enabled
                  ? () {
                      HapticFeedback.selectionClick();
                      _syncController(_nameCtrl, candidate);
                      widget.onNameChanged(candidate);
                    }
                  : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: DsSizes.touchTarget,
                  minWidth: DsSizes.touchTarget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md),
                  child: Center(
                    widthFactor: 1.0,
                    child: Text(
                      candidate,
                      style: ds.typography.body.copyWith(
                        color: colors.brandText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCapacityAndDuration(BuildContext context, double pressureMpa) {
    final ds = context.ds;
    final colors = ds.colors;
    final minutes = widget.calcParams
        .durationMinFor(pressureMpa, cylinderVolL: widget.draft.volumeL)
        .round();
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.gas_meter_outlined, size: DsSizes.iconSm, color: colors.textSecondary),
        const SizedBox(width: DsSpacing.xs + 2),
        Text(
          '容量',
          style: ds.typography.caption.copyWith(
            color: colors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    final chips = Wrap(
      spacing: DsSpacing.sm,
      runSpacing: DsSpacing.xs,
      children: <Widget>[
        for (final vol in kAllowedCylinderVolumesL) _buildVolumeChip(context, vol),
      ],
    );
    final durationText = Text(
      '可用时间 $minutes 分钟',
      maxLines: 1,
      softWrap: false,
      style: DsTypography.tabular(ds.typography.body).copyWith(
        color: colors.textPrimary,
        fontWeight: FontWeight.w700,
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md, vertical: DsSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: DsRadius.borderMd,
        border: Border.all(color: colors.border),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final compact =
              constraints.maxWidth < 330 ||
              MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.xs,
                  children: <Widget>[label, chips],
                ),
                const SizedBox(height: DsSpacing.xs),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: durationText,
                ),
              ],
            );
          }
          return Row(
            children: <Widget>[
              label,
              const SizedBox(width: DsSpacing.sm),
              chips,
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(fit: BoxFit.scaleDown, child: durationText),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVolumeChip(BuildContext context, double volumeL) {
    final ds = context.ds;
    final colors = ds.colors;
    final selected = (widget.draft.volumeL - volumeL).abs() < 0.01;
    final label = cylinderVolumeChipLabel(volumeL);
    return Semantics(
      button: true,
      selected: selected,
      label: '气瓶容量 $label',
      child: Material(
        key: Key('voice-person-vol-${cylinderVolumeKeyTag(volumeL)}'),
        color: selected ? colors.brand : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderSm,
          side: BorderSide(color: selected ? colors.brand : colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.enabled
              ? () {
                  HapticFeedback.selectionClick();
                  widget.onVolumeChanged(volumeL);
                }
              : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpacing.sm + 2),
              child: Center(
                widthFactor: 1.0,
                child: Text(
                  label,
                  style: DsTypography.tabular(ds.typography.caption).copyWith(
                    color: selected ? colors.onBrand : colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNoticeBox(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final ds = context.ds;
    final caution = ds.colors.statusColors(DsStatus.caution);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: caution.pillBg,
        borderRadius: DsRadius.borderSm,
        border: Border.all(color: caution.fill.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: DsSizes.iconSm, color: caution.text),
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ds.typography.caption.copyWith(
                color: ds.colors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
