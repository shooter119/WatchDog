import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 离线冲突复核时的服务端在场人员快照（隔离 `features/monitor/` 跨 Feature 依赖）。
@immutable
class OfflineReviewEntrySnapshot {
  const OfflineReviewEntrySnapshot({
    required this.id,
    required this.name,
    required this.isActive,
    required this.version,
    this.pressureMpa,
    this.consumptionLpm,
  });

  final String id;
  final String name;
  final bool isActive;
  final int version;
  final double? pressureMpa;
  final double? consumptionLpm;
}

/// 离线冲突复核页的数据与提交网关。
abstract class OfflineReviewGateway {
  Listenable? get changes => null;

  bool get isAuthorized;

  Future<bool> isIncidentActive(String incidentId);

  Future<OfflineReviewEntrySnapshot?> fetchEntrySnapshot({
    required String incidentId,
    required String entryId,
  });

  Future<void> submitReviewedOperation({
    required String incidentId,
    required String type,
    required Map<String, dynamic> payload,
    required String originalOpId,
    required String newOpId,
    int? expectedVersion,
  });

  Future<void> syncAfterReview();
}

/// 单条离线冲突待核对记录卡片。
class OfflineReviewRecordCard extends StatelessWidget {
  const OfflineReviewRecordCard({
    super.key,
    required this.timestamp,
    required this.description,
    required this.result,
    required this.isLegacy,
    required this.hasRetryRequest,
    required this.busy,
    required this.onClaim,
    required this.onDiscard,
    required this.onApply,
  });

  final String timestamp;
  final String description;
  final String result;
  final bool isLegacy;
  final bool hasRetryRequest;
  final bool busy;
  final VoidCallback onClaim;
  final VoidCallback onDiscard;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            timestamp,
            style: typo.captionTabular.copyWith(
              color: colors.textTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            description,
            style: typo.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            result,
            style: typo.body.copyWith(color: colors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: DsSpacing.md),
          if (isLegacy)
            CommandButton(
              label: '确认本人旧记录',
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              enabled: !busy,
              onPressed: onClaim,
            )
          else
            Wrap(
              spacing: DsSpacing.sm,
              runSpacing: DsSpacing.sm,
              children: <Widget>[
                CommandButton(
                  label: '保留记录，不应用',
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.standard,
                  enabled: !busy && !hasRetryRequest,
                  onPressed: onDiscard,
                ),
                CommandButton(
                  label: hasRetryRequest ? '重试已确认的提交' : '核对后重新提交',
                  variant: CommandButtonVariant.primary,
                  size: CommandButtonSize.standard,
                  enabled: !busy,
                  onPressed: onApply,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String formatOfflineReviewTime(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  String pad(int v) => v.toString().padLeft(2, '0');
  return '${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)}';
}
