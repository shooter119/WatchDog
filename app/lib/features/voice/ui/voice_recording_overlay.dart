import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/screen_on.dart';
import '../state/voice_session_types.dart';

/// 全局跨页语音录音 / 识别中 / 错误提示浮层。
///
/// 挂载于新外壳根部，在任意非智能辅助 Tab 长按中置语音键后原地浮出：
/// - 录音中：品牌蓝脉冲环（严格尊重 `MediaQuery.disableAnimations`）、实时转写字幕、
///   60 秒计时与 50 秒余量预警、分批追加提示、兜底停止按钮；
/// - 识别中：高对比进度指示；
/// - 错误态：权限被拒时提供「去系统设置」引导，并保留「返回确认」入口。
class VoiceRecordingOverlay extends StatelessWidget {
  const VoiceRecordingOverlay({
    super.key,
    required this.status,
    this.recordingSeconds = 0,
    this.maxRecordingSeconds = 60,
    this.warningRecordingSeconds = 50,
    this.amplitude = 0.15,
    this.liveTranscript,
    this.pendingDraftCount = 0,
    this.errorMessage,
    this.permissionDenied = false,
    this.onStopRecording,
    this.onRetry,
    this.onOpenSettings,
    this.onReturnToConfirm,
    this.onDismiss,
  });

