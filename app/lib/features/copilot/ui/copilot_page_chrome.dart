import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 通过 DS v3.0 [CommandSheet] 确认清空当前场景问答历史。
Future<bool> showCopilotClearConfirmSheet(BuildContext context) async {
  final confirmed = await showCommandSheet<bool>(
    context: context,
    title: '清空问答记录',
    builder: (BuildContext sheetContext) {
      final ds = sheetContext.ds;
      return Text(
        '将删除本场景下与「辅助」的全部对话历史，确定清空？',
        style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
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
        label: '清空',
        variant: CommandButtonVariant.danger,
        size: CommandButtonSize.large,
        requireConfirmation: false,
        onPressed: () => Navigator.of(sheetContext).pop(true),
      ),
    ],
  );
  return confirmed == true;
}

/// 智能辅助顶栏（标题 + 清空记录 + 历史通用对话）。
class CopilotHeaderBar extends StatelessWidget {
  const CopilotHeaderBar({
    super.key,
    required this.hasMessages,
    required this.canClear,
    required this.onClearTap,
    required this.onLegacyHistoryTap,
  });

  final bool hasMessages;
  final bool canClear;
  final VoidCallback onClearTap;
  final VoidCallback onLegacyHistoryTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Container(
      key: const Key('chat-header'),
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.md,
        DsSpacing.sm,
        DsSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              '辅助问答',
              style: ds.typography.headline.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (hasMessages)
            IconButton(
              onPressed: canClear ? onClearTap : null,
              icon: const Icon(
                DsIcons.clearSweep,
                size: DsSizes.iconLg,
              ),
              tooltip: '清空问答记录',
              constraints: const BoxConstraints(
                minWidth: DsSizes.touchTarget,
                minHeight: DsSizes.touchTarget,
              ),
              color: colors.textTertiary,
            ),
          IconButton(
            onPressed: onLegacyHistoryTap,
            tooltip: '历史通用对话',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            icon: const Icon(DsIcons.opLog, size: DsSizes.iconLg),
            color: colors.textTertiary,
          ),
        ],
      ),
    );
  }
}

