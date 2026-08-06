import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 快捷更新压力面板：预设档位点选 + 手动输入数值，提交压力读数（动态耗气率采样点）
class ReportPressureSheet extends StatefulWidget {
  final AppController controller;
  final Entry entry;

  const ReportPressureSheet({super.key, required this.controller, required this.entry});

  /// 压力档位：满压 30MPa 起每档 -3MPa（GA 124 余气报警 5-6MPa，低至 6MPa 为止）
  static const levels = [30, 27, 24, 21, 18, 15, 12, 9, 6];

  /// 手动输入合法范围（与后端一致：0 < p <= 40）
  static const maxPressureMpa = 40.0;

  @override
  State<ReportPressureSheet> createState() => _ReportPressureSheetState();
}

class _ReportPressureSheetState extends State<ReportPressureSheet> {
  double? _selected;
  double? _customValue;
  bool _submitting = false;
  final TextEditingController _customCtrl = TextEditingController();

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  /// 最终取值：手动输入优先，否则用选中的档位
  double? get _effective => _customValue ?? _selected;

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  void _onCustomChanged(String text) {
    final v = double.tryParse(text.trim());
    setState(() {
      if (v != null && v > 0 && v <= ReportPressureSheet.maxPressureMpa) {
        _customValue = v;
        _selected = null; // 手动输入与档位互斥
      } else {
        _customValue = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final current = e.pressureMpa;
    final effective = _effective;
    final fg = effective != null
        ? AppColors.actionPrimary
        : AppColors.textTertiary.withValues(alpha: 0.6);
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + keyboardInset),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${e.name} 更新压力', style: AppTextStyles.h1),
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
            const SizedBox(height: 14),
            TextField(
              controller: _customCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              onChanged: _onCustomChanged,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                labelText: '其他压力',
                hintText: '手动输入压力值',
                suffixText: 'MPa',
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: const BorderSide(color: AppColors.actionPrimary, width: 2),
                ),
                labelStyle: const TextStyle(color: AppColors.textTertiary),
                hintStyle: const TextStyle(color: AppColors.textTertiary),
                suffixStyle: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: effective == null || _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(Icons.speed, color: fg),
                label: Text(_submitting ? '提交中…' : (effective == null ? '选择压力档位' : '确认更新 ${_fmt(effective)} MPa')),
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
          onTap: disabled
              ? null
              : () => setState(() {
                    _selected = lv.toDouble();
                    _customValue = null;
                    _customCtrl.clear();
                  }),
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
    final lv = _effective;
    if (lv == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.controller.updatePressure(id: widget.entry.id, pressureMpa: lv);
      if (!mounted) return;
      Navigator.pop(context, lv);
    } catch (err) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新压力失败：$err'), behavior: SnackBarBehavior.floating),
      );
    }
  }
}
