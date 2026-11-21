import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/voice_draft_person.dart';
import 'widgets/voice_person_editor_card.dart';

/// 全局跨页进场语音确认 [CommandSheet]。
///
/// 支持单人 / 多人自适应排版、顶部转写原文条、继续语音追加、重新语音输入，
/// 以及底部固定 ≥ 56dp 一键全部确认按钮。
class VoiceConfirmSheet extends StatelessWidget {
  const VoiceConfirmSheet({
    super.key,
    required this.drafts,
    required this.calcParams,
    required this.onNameChanged,
    required this.onPressureChanged,
    required this.onVolumeChanged,
    required this.onRemoveAt,
    required this.onConfirmAll,
    required this.onContinueVoice,
    required this.onRetry,
    this.transcript,
    this.inlineError,
    this.rosterNames = const <String>[],
    this.activeEntryNames = const <String>{},
    this.isProcessing = false,
    this.showCloseButton = true,
  });

  final List<VoiceDraftPerson> drafts;
  final VoiceCalcParams calcParams;
  final void Function(int index, String value) onNameChanged;
  final void Function(int index, String value) onPressureChanged;
  final void Function(int index, double value) onVolumeChanged;
  final void Function(int index) onRemoveAt;
  final VoidCallback onConfirmAll;
  final VoidCallback onContinueVoice;
  final VoidCallback onRetry;
  final String? transcript;
  final String? inlineError;
  final List<String> rosterNames;
  final Set<String> activeEntryNames;
  final bool isProcessing;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final isMulti = drafts.length > 1;
    final title = isMulti ? '核对进场名单（${drafts.length} 人）' : '核对进场信息';
    final subtitle = isMulti
        ? '确认名单（${drafts.length} 人）：请下滑核对后一次性确认'
        : '待确认 · 请核对姓名、气瓶压力与容积';

    final primaryLabel = isMulti
        ? '全部确认进入火场（${drafts.length} 人）'
        : '确认进入火场，开始倒计时';

    return CommandSheet(
      key: const Key('voice-confirm-sheet'),
      title: title,
      subtitle: subtitle,
      showCloseButton: showCloseButton,
      contentPadding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.md,
        DsSpacing.lg,
        DsSpacing.md,
      ),
      actions: <Widget>[
        _ConfirmSheetFooter(
          inlineError: inlineError,
          primaryLabel: primaryLabel,
          isProcessing: isProcessing,
          canConfirm: drafts.isNotEmpty,
          onConfirmAll: onConfirmAll,
          onContinueVoice: onContinueVoice,
          onRetry: onRetry,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (transcript != null && transcript!.trim().isNotEmpty) ...<Widget>[
            _TranscriptBar(transcript: transcript!.trim()),
            const SizedBox(height: DsSpacing.md),
          ],
          if (drafts.isEmpty)
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              child: Text(
                '未识别到人员信息，请重新语音输入',
                textAlign: TextAlign.center,
                style: ds.typography.body.copyWith(color: colors.textSecondary),
              ),
            )
          else
            for (var i = 0; i < drafts.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: DsSpacing.md),
              VoicePersonEditorCard(
                index: i,
                draft: drafts[i],
                calcParams: calcParams,
                rosterNames: rosterNames,
                isDuplicateActive: activeEntryNames.contains(
                  drafts[i].trimmedName,
                ),
                showHeader: isMulti,
                enabled: !isProcessing,
                onNameChanged: (String v) => onNameChanged(i, v),
                onPressureChanged: (String v) => onPressureChanged(i, v),
                onVolumeChanged: (double v) => onVolumeChanged(i, v),
                onRemove: () => onRemoveAt(i),
              ),
            ],
        ],
      ),
    );
  }
}

class _TranscriptBar extends StatelessWidget {
  const _TranscriptBar({required this.transcript});

  final String transcript;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: DsRadius.borderSm,
        border: Border.all(color: colors.border, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.graphic_eq_rounded,
              size: DsSizes.iconSm,
              color: colors.brandText,
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          Text(
            '转写',
            style: ds.typography.caption.copyWith(
              color: colors.textTertiary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              transcript,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: ds.typography.caption.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmSheetFooter extends StatelessWidget {
  const _ConfirmSheetFooter({
    required this.inlineError,
    required this.primaryLabel,
    required this.isProcessing,
    required this.canConfirm,
    required this.onConfirmAll,
    required this.onContinueVoice,
    required this.onRetry,
  });

  final String? inlineError;
  final String primaryLabel;
  final bool isProcessing;
  final bool canConfirm;
  final VoidCallback onConfirmAll;
  final VoidCallback onContinueVoice;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final alarm = colors.statusColors(DsStatus.alarm);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (inlineError != null && inlineError!.trim().isNotEmpty) ...<Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.md,
              vertical: DsSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: alarm.pillBg,
              borderRadius: DsRadius.borderSm,
              border: Border.all(
                color: alarm.fill.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: DsSizes.iconSm,
                    color: alarm.text,
                  ),
                ),
                const SizedBox(width: DsSpacing.sm),
                Expanded(
                  child: Text(
                    inlineError!,
                    style: ds.typography.caption.copyWith(
                      color: alarm.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
        ],
        CommandButton(
          key: const Key('voice-confirm-all-btn'),
          label: primaryLabel,
          icon: Icons.check_circle_outline_rounded,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          isLoading: isProcessing,
          enabled: canConfirm && !isProcessing,
          onPressed: onConfirmAll,
        ),
        const SizedBox(height: DsSpacing.sm),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(1.0);
            final stacked = constraints.maxWidth < 290 || textScale > 1.25;
            final retryBtn = CommandButton(
              label: '重新语音输入',
              icon: Icons.replay_rounded,
              variant: CommandButtonVariant.ghost,
              size: CommandButtonSize.standard,
              expanded: stacked,
              enabled: !isProcessing,
              onPressed: onRetry,
            );
            final continueBtn = CommandButton(
              key: const Key('voice-continue-record-btn'),
              label: '继续语音添加',
              icon: Icons.mic_none_rounded,
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              expanded: stacked,
              enabled: !isProcessing,
              onPressed: onContinueVoice,
            );
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  continueBtn,
                  const SizedBox(height: DsSpacing.xs),
                  retryBtn,
                ],
              );
            }
            return Row(
              children: <Widget>[
                Expanded(child: retryBtn),
                const SizedBox(width: DsSpacing.sm),
                Expanded(child: continueBtn),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 以模态底部弹窗展示 [VoiceConfirmSheet]。
Future<void> showVoiceConfirmSheet({
  required BuildContext context,
  required WidgetBuilder sheetBuilder,
  bool isDismissible = true,
  bool useRootNavigator = false,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    useRootNavigator: useRootNavigator,
    builder: (BuildContext routeContext) => Theme(
      data: capturedTheme,
      child: MediaQuery(
        data: capturedMediaQuery.copyWith(
          viewInsets: MediaQuery.viewInsetsOf(routeContext),
          padding: MediaQuery.paddingOf(routeContext),
          viewPadding: MediaQuery.viewPaddingOf(routeContext),
        ),
        child: Builder(builder: sheetBuilder),
      ),
    ),
  );
}
