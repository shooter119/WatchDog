import 'package:flutter/material.dart';

import '../models/models.dart';

/// 同名已在场时的处理选择
enum SameNameChoice { merge, force }

/// 同名人员已在火场内确认弹窗：
/// - merge：同一人（更正/重复登记），保留原记录按新压力重新倒计时
/// - force：确实另有同名人员，另建一条记录
/// - null：取消
Future<SameNameChoice?> showSameNameDialog(
  BuildContext context, {
  required Entry existing,
  required double pressureMpa,
  required int durationMin,
}) async {
  final at = DateTime.fromMillisecondsSinceEpoch(existing.entryAt);
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  return showDialog<SameNameChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('该人员已在火场内'),
      content: Text(
        '「${existing.name}」$time 已进入火场且尚未出场，本次又登记了同一姓名。\n\n'
        '如为同一人（重复或更正登记），建议合并为一条记录：保留原记录，按本次压力 $pressureMpa 兆帕从当前时刻重新倒计时（可用 $durationMin 分钟），不会重复计数。',
        style: const TextStyle(height: 1.5, fontSize: 14),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, SameNameChoice.force),
          child: const Text('另有同名人员，另建记录'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, SameNameChoice.merge),
          child: const Text('同一人，按新压力重新倒计时'),
        ),
      ],
    ),
  );
}
