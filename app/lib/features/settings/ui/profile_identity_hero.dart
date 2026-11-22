import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/settings_store.dart';

/// 「我的」Tab 二级页面导航回调集合（零跨 Feature 导入，由外壳统一装配）。
class ProfileHubRoutes {
  const ProfileHubRoutes({
    this.onOpenWatermarkSettings,
    this.onOpenVideoAdmin,
    this.onOpenMemberReview,
    this.onOpenRoster,
    this.onOpenUnitStations,
    this.onOpenArchivedIncidents,
    this.onOpenStats,
    this.onOpenOpLog,
    this.onOpenLoginDevices,
    this.onOpenOfflineReview,
    this.onOpenAdminScanner,
    this.onOpenAbout,
    this.onOpenComponentGallery,
    this.onFlushOpLogs,
  });

  final Future<void> Function(BuildContext context)? onOpenWatermarkSettings;
  final Future<void> Function(BuildContext context)? onOpenVideoAdmin;
  final Future<void> Function(BuildContext context)? onOpenMemberReview;
  final Future<void> Function(BuildContext context)? onOpenRoster;
  final Future<void> Function(BuildContext context)? onOpenUnitStations;
  final Future<void> Function(BuildContext context)? onOpenArchivedIncidents;
  final Future<void> Function(BuildContext context)? onOpenStats;
  final Future<void> Function(BuildContext context)? onOpenOpLog;
  final Future<void> Function(BuildContext context)? onOpenLoginDevices;
  final Future<void> Function(BuildContext context)? onOpenOfflineReview;
  final Future<void> Function(BuildContext context)? onOpenAdminScanner;
  final Future<void> Function(BuildContext context)? onOpenAbout;
  final Future<void> Function(BuildContext context)? onOpenComponentGallery;
  final Future<void> Function()? onFlushOpLogs;
}

/// 「我的」Tab 顶部身份 Hero 卡片：实名、所属单位、角色胶囊、扫码入口与游客引导。
class ProfileIdentityHeroCard extends StatelessWidget {
  const ProfileIdentityHeroCard({
    super.key,
    required this.identity,
    required this.onDevices,
    required this.onReview,
    required this.onLeave,
    required this.onJoin,
    required this.onScan,
  });

  final SettingsIdentitySnapshot identity;
  final Future<void>? Function() onDevices;
  final Future<void>? Function() onReview;
  final Future<void> Function() onLeave;
  final VoidCallback onJoin;
  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final authenticated = identity.effectiveAuthenticated;
    final roleStatus = identity.isGuest
        ? DsStatus.neutral
        : authenticated
        ? DsStatus.safe
        : DsStatus.caution;
    final roleIcon = identity.isGuest
        ? DsIcons.user
        : authenticated
        ? DsIcons.verified
        : DsIcons.shield;

    return SurfaceCard(
      key: const Key('identity-hero'),
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Wrap(
                      spacing: DsSpacing.sm,
                      runSpacing: DsSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          identity.displayName,
                          softWrap: true,
                          style: ds.typography.headline.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        StatusPill(
                          status: roleStatus,
                          icon: roleIcon,
                          label: identity.displayRole,
                        ),
                      ],
                    ),
                    const SizedBox(height: DsSpacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            DsIcons.unit,
                            size: DsSizes.iconSm,
                            color: colors.textTertiary,
                          ),
                        ),
                        const SizedBox(width: DsSpacing.sm),
                        Expanded(
                          child: Text(
                            identity.displayUnit,
                            softWrap: true,
                            style: ds.typography.body.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (authenticated)
                PopupMenuButton<String>(
                  key: const Key('user-actions'),
                  tooltip: '用户操作',
                  iconColor: colors.textSecondary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: DsSizes.touchTarget,
                    minHeight: DsSizes.touchTarget,
                  ),
                  onSelected: (value) {
                    if (value == 'leave') unawaited(onLeave());
                    if (value == 'devices') onDevices();
                    if (value == 'review') onReview();
                  },
                  itemBuilder: (_) => const <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(value: 'devices', child: Text('登录设备')),
                    PopupMenuItem<String>(
                      value: 'review',
                      child: Text('离线记录待核对'),
                    ),
                    PopupMenuItem<String>(
                      value: 'leave',
                      child: Text('退出当前单位'),
                    ),
                  ],
                ),
            ],
          ),
          if (authenticated && identity.offlineReviewCount > 0) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(
                    DsSizes.touchTarget,
                    DsSizes.touchTarget,
                  ),
                  foregroundColor: colors.brandText,
                  padding: const EdgeInsets.symmetric(horizontal: DsSpacing.sm),
                ),
                onPressed: onReview,
                icon: const Icon(DsIcons.checkCircle, size: 18),
                label: Text('${identity.offlineReviewCount} 条离线记录待核对'),
              ),
            ),
          ],
          if (authenticated && identity.canScanAdmin) ...<Widget>[
            const SizedBox(height: DsSpacing.md),
            Divider(height: 1, color: colors.border),
            const SizedBox(height: DsSpacing.sm),
            InkWell(
              key: const Key('admin-scan'),
              borderRadius: DsRadius.borderMd,
              onTap: () => unawaited(onScan()),
              child: Container(
                constraints: const BoxConstraints(
                  minWidth: DsSizes.touchTarget,
                  minHeight: DsSizes.touchTarget,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.md,
                  vertical: DsSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: DsRadius.borderMd,
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      DsIcons.qrScan,
                      size: DsSizes.iconMd,
                      color: colors.textPrimary,
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Expanded(
                      child: Text(
                        '网页后台扫码登录',
                        style: ds.typography.body.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Text(
                      '扫一扫',
                      style: ds.typography.caption.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      DsIcons.chevronRight,
                      size: 18,
                      color: colors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (identity.isGuest) ...<Widget>[
            const SizedBox(height: DsSpacing.lg),
            CommandButton(
              label: '加入单位',
              icon: DsIcons.addCircle,
              variant: CommandButtonVariant.secondary,
              expanded: true,
              onPressed: onJoin,
            ),
          ],
        ],
      ),
    );
  }
}
