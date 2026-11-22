import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/entry.dart';

/// 同名人员已在场时的处理选择（供现场监控与 M3b 语音确认流复用）。
enum SameNameChoice { merge, force }

/// 弹出同名已在场确认 [CommandSheet]。
///
/// - [SameNameChoice.merge]：同一人（更正/重复登记），保留原记录按新压力重新倒计时；
/// - [SameNameChoice.force]：确实另有同名人员，返回输入区补充区分标识；
/// - `null`：取消。
Future<SameNameChoice?> showSameNameConflictSheet(
  BuildContext context, {
  required Entry existing,
  required double pressureMpa,
  required int durationMin,
}) {
  final at = DateTime.fromMillisecondsSinceEpoch(existing.entryAt);
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';

  return showCommandSheet<SameNameChoice>(
    context: context,
    title: '该人员已在火场内',
    subtitle: '${existing.name} · $time 入场尚未出场',
    builder: (BuildContext sheetContext) {
      return SameNameConflictSheetBody(
        existing: existing,
        entryTimeText: time,
        pressureMpa: pressureMpa,
        durationMin: durationMin,
        onSelect: (SameNameChoice? choice) =>
            Navigator.of(sheetContext).pop(choice),
      );
    },
  );
}

/// 同名冲突确认弹窗主体内容（支持嵌入 [CommandSheet] 或独立渲染单测）。
class SameNameConflictSheetBody extends StatelessWidget {
  const SameNameConflictSheetBody({
    super.key,
    required this.existing,
    required this.entryTimeText,
    required this.pressureMpa,
    required this.durationMin,
    required this.onSelect,
  });

  final Entry existing;
  final String entryTimeText;
  final double pressureMpa;
  final int durationMin;
  final ValueChanged<SameNameChoice?> onSelect;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final cautionPair = colors.statusColors(DsStatus.caution);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SurfaceCard(
          level: DsSurfaceLevel.flat,
          backgroundColor: cautionPair.pillBg,
          borderColor: cautionPair.fill.withValues(alpha: 0.35),
          padding: const EdgeInsets.all(DsSpacing.md),
          child: Text(
            '「${existing.name}」$entryTimeText 已进入火场且尚未出场，本次又登记了同一姓名。\n\n'
            '如为同一人（重复或更正登记），建议合并为一条记录：保留原记录，按本次压力 '
            '$pressureMpa 兆帕从当前时刻重新倒计时（可用 $durationMin 分钟），不会重复计数。',
            style: DsTypography.tabular(
              ds.typography.body.copyWith(
                color: colors.textPrimary,
                height: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        CommandButton(
          key: const Key('same-name-merge-btn'),
          label: '同一人，按新压力重新倒计时',
          icon: DsIcons.merge,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          onPressed: () => onSelect(SameNameChoice.merge),
        ),
        const SizedBox(height: DsSpacing.sm),
        CommandButton(
          key: const Key('same-name-force-btn'),
          label: '同名不同人，返回补充标识',
          icon: DsIcons.userAdd,
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          expanded: true,
          onPressed: () => onSelect(SameNameChoice.force),
        ),
        const SizedBox(height: DsSpacing.xs),
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.ghost,
          size: CommandButtonSize.standard,
          expanded: true,
          onPressed: () => onSelect(null),
        ),
      ],
    );
  }
}
