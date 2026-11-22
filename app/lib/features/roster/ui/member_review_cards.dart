import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 待审批入队成员视图模型（隔离 `features/auth/` 跨 Feature 依赖）。
@immutable
class PendingMemberView {
  const PendingMemberView({
    required this.id,
    required this.realName,
    this.stationName = '',
    this.applyReason = '',
    this.createdAt = 0,
    this.inRoster = false,
  });

  final String id;
  final String realName;
  final String stationName;
  final String applyReason;
  final int createdAt;
  final bool inRoster;
}

/// 已处理入队审批记录视图模型。
@immutable
class MemberReviewHistoryItem {
  const MemberReviewHistoryItem({
    required this.id,
    required this.realName,
    required this.reviewStatus,
    this.reviewerName = '',
    this.reviewedAt,
  });

  final String id;
  final String realName;
  final String reviewStatus;
  final String reviewerName;
  final dynamic reviewedAt;

  bool get isApproved => reviewStatus == 'approved';

  factory MemberReviewHistoryItem.fromMap(Map<String, dynamic> map) =>
      MemberReviewHistoryItem(
        id: map['id']?.toString() ?? '',
        realName: map['real_name']?.toString() ?? '',
        reviewStatus: map['review_status']?.toString() ?? '',
        reviewerName: map['reviewer_name']?.toString() ?? '',
        reviewedAt: map['reviewed_at'],
      );
}

/// 入队审批页的数据与权限网关。
abstract class MemberReviewGateway {
  Listenable? get changes => null;

  int get protectedDataEpoch;
  bool get protectedDataRevoked;
  bool get needsAuthentication;
  bool get canReviewMembers;
  bool get isLoading;
  String? get error;
  String get unitName;

  List<PendingMemberView> get pendingMembers;
  List<MemberReviewHistoryItem> get reviewHistory;

  Future<void> refresh();
  Future<void> approveMember(String memberId);
  Future<void> rejectMember(String memberId);
  Future<List<MemberReviewHistoryItem>> fetchHistoryPage({required int offset});
  void appendHistoryPage(List<MemberReviewHistoryItem> rows);
}

class MemberReviewErrorBanner extends StatelessWidget {
  const MemberReviewErrorBanner({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final alarmPair = ds.colors.statusColors(DsStatus.alarm);
    return SurfaceCard(
      accentStatus: DsStatus.alarm,
      backgroundColor: alarmPair.pillBg,
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Row(
        children: <Widget>[
          Icon(
            DsIcons.warning,
            color: alarmPair.text,
            size: DsSizes.iconMd,
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: ds.typography.body.copyWith(color: alarmPair.text),
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          CommandButton(
            label: '重试',
            variant: CommandButtonVariant.ghost,
            size: CommandButtonSize.standard,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class PendingMemberCard extends StatelessWidget {
  const PendingMemberCard({
    super.key,
    required this.member,
    required this.unitName,
    required this.appliedAtText,
    required this.busy,
    required this.onReject,
    required this.onApprove,
  });

  final PendingMemberView member;
  final String unitName;
  final String appliedAtText;
  final bool busy;
  final VoidCallback onReject;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                member.realName,
                style: typo.title.copyWith(color: colors.textPrimary),
              ),
              if (member.inRoster)
                const StatusPill(
                  status: DsStatus.neutral,
                  icon: DsIcons.speak,
                  label: '已在语音名单',
                ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          Text(
            '申请单位：$unitName',
            style: typo.body.copyWith(color: colors.textSecondary),
          ),
          if (member.stationName.isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.xs),
            Text(
              '所属站：${member.stationName}',
              style: typo.body.copyWith(color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: DsSpacing.xs),
          Text(
            '申请时间：$appliedAtText',
            style: typo.captionTabular.copyWith(color: colors.textTertiary),
          ),
          if (member.applyReason.isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.xs),
            Text(
              '申请说明：${member.applyReason}',
              style: typo.body.copyWith(color: colors.textSecondary),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.md),
            child: Divider(height: 1, color: colors.border),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: DsSpacing.md,
              runSpacing: DsSpacing.sm,
              alignment: WrapAlignment.end,
              children: <Widget>[
                CommandButton(
                  label: '驳回',
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.standard,
                  enabled: !busy,
                  onPressed: onReject,
                ),
                CommandButton(
                  label: busy ? '处理中' : '同意入队',
                  variant: CommandButtonVariant.primary,
                  size: CommandButtonSize.standard,
                  isLoading: busy,
                  onPressed: onApprove,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ReviewHistoryCard extends StatelessWidget {
  const ReviewHistoryCard({
    super.key,
    required this.item,
    required this.reviewedAtText,
  });

  final MemberReviewHistoryItem item;
  final String reviewedAtText;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final reviewer = item.reviewerName.isEmpty ? '历史记录未保存' : item.reviewerName;

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.lg,
        vertical: DsSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                item.realName,
                style: typo.title.copyWith(color: colors.textPrimary),
              ),
              StatusPill(
                status: item.isApproved ? DsStatus.safe : DsStatus.neutral,
                icon: item.isApproved
                    ? DsIcons.check
                    : DsIcons.close,
                label: item.isApproved ? '已同意' : '已驳回',
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            '处理人：$reviewer',
            style: typo.caption.copyWith(color: colors.textSecondary),
          ),
          Text(
            reviewedAtText,
            style: typo.captionTabular.copyWith(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}
