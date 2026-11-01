import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'app_widgets.dart';

/// 模态确认弹窗通用辅助函数
///
/// 返回值：点击确认返回 true；取消或点击空白处关闭返回 false。
Future<bool> showAppConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      Widget? dialogContent;
      if (message != null && content != null) {
        dialogContent = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(message), const SizedBox(height: 12), content],
        );
      } else if (content != null) {
        dialogContent = content;
      } else if (message != null) {
        dialogContent = Text(message);
      }

      return AlertDialog(
        title: Text(title),
        content: dialogContent,
        actions: [
          appConfirmDialogActions(
            dialogContext,
            confirmLabel: confirmLabel,
            cancelLabel: cancelLabel,
            destructive: destructive,
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// 确认框按钮行（Q8 规格）：左侧带边框的中性取消、右侧实心确认，间距 12dp，高 52dp。
///
/// 供需要自定义内容（如实时鉴权重建）的确认框复用；点击分别 `pop(false)` / `pop(true)`。
Widget appConfirmDialogActions(
  BuildContext context, {
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
}) {
  final cancelButton = OutlinedButton(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 52),
      foregroundColor: AppColors.textPrimary,
      // 边框用 textSecondary（对白底 7.6:1），避免浅灰“隐形按钮”。
      side: BorderSide(color: AppColors.textSecondary, width: 1.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      textStyle: const TextStyle(
        fontFamily: AppFonts.family,
        fontFamilyFallback: AppFonts.fallback,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    ),
    onPressed: () => Navigator.of(context).pop(false),
    child: Text(cancelLabel),
  );

  final confirmButton = FilledButton(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 52),
      backgroundColor: destructive
          ? AppColors.destructive
          : AppColors.actionPrimary,
      // 危险确认用 onStatus 白字（对 destructive 6.47:1）；夜间主题 onPrimary 为深色。
      foregroundColor: destructive ? AppColors.onStatus : AppColors.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      textStyle: const TextStyle(
        fontFamily: AppFonts.family,
        fontFamilyFallback: AppFonts.fallback,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    ),
    onPressed: () => Navigator.of(context).pop(true),
    child: Text(confirmLabel),
  );

  return Row(
    children: [
      Expanded(child: cancelButton),
      const SizedBox(width: 12),
      Expanded(child: confirmButton),
    ],
  );
}
