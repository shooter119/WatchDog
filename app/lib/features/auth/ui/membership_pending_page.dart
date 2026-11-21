import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/onboarding_flow_store.dart';
import 'auth_ui_parts.dart';

/// Design System v3.0 入队申请待审批等待页。
///
/// 展示当前提交的单位与队员信息，支持切回前台自动静默刷新、
/// 手动检查审批状态、先以游客身份体验，以及撤销申请/切换账号重填。
class MembershipPendingPage extends StatefulWidget {
  const MembershipPendingPage({
    super.key,
    required this.store,
    this.observeLifecycle = true,
    this.onShowMessage,
  });

  final OnboardingFlowStore store;

  /// 当外层 [OnboardingFlowShell] 已统一监听生命周期时传 `false` 避免重复触发。
  final bool observeLifecycle;
  final void Function(String message)? onShowMessage;

  @override
  State<MembershipPendingPage> createState() => _MembershipPendingPageState();
}

class _MembershipPendingPageState extends State<MembershipPendingPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    if (widget.observeLifecycle) WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant MembershipPendingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.observeLifecycle != widget.observeLifecycle) {
      if (widget.observeLifecycle) {
        WidgetsBinding.instance.addObserver(this);
      } else {
        WidgetsBinding.instance.removeObserver(this);
      }
    }
  }

  @override
  void dispose() {
    if (widget.observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.observeLifecycle) return;
    if (state == AppLifecycleState.resumed) {
      widget.store.handleAppResumed();
    } else {
      widget.store.handleAppPaused();
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    if (widget.onShowMessage != null) {
      widget.onShowMessage!(message);
      return;
    }
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _checkStatus() async {
    final result = await widget.store.checkPendingStatus(silent: false);
    if (!mounted) return;
    if (result.status == PendingCheckStatus.stillPending &&
        result.message != null) {
      _showToast(result.message!);
    }
  }

  String _formatSubmittedAt(String raw) {
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }

  Widget _buildInfoRow(
    BuildContext context, {
    required String label,
    required String value,
    bool tabular = false,
  }) {
    final ds = context.ds;
    final colors = ds.colors;
    final valueStyle = (tabular ? ds.typography.bodyTabular : ds.typography.body)
        .copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: ds.typography.body.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(width: DsSpacing.md),
        Expanded(
          child: Text(
            value.isEmpty ? '-' : value,
            textAlign: TextAlign.end,
            softWrap: true,
            style: valueStyle,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return ListenableBuilder(
      listenable: widget.store,
      builder: (BuildContext context, _) {
        final store = widget.store;
        final pending = store.pendingApplication;
        if (pending == null) {
          return const CommandScaffold(
            body: StatePlaceholder.loading(message: '正在更新认证状态...'),
          );
        }
        final formattedTime = _formatSubmittedAt(pending.submittedAt);
        return CommandScaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.pageMargin,
              DsSpacing.xxl,
              DsSpacing.pageMargin,
              DsSpacing.xxl,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const AuthHeaderBadgeRow(
                      icon: Icons.hourglass_top_rounded,
                      pillLabel: '等待站长审批',
                      pillIcon: Icons.schedule_rounded,
                      pillStatus: DsStatus.caution,
                      useCautionIconTone: true,
                    ),
                    const SizedBox(height: DsSpacing.lg),
                    Text(
                      '入队申请审核中',
                      style: ds.typography.display.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: DsSpacing.xs),
                    Text(
                      '申请已提交，等待站长或安全员审批通过。',
                      style: ds.typography.body.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: DsSpacing.xl),
                    SurfaceCard(
                      level: DsSurfaceLevel.outlined,
                      accentStatus: DsStatus.caution,
                      padding: const EdgeInsets.all(DsSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _buildInfoRow(
                            context,
                            label: '申请单位',
                            value: pending.unitName,
                          ),
                          Divider(height: DsSpacing.xl, color: colors.border),
                          _buildInfoRow(
                            context,
                            label: '申请队员',
                            value: pending.realName,
                          ),
                          if (pending.stationName.isNotEmpty) ...<Widget>[
                            Divider(height: DsSpacing.xl, color: colors.border),
                            _buildInfoRow(
                              context,
                              label: '所属队站',
                              value: pending.stationName,
                            ),
                          ],
                          if (pending.phone.isNotEmpty) ...<Widget>[
                            Divider(height: DsSpacing.xl, color: colors.border),
                            _buildInfoRow(
                              context,
                              label: '联系电话',
                              value: pending.phone,
                              tabular: true,
                            ),
                          ],
                          if (formattedTime.isNotEmpty) ...<Widget>[
                            Divider(height: DsSpacing.xl, color: colors.border),
                            _buildInfoRow(
                              context,
                              label: '提交时间',
                              value: formattedTime,
                              tabular: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: DsSpacing.md),
                    const AuthNoticeBanner(
                      status: DsStatus.neutral,
                      icon: Icons.lightbulb_outline_rounded,
                      message:
                          '站长在手机 App【设置 → 入队审批】中点击同意后，切回本页面或点击下方按钮即可自动完成登录。',
                    ),
                    if (store.silentChecking) ...<Widget>[
                      const SizedBox(height: DsSpacing.sm),
                      Text(
                        '正在静默检查审批状态...',
                        textAlign: TextAlign.center,
                        style: ds.typography.caption.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                    if (store.error != null) ...<Widget>[
                      const SizedBox(height: DsSpacing.md),
                      AuthNoticeBanner(
                        key: const Key('pending-error'),
                        message: store.error!,
                      ),
                    ],
                    const SizedBox(height: DsSpacing.xl),
                    CommandButton(
                      key: const Key('pending-check-status'),
                      label: '检查审批状态',
                      icon: Icons.refresh_rounded,
                      variant: CommandButtonVariant.primary,
                      size: CommandButtonSize.large,
                      expanded: true,
                      isLoading: store.busy,
                      enabled: !store.busy,
                      onPressed: () => unawaited(_checkStatus()),
                    ),
                    if (store.canEnterGuestMode) ...<Widget>[
                      const SizedBox(height: DsSpacing.md),
                      CommandButton(
                        key: const Key('pending-guest-mode'),
                        label: '先以游客身份体验',
                        icon: Icons.explore_outlined,
                        variant: CommandButtonVariant.secondary,
                        size: CommandButtonSize.large,
                        expanded: true,
                        enabled: !store.busy,
                        onPressed: () => unawaited(store.enterGuestMode()),
                      ),
                    ],
                    const SizedBox(height: DsSpacing.sm),
                    CommandButton(
                      key: const Key('pending-cancel-app'),
                      label: '切换账号 / 撤销申请并重新填写',
                      icon: Icons.swap_horiz_rounded,
                      variant: CommandButtonVariant.ghost,
                      size: CommandButtonSize.standard,
                      expanded: true,
                      enabled: !store.busy,
                      onPressed: () =>
                          unawaited(store.cancelPendingApplication()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
