import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 快捷报数面板：以 3MPa 为档位差，点选即提交压力读数（动态耗气率采样点）
class ReportPressureSheet extends StatefulWidget {
  final AppController controller;
  final Entry entry;

  const ReportPressureSheet({super.key, required this.controller, required this.entry});

  /// 压力档位：满压 30MPa 起每档 -3MPa（GA 124 余气报警 5-6MPa，低至 6MPa 为止）
  static const levels = [30, 27, 24, 21, 18, 15, 12, 9, 6];

  @override
  State<ReportPressureSheet> createState() => _ReportPressureSheetState();
}

class _ReportPressureSheetState extends State<ReportPressureSheet> {
  double? _selected;
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final current = e.pressureMpa;
    final fg = _selected != null
        ? AppColors.actionPrimary
        : AppColors.textTertiary.withValues(alpha: 0.6);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${e.name} 报数', style: AppTextStyles.h1),
                const SizedBox(width: 10),
                if (current != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSubtle,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text('当前 $current MPa', style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    )),
                  ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  color: AppColors.textSecondary,
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '选择当前气瓶压力读数，系统将自动估算实测消耗率并修正剩余时间',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final lv in ReportPressureSheet.levels) _levelButton(lv, current),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _selected == null || _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(Icons.speed, color: fg),
                label: Text(_submitting ? '提交中…' : (_selected == null ? '选择压力档位' : '确认报数 ${_selected!.toStringAsFixed(0)} MPa')),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.actionPrimary,
                  disabledBackgroundColor: AppColors.surfaceSubtle,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: AppColors.textTertiary.withValues(alpha: 0.6),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _levelButton(int lv, double? current) {
    final disabled = current != null && lv.toDouble() > current + 0.01;
    final selected = _selected == lv.toDouble();
    return SizedBox(
      width: 76,
      height: 60,
      child: Material(
        color: selected ? AppColors.actionPrimary : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: disabled ? null : () => setState(() => _selected = lv.toDouble()),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: selected ? AppColors.actionPrimary : AppColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Text(
              '$lv',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: disabled
                    ? AppColors.textTertiary.withValues(alpha: 0.3)
                    : selected
                        ? Colors.white
                        : AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final lv = _selected;
    if (lv == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.controller.reportPressure(id: widget.entry.id, pressureMpa: lv);
      if (!mounted) return;
      Navigator.pop(context, lv);
    } catch (err) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('报数失败：$err'), behavior: SnackBarBehavior.floating),
      );
    }
  }
}
