import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/voice_session_types.dart';

/// 指定人员 / 全员离场二次确认 [CommandSheet]。
///
/// 采用 `CommandButtonVariant.danger` + ≥ 56dp 主按钮（`Key('voice-exit-confirm-btn')`），
/// 展示在场人员名单与语音原文供指挥员/安全员复核防误触。
class VoiceExitConfirmSheet extends StatelessWidget {
  const VoiceExitConfirmSheet({
    super.key,
    required this.entries,
    required this.voiceText,
    this.isAllExit = true,
    this.onConfirm,
    this.onCancel,
  });

  final List<VoiceActiveEntry> entries;
  final String voiceText;
  final bool isAllExit;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final title = isAllExit ? '全员离场确认' : '确认人员离场';
    final countText = isAllExit
        ? '当前在场 ${entries.length} 人'
        : '本次离场 ${entries.length} 人';

    return CommandSheet(
      key: const Key('voice-exit-confirm-sheet'),
      title: title,
      subtitle: countText,
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: onCancel ?? () => Navigator.of(context).pop(false),
        ),
        CommandButton(
          key: const Key('voice-exit-confirm-btn'),
          label: '确认离场',
          icon: DsIcons.logout,
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: onConfirm ?? () => Navigator.of(context).pop(true),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SurfaceCard(
            level: DsSurfaceLevel.flat,
            accentStatus: DsStatus.alarm,
            padding: const EdgeInsets.all(DsSpacing.md),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: DsSpacing.sm,
              runSpacing: DsSpacing.xs,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      DsIcons.stations,
                      size: DsSizes.iconLg,
                      color: colors.textPrimary,
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Text(
                      countText,
                      style: DsTypography.tabular(
                        ds.typography.title,
                      ).copyWith(color: colors.textPrimary),
                    ),
                  ],
                ),
                StatusPill(
                  status: DsStatus.alarm,
                  label: isAllExit ? '全员离场' : '批量离场',
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          Text(
            isAllExit ? '在场人员' : '待离场人员',
            style: ds.typography.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.sm,
            children: <Widget>[
              for (final entry in entries)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.md,
                    vertical: DsSpacing.xs + 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: DsRadius.borderPill,
                    border: Border.all(color: colors.border, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        DsIcons.user,
                        size: DsSizes.iconSm,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: DsSpacing.xs),
                      Text(
                        entry.name,
                        style: ds.typography.body.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (voiceText.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.md),
            Text(
              '语音原文',
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: DsSpacing.xs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.sm + 2,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: DsRadius.borderSm,
                border: Border.all(color: colors.border, width: 1),
              ),
              child: Text(
                '“${voiceText.trim()}”',
                style: ds.typography.body.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
          const SizedBox(height: DsSpacing.md),
          Text(
            '确认后将为以上人员统一登记离场，并同步记录撤离日志。',
            style: ds.typography.body.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 弹出指定人员 / 全员离场二次确认弹窗，返回 `true` 表示确认离场。
Future<bool?> showVoiceExitConfirmSheet({
  required BuildContext context,
  required List<VoiceActiveEntry> entries,
  required String voiceText,
  bool isAllExit = true,
  bool useRootNavigator = false,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    useRootNavigator: useRootNavigator,
    builder: (BuildContext routeContext) => Theme(
      data: capturedTheme,
      child: MediaQuery(
        data: capturedMediaQuery.copyWith(
          viewInsets: MediaQuery.viewInsetsOf(routeContext),
          padding: MediaQuery.paddingOf(routeContext),
          viewPadding: MediaQuery.viewPaddingOf(routeContext),
        ),
        child: VoiceExitConfirmSheet(
          entries: entries,
          voiceText: voiceText,
          isAllExit: isAllExit,
        ),
      ),
    ),
  );
}