  final VoiceSessionStatus status;
  final int recordingSeconds;
  final int maxRecordingSeconds;
  final int warningRecordingSeconds;
  final double amplitude;
  final String? liveTranscript;
  final int pendingDraftCount;
  final String? errorMessage;
  final bool permissionDenied;
  final VoidCallback? onStopRecording;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onReturnToConfirm;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return Positioned.fill(
      key: const Key('voice-recording-overlay'),
      child: Material(
        color: colors.canvas.withValues(alpha: 0.86),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(DsSpacing.pageMargin),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: SurfaceCard(
                  level: DsSurfaceLevel.raised,
                  accentStatus: status == VoiceSessionStatus.error
                      ? DsStatus.caution
                      : null,
                  padding: const EdgeInsets.all(DsSpacing.xl),
                  child: switch (status) {
                    VoiceSessionStatus.recording => _buildRecordingContent(
                      context,
                      disableAnimations: disableAnimations,
                    ),
                    VoiceSessionStatus.processing => _buildProcessingContent(
                      context,
                      disableAnimations: disableAnimations,
                    ),
                    VoiceSessionStatus.error => _buildErrorContent(context),
                    VoiceSessionStatus.idle ||
                    VoiceSessionStatus.confirming => const SizedBox.shrink(),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingContent(
    BuildContext context, {
    required bool disableAnimations,
  }) {
    final ds = context.ds;
    final colors = ds.colors;
    final remaining = math.max(0, maxRecordingSeconds - recordingSeconds);
    final isWarning = recordingSeconds >= warningRecordingSeconds;
    final hasTranscript =
        liveTranscript != null && liveTranscript!.trim().isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _VoicePulseRing(
          intensity: amplitude,
          disableAnimations: disableAnimations,
        ),
        const SizedBox(height: DsSpacing.lg),
        Text(
          '请清晰说出：姓名 + 气瓶压力',
          textAlign: TextAlign.center,
          style: ds.typography.title.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          '或：出火场人员姓名 / 现场日志 / 战术提问',
          textAlign: TextAlign.center,
          style: ds.typography.body.copyWith(color: colors.textSecondary),
        ),
        if (hasTranscript) ...<Widget>[
          const SizedBox(height: DsSpacing.lg),
          Container(
            key: const Key('voice-live-transcript'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.md,
              vertical: DsSpacing.sm + 2,
            ),
            decoration: BoxDecoration(
              color: colors.brand.withValues(alpha: 0.08),
              borderRadius: DsRadius.borderMd,
              border: Border.all(
                color: colors.brand.withValues(alpha: 0.24),
                width: 1,
              ),
            ),
            child: Text(
              liveTranscript!.trim(),
              textAlign: TextAlign.center,
              style: ds.typography.body.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
        const SizedBox(height: DsSpacing.md),
        Container(
          key: const Key('voice-recording-timer'),
          padding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.md,
            vertical: DsSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: isWarning
                ? colors.statusColors(DsStatus.caution).pillBg
                : colors.surfaceMuted,
            borderRadius: DsRadius.borderPill,
            border: Border.all(
              color: isWarning
                  ? colors.cautionFill.withValues(alpha: 0.35)
                  : colors.border,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                isWarning ? Icons.timer_outlined : Icons.graphic_eq_rounded,
                size: DsSizes.iconSm,
                color: isWarning ? colors.cautionText : colors.brandText,
              ),
              const SizedBox(width: DsSpacing.xs + 2),
              Flexible(
                child: Text(
                  isWarning
                      ? '还剩 $remaining 秒，时间到将自动结束'
                      : '最长录音 $maxRecordingSeconds 秒 · 已录 $recordingSeconds 秒',
                  textAlign: TextAlign.center,
                  style: DsTypography.tabular(ds.typography.caption).copyWith(
                    color: isWarning ? colors.cautionText : colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (pendingDraftCount > 0) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Text(
            '已录入 $pendingDraftCount 人，本次语音将追加到名单',
            textAlign: TextAlign.center,
            style: ds.typography.caption.copyWith(
              color: colors.brandText,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (onStopRecording != null) ...<Widget>[
          const SizedBox(height: DsSpacing.lg),
          CommandButton(
            label: '完成并识别',
            icon: Icons.stop_circle_outlined,
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            expanded: true,
            onPressed: onStopRecording,
          ),
        ],
      ],
    );
  }

  Widget _buildProcessingContent(
    BuildContext context, {
    required bool disableAnimations,
  }) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(
            value: disableAnimations ? 0.72 : null,
            strokeWidth: 3,
            color: colors.brand,
          ),
        ),
        const SizedBox(height: DsSpacing.md),
        Text(
          '语音转文字中…',
          textAlign: TextAlign.center,
          style: ds.typography.title.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          '正在自动识别进出场、日志或战术提问',
          textAlign: TextAlign.center,
          style: ds.typography.caption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildErrorContent(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Align(
          alignment: Alignment.center,
          child: StatusPill(
            status: DsStatus.caution,
            label: '语音录入提示',
          ),
        ),
        const SizedBox(height: DsSpacing.md),
        Text(
          errorMessage ?? '未识别到有效语音，请重试',
          textAlign: TextAlign.center,
          style: ds.typography.title.copyWith(color: colors.textPrimary),
        ),
        if (permissionDenied) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Text(
            '请前往系统应用设置开启麦克风权限，开启后即可长按底部语音键快速录入。',
            textAlign: TextAlign.center,
            style: ds.typography.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: DsSpacing.lg),
          CommandButton(
            label: '去系统设置',
            icon: Icons.settings_outlined,
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            expanded: true,
            onPressed: onOpenSettings ?? () => ScreenOn.openAppSettings(),
          ),
        ],
        const SizedBox(height: DsSpacing.md),
        CommandButton(
          label: '重新语音输入',
          icon: Icons.replay_rounded,
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.standard,
          expanded: true,
          onPressed: onRetry ?? onDismiss,
        ),
        if (pendingDraftCount > 0 && onReturnToConfirm != null) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          CommandButton(
            label: '返回确认（$pendingDraftCount 人）',
            variant: CommandButtonVariant.ghost,
            size: CommandButtonSize.standard,
            expanded: true,
            onPressed: onReturnToConfirm,
          ),
        ],
      ],
    );
  }
}

/// 品牌蓝脉冲麦克风圆环，严格限制在固定尺寸容器内并尊重 `disableAnimations`。
class _VoicePulseRing extends StatelessWidget {
  const _VoicePulseRing({
    required this.intensity,
    required this.disableAnimations,
  });

  final double intensity;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final clamped = intensity.clamp(0.0, 1.0);
    final outerScale = disableAnimations ? 1.0 : 0.94 + clamped * 0.12;
    final innerScale = disableAnimations ? 1.0 : 0.96 + clamped * 0.06;
    final duration = disableAnimations ? Duration.zero : DsMotion.fast;

    return SizedBox(
      width: 112,
      height: 112,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          AnimatedScale(
            scale: outerScale,
            duration: duration,
            curve: DsMotion.enter,
            child: Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.brand.withValues(alpha: 0.10),
                border: Border.all(
                  color: colors.brand.withValues(alpha: 0.36),
                  width: 1.5,
                ),
              ),
            ),
          ),
          AnimatedScale(
            scale: innerScale,
            duration: duration,
            curve: DsMotion.enter,
            child: Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.brand,
              ),
              child: Icon(
                Icons.mic_rounded,
                size: 38,
                color: colors.onBrand,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