/// 顶部当前警情上下文胶囊（≥48dp 触控热区，点击直达警情详情）。
class CopilotIncidentContextPill extends StatelessWidget {
  const CopilotIncidentContextPill({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Padding(
      padding: const EdgeInsets.only(
        left: DsSpacing.lg,
        right: DsSpacing.lg,
        bottom: DsSpacing.sm,
      ),
      child: Material(
        color: colors.surfaceMuted,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderPill,
          side: BorderSide(color: colors.border, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('chat-incident-context-pill'),
          borderRadius: DsRadius.borderPill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.lg,
                vertical: DsSpacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    DsIcons.info,
                    size: DsSizes.iconSm,
                    color: colors.brandText,
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  Flexible(
                    child: Text(
                      '已结合当前警情资料 · 查看背景',
                      style: ds.typography.caption.copyWith(
                        color: colors.brandText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: DsSpacing.xs),
                  Icon(
                    DsIcons.chevronRight,
                    size: DsSizes.iconSm + 2,
                    color: colors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 60 秒录音时长与 50 秒预警双通道状态条（等宽数字）。
class CopilotRecordingBanner extends StatelessWidget {
  const CopilotRecordingBanner({
    super.key,
    required this.isWarning,
    required this.recordingSeconds,
    required this.remainingSeconds,
  });

  final bool isWarning;
  final int recordingSeconds;
  final int remainingSeconds;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final cautionPair = colors.statusColors(DsStatus.caution);
    final bg = isWarning
        ? cautionPair.pillBg
        : colors.brand.withValues(alpha: 0.10);
    final fg = isWarning ? cautionPair.text : colors.brandText;
    final border = isWarning
        ? cautionPair.fill.withValues(alpha: 0.30)
        : colors.brand.withValues(alpha: 0.24);
    final text = isWarning
        ? '录音还剩 $remainingSeconds 秒，时间到将自动结束'
        : '录音中 · 最长 60 秒 · 已录 $recordingSeconds 秒';

    return Container(
      key: const Key('chat-recording-limit'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        0,
        DsSpacing.lg,
        DsSpacing.sm,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: DsRadius.borderSm,
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            isWarning ? DsIcons.warning : DsIcons.voiceFill,
            size: DsSizes.iconSm,
            color: fg,
          ),
          const SizedBox(width: DsSpacing.xs),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: ds.typography.captionTabular.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 实时语音转写预览条。
class CopilotTranscriptBanner extends StatelessWidget {
  const CopilotTranscriptBanner({super.key, required this.transcript});

  final String? transcript;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final text = transcript?.trim();
    final hasText = text != null && text.isNotEmpty;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.xs,
        DsSpacing.lg,
        DsSpacing.sm,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.md,
      ),
      decoration: BoxDecoration(
        color: colors.brand.withValues(alpha: 0.10),
        borderRadius: DsRadius.borderSm,
        border: Border.all(color: colors.brand.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            hasText ? DsIcons.soundWave : DsIcons.voiceLine,
            size: DsSizes.iconMd - 2,
            color: colors.brandText,
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              hasText ? text : '正在识别语音…',
              style: ds.typography.body.copyWith(
                height: 1.5,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 左右下角 48dp 圆形悬浮操作钮（键盘切输入 / 拍照识险）。
class CopilotFloatingCircleButton extends StatelessWidget {
  const CopilotFloatingCircleButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: ds.brightness == Brightness.light
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x140F172A),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Material(
        color: colors.surface,
        shape: CircleBorder(side: BorderSide(color: colors.border, width: 1)),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
            minWidth: DsSizes.touchTarget,
            minHeight: DsSizes.touchTarget,
          ),
          icon: icon,
        ),
      ),
    );
  }
}

/// 临时悬浮文字输入条（保留草稿跨主题切换不丢失）。
class CopilotTextComposerBar extends StatelessWidget {
  const CopilotTextComposerBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.clearing,
    required this.onClose,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool clearing;
  final VoidCallback onClose;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return SurfaceCard(
      key: const Key('chat-text-composer'),
      level: DsSurfaceLevel.raised,
      borderRadius: DsRadius.borderXl,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm,
        vertical: DsSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          IconButton(
            key: const Key('chat-close-text-mode'),
            onPressed: onClose,
            tooltip: '收起文字输入',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            color: colors.textSecondary,
            icon: const Icon(DsIcons.chevronDown, size: 22),
          ),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 112),
              child: TextField(
                key: const Key('chat-text-field'),
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                style: ds.typography.body.copyWith(color: colors.textPrimary),
                cursorColor: colors.brand,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSubmit(),
                decoration: InputDecoration(
                  hintText: '输入现场问题…',
                  hintStyle: ds.typography.body.copyWith(
                    color: colors.textTertiary,
                  ),
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.sm,
                    vertical: DsSpacing.md,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: DsSpacing.xs),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (BuildContext context, TextEditingValue value, _) {
              final canSend =
                  !sending && !clearing && value.text.trim().isNotEmpty;
              return FilledButton(
                key: const Key('chat-send-button'),
                onPressed: canSend ? onSubmit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: colors.brand,
                  foregroundColor: colors.onBrand,
                  minimumSize: const Size(
                    DsSizes.touchTarget,
                    DsSizes.touchTarget,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md),
                  shape: const RoundedRectangleBorder(
                    borderRadius: DsRadius.borderMd,
                  ),
                ),
                child: sending
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          value: disableAnimations ? 0.72 : null,
                          strokeWidth: 2,
                          color: colors.onBrand,
                        ),
                      )
                    : const Icon(DsIcons.send, size: DsSizes.iconMd),
              );
            },
          ),
        ],
      ),
    );
  }
}
