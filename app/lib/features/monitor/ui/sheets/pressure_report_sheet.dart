import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/entry.dart';
import '../../state/monitor_store.dart';

/// 弹出基于 [CommandSheet] 的快捷更新压力底部面板。
Future<double?> showPressureReportSheet(
  BuildContext context, {
  required MonitorStore monitorStore,
  required Entry entry,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext routeContext) {
      return Theme(
        data: capturedTheme,
        child: MediaQuery(
          data: capturedMediaQuery.copyWith(
            viewInsets: MediaQuery.viewInsetsOf(routeContext),
            padding: MediaQuery.paddingOf(routeContext),
            viewPadding: MediaQuery.viewPaddingOf(routeContext),
          ),
          child: PressureReportSheet(
            monitorStore: monitorStore,
            entry: entry,
          ),
        ),
      );
    },
  );
}

/// 快捷更新压力面板（基于 DS v3.0 [CommandSheet]）。
///
/// 业务不变量：
/// - 30 → 6 MPa（-3 MPa 步进）共 9 档预设，高于当前压力的预设禁用；
/// - 手动输入合法范围 `0 < p <= 40`，与档位严格互斥；
/// - 手动提交高于当前压力时通过 [showCommandSheet] 二次确认；
/// - 提交成功后写火场日志（非阻断）并关闭面板返回新压力值。
class PressureReportSheet extends StatefulWidget {
  const PressureReportSheet({
    super.key,
    required this.monitorStore,
    required this.entry,
  });

  final MonitorStore monitorStore;
  final Entry entry;

  /// 压力档位：满压 30 MPa 起每档 -3 MPa（GA 124 余气报警 5-6 MPa，低至 6 MPa）。
  static const List<int> levels = <int>[30, 27, 24, 21, 18, 15, 12, 9, 6];

  /// 手动输入合法上限（与后端一致：`0 < p <= 40`）。
  static const double maxPressureMpa = 40.0;

  @override
  State<PressureReportSheet> createState() => _PressureReportSheetState();
}

class _PressureReportSheetState extends State<PressureReportSheet> {
  double? _selected;
  double? _customValue;
  bool _submitting = false;
  final TextEditingController _customCtrl = TextEditingController();

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  double? get _effective => _customValue ?? _selected;

  void _onCustomChanged(String text) {
    final v = double.tryParse(text.trim());
    setState(() {
      if (v != null && v > 0 && v <= PressureReportSheet.maxPressureMpa) {
        _customValue = v;
        _selected = null;
      } else {
        _customValue = null;
      }
    });
  }

  void _selectLevel(int level) {
    setState(() {
      _selected = level.toDouble();
      _customValue = null;
      _customCtrl.clear();
    });
  }

