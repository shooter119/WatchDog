import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tactical_brief_engine.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 弹出通讯员战况速报底部模态抽屉
Future<void> showTacticalBriefSheet(
  BuildContext context, {
  required AppController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => TacticalBriefSheet(controller: controller),
  );
}

/// 通讯员现场战况速报生成与一键复制面板
class TacticalBriefSheet extends StatefulWidget {
  final AppController controller;

  const TacticalBriefSheet({
    super.key,
    required this.controller,
  });

  @override
  State<TacticalBriefSheet> createState() => _TacticalBriefSheetState();
}

class _TacticalBriefSheetState extends State<TacticalBriefSheet> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final briefText = TacticalBriefEngine.formatObjectiveBrief(
      incident: c.currentIncident,
      forces: c.forces,
      entries: c.entries,
      notes: c.notes,
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部抓手与标题
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.cardInner,
                AppSpacing.s3,
                AppSpacing.s3,
                AppSpacing.s2,
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.actionPrimary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.description_outlined,
                      size: 18,
                      color: AppColors.actionPrimary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '现场战况速报',
                          style: AppTextStyles.h2.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          '纯客观陈述 · 去富文本杂质 · 适合政务通讯直接发送',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textTertiary,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // 文本预览区域
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.cardInner),
                child: AppCard(
                  radius: AppRadius.md,
                  padding: const EdgeInsets.all(AppSpacing.cardInner),
                  color: AppColors.surfaceSubtle,
                  child: SelectableText(
                    briefText,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: 1.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),

            // 吸底复制按钮
            Padding(
              padding: const EdgeInsets.all(AppSpacing.cardInner),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _copied ? AppColors.safe : AppColors.actionPrimary,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                    icon: Icon(
                      _copied ? Icons.check_circle_rounded : Icons.copy_rounded,
                      size: 20,
                    ),
                    label: Text(
                      _copied ? '已复制到剪贴板' : '一键复制速报全文',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: briefText));
                      HapticFeedback.mediumImpact();
                      if (!mounted) return;
                      setState(() => _copied = true);

                      messenger.showSnackBar(
                        SnackBar(
                          content: const Text('已复制标准化战况，可直接切换至政务微信/政务钉群粘贴发送'),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 3),
                          backgroundColor: AppColors.safe,
                        ),
                      );

                      Future.delayed(const Duration(seconds: 2), () {
                        if (mounted) setState(() => _copied = false);
                      });
                    },
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      '已自动脱敏过滤内部密码与敏感标识',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
