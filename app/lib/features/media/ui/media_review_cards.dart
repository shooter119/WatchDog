import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/local_asr_service.dart';
import '../../../services/local_media_store.dart';

export 'media_photo_viewer_page.dart';

/// 媒体元数据与保存范围说明卡。
class MediaInfoCard extends StatelessWidget {
  const MediaInfoCard({
    super.key,
    required this.media,
    required this.durationText,
    required this.timeText,
    required this.submitted,
  });

  final LocalMedia media;
  final String durationText;
  final String timeText;
  final bool submitted;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    media.isVideo
                        ? Icons.videocam_rounded
                        : Icons.photo_rounded,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    durationText,
                    style: DsTypography.tabular(
                      typo.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
              if (submitted)
                const StatusPill(
                  status: DsStatus.safe,
                  label: '已写入警情',
                  icon: Icons.check_circle_outline,
                )
              else if (media.incidentId.isEmpty)
                const StatusPill(
                  status: DsStatus.caution,
                  label: '未关联',
                  icon: Icons.link_off,
                ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          Text(
            timeText,
            style: DsTypography.tabular(
              typo.caption.copyWith(color: colors.textSecondary),
            ),
          ),
          if (media.address.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: DsSpacing.xs),
              child: Text(
                media.weather.isEmpty
                    ? media.address
                    : '${media.address} · ${media.weather}',
                style: typo.caption.copyWith(color: colors.textSecondary),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            media.sourcePath.isEmpty
                ? '旧资料没有无水印母版，本次只能保存带水印版；保存成功后将从本机记录中移除'
                : '拍摄文件仅用于本次核对；保存成功后将从 App 清理，手机相册保留带水印版和无水印版',
            style: typo.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 视频离线/联网口述识别进行中状态卡。
class MediaDerivingCard extends StatelessWidget {
  const MediaDerivingCard({
    super.key,
    required this.stage,
    required this.onCancel,
  });

  final String stage;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(
        vertical: DsSpacing.xl,
        horizontal: DsSpacing.lg,
      ),
      child: Column(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              value: disableAnimations ? 0.72 : null,
              strokeWidth: 2.4,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          Text(
            stage.isEmpty ? '正在处理…' : stage,
            textAlign: TextAlign.center,
            style: typo.body.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            '识别在本机完成，不上传音频',
            textAlign: TextAlign.center,
            style: typo.caption.copyWith(color: colors.textTertiary),
          ),
          const SizedBox(height: DsSpacing.sm),
          CommandButton(
            label: '取消识别',
            icon: Icons.close_rounded,
            variant: CommandButtonVariant.ghost,
            size: CommandButtonSize.standard,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// 视频口述识别失败提示与重试卡。
class MediaDeriveErrorCard extends StatelessWidget {
  const MediaDeriveErrorCard({
    super.key,
    required this.errorMessage,
    required this.onDismiss,
    required this.onRetry,
  });

  final String errorMessage;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      accentStatus: DsStatus.alarm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: colors.alarmText,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  errorMessage,
                  style: typo.body.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: DsSpacing.sm,
              runSpacing: DsSpacing.xs,
              children: [
                CommandButton(
                  label: '手动填写',
                  variant: CommandButtonVariant.ghost,
                  size: CommandButtonSize.standard,
                  onPressed: onDismiss,
                ),
                CommandButton(
                  label: '重试识别',
                  icon: Icons.refresh_rounded,
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.standard,
                  onPressed: onRetry,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 现场口述核对、写入警情入口及可撤销删除的分段标签卡。
class MediaTranscriptCard extends StatelessWidget {
  const MediaTranscriptCard({
    super.key,
    required this.controller,
    required this.segments,
    required this.hasText,
    required this.hasIncident,
    required this.submitted,
    required this.busy,
    required this.deriving,
    required this.onConfirmAndSubmit,
    required this.onRemoveSegment,
  });

  final TextEditingController controller;
  final List<LocalAsrSegment> segments;
  final bool hasText;
  final bool hasIncident;
  final bool submitted;
  final bool busy;
  final bool deriving;
  final VoidCallback onConfirmAndSubmit;
  final ValueChanged<LocalAsrSegment> onRemoveSegment;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '现场口述（请核对后再使用）',
            style: typo.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.sm),
          TextField(
            controller: controller,
            maxLines: null,
            minLines: 4,
            style: typo.body.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: '没有识别到口述内容时，可以在这里手动补写',
              hintStyle: typo.body.copyWith(color: colors.textTertiary),
              filled: true,
              fillColor: colors.surfaceMuted,
              border: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.brand, width: 1.5),
              ),
              contentPadding: const EdgeInsets.all(DsSpacing.md),
            ),
          ),
          if (hasText && hasIncident && !submitted) ...[
            const SizedBox(height: DsSpacing.md),
            CommandButton(
              label: '核对无误，写入警情',
              icon: Icons.fact_check_outlined,
              variant: CommandButtonVariant.primary,
              size: CommandButtonSize.standard,
              expanded: true,
              enabled: !busy && !deriving,
              onPressed: onConfirmAndSubmit,
            ),
          ] else if (hasText && !hasIncident) ...[
            const SizedBox(height: DsSpacing.sm),
            Text(
              '关联警情后可在这里核对并写入；当前口述只会保存在本机草稿。',
              style: typo.caption.copyWith(color: colors.textSecondary),
            ),
          ],
          if (segments.isNotEmpty) ...[
            const SizedBox(height: DsSpacing.md),
            Text(
              '按住片段可删除误识别内容，删除后可撤销',
              style: typo.caption.copyWith(color: colors.textTertiary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final segment in segments)
                  GestureDetector(
                    key: Key('segment-chip-${segment.startMs}'),
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () => onRemoveSegment(segment),
                    child: Container(
                      constraints: const BoxConstraints(
                        minHeight: DsSizes.touchTarget,
                      ),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: DsSpacing.md,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceMuted,
                        borderRadius: DsRadius.borderPill,
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(
                        '${_formatOffset(segment.startMs)}  ${segment.text}',
                        style: DsTypography.tabular(
                          typo.caption.copyWith(color: colors.textSecondary),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _formatOffset(int ms) {
    final seconds = (ms / 1000).floor();
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