  Future<void> _submit() async {
    final lv = _effective;
    if (lv == null || _submitting) return;

    final current = widget.entry.pressureMpa;
    final formattedLv = MonitorStore.formatPressure(lv);

    if (current != null && lv > current + 0.01) {
      final confirmed = await showCommandSheet<bool>(
        context: context,
        title: '压力调高确认',
        subtitle: '${widget.entry.name} · 当前 ${current.toStringAsFixed(1)} MPa',
        builder: (BuildContext sheetContext) {
          final sheetDs = sheetContext.ds;
          final cautionPair = sheetDs.colors.statusColors(DsStatus.caution);
          return SurfaceCard(
            level: DsSurfaceLevel.flat,
            backgroundColor: cautionPair.pillBg,
            borderColor: cautionPair.fill.withValues(alpha: 0.35),
            padding: const EdgeInsets.all(DsSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  DsIcons.warning,
                  color: cautionPair.text,
                  size: DsSizes.iconLg,
                ),
                const SizedBox(width: DsSpacing.sm),
                Expanded(
                  child: Text(
                    '队员 ${widget.entry.name} 当前压力为 ${current.toStringAsFixed(1)} MPa，'
                    '拟更新为更大的 $formattedLv MPa。\n\n'
                    '气瓶正常工作通常只降不升。若是校正上一次误报的读数，请点击「确认调高」继续。',
                    style: sheetDs.typography.body.copyWith(
                      color: sheetDs.colors.textPrimary,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        actionsBuilder: (BuildContext sheetContext) => <Widget>[
          CommandButton(
            label: '取消',
            variant: CommandButtonVariant.secondary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(sheetContext).pop(false),
          ),
          CommandButton(
            label: '确认调高',
            variant: CommandButtonVariant.danger,
            size: CommandButtonSize.large,
            requireConfirmation: false,
            onPressed: () => Navigator.of(sheetContext).pop(true),
          ),
        ],
      );
      if (confirmed != true) return;
    }

    if (!mounted) return;
    setState(() => _submitting = true);
    try {
      await widget.monitorStore.updatePressure(
        id: widget.entry.id,
        pressureMpa: lv,
        recordNote: true,
      );
      if (!mounted) return;
      Navigator.of(context).pop(lv);
    } catch (err) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('更新压力失败：$err'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final current = widget.entry.pressureMpa;
    final effective = _effective;

    return CommandSheet(
      title: '${widget.entry.name} 更新压力',
      subtitle: current != null
          ? '初始 $current MPa · 选择当前压力自动修正剩余时间'
          : '选择当前气瓶压力读数，系统将自动估算实测消耗率并修正剩余时间',
      actions: <Widget>[
        CommandButton(
          key: const Key('pressure-sheet-submit-btn'),
          label: _submitting
              ? '提交中…'
              : (effective == null
                    ? '选择压力档位'
                    : '确认更新 ${MonitorStore.formatPressure(effective)} MPa'),
          icon: DsIcons.gasMeter,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          isLoading: _submitting,
          enabled: effective != null && !_submitting,
          onPressed: _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '常用压力档位（MPa）',
            style: ds.typography.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              const spacing = DsSpacing.sm;
              final columns = constraints.maxWidth < 260 ? 2 : 3;
              final itemWidth =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: <Widget>[
                  for (final lv in PressureReportSheet.levels)
                    _buildLevelButton(
                      context,
                      level: lv,
                      current: current,
                      width: itemWidth,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: DsSpacing.lg),
          TextField(
            key: const Key('pressure-sheet-custom-input'),
            controller: _customCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: _onCustomChanged,
            style: DsTypography.tabular(
              ds.typography.title.copyWith(color: colors.textPrimary),
            ),
            decoration: InputDecoration(
              labelText: '其他压力',
              hintText: '手动输入压力值（0 < p ≤ 40）',
              suffixText: 'MPa',
              filled: true,
              fillColor: colors.surfaceMuted,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.md,
              ),
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
                borderSide: BorderSide(color: colors.brand, width: 2),
              ),
              labelStyle: ds.typography.body.copyWith(
                color: colors.textSecondary,
              ),
              hintStyle: ds.typography.body.copyWith(
                color: colors.textTertiary,
              ),
              suffixStyle: ds.typography.body.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelButton(
    BuildContext context, {
    required int level,
    required double? current,
    required double width,
  }) {
    final ds = context.ds;
    final colors = ds.colors;
    final disabled = current != null && level.toDouble() > current + 0.01;
    final selected = _selected == level.toDouble();

    final bg = selected
        ? colors.brand
        : (disabled ? colors.surfaceMuted : colors.surface);
    final fg = selected
        ? colors.onBrand
        : (disabled
              ? colors.textTertiary.withValues(alpha: 0.45)
              : colors.textPrimary);
    final borderColor = selected ? colors.brand : colors.border;

    return SizedBox(
      width: width,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DsSizes.primaryAction),
        child: Material(
          key: Key('pressure-sheet-level-$level'),
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: DsRadius.borderMd,
            side: BorderSide(color: borderColor, width: selected ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: disabled
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    _selectLevel(level);
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.sm,
                vertical: DsSpacing.sm,
              ),
              child: Center(
                child: Text(
                  '$level',
                  style: DsTypography.tabular(
                    ds.typography.metric.copyWith(color: fg),
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
