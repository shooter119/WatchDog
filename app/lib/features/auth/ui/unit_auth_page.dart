import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/onboarding_flow_store.dart';
import 'auth_ui_parts.dart';
import 'membership_apply_dialogs.dart';

/// Design System v3.0 全屏单位实名认证页。
///
/// 承接首次启动及退出重新登录的单位名称、真实姓名、单位验证码输入，
/// 集成模糊姓名提示、仅名单/未入名单入队申请弹窗与单机游客模式入口。
class UnitAuthPage extends StatefulWidget {
  const UnitAuthPage({super.key, required this.store, this.onShowMessage});

  final OnboardingFlowStore store;
  final void Function(String message)? onShowMessage;

  @override
  State<UnitAuthPage> createState() => _UnitAuthPageState();
}

class _UnitAuthPageState extends State<UnitAuthPage> {
  final TextEditingController _unitName = TextEditingController();
  final TextEditingController _realName = TextEditingController();
  final TextEditingController _unitCode = TextEditingController();
  bool _obscureUnitCode = true;
  bool _appliedUnitDefault = false;
  bool _appliedRealNameDefault = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_syncDefaultsFromStore);
    _syncDefaultsFromStore();
  }

  @override
  void didUpdateWidget(covariant UnitAuthPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_syncDefaultsFromStore);
      widget.store.addListener(_syncDefaultsFromStore);
      _syncDefaultsFromStore();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_syncDefaultsFromStore);
    _unitName.dispose();
    _realName.dispose();
    _unitCode.dispose();
    super.dispose();
  }

  void _syncDefaultsFromStore() {
    if (!_appliedUnitDefault &&
        _unitName.text.isEmpty &&
        widget.store.initialUnitName.isNotEmpty) {
      _unitName.text = widget.store.initialUnitName;
      _appliedUnitDefault = true;
    }
    if (!_appliedRealNameDefault &&
        _realName.text.isEmpty &&
        widget.store.initialRealName.isNotEmpty) {
      _realName.text = widget.store.initialRealName;
      _appliedRealNameDefault = true;
    }
  }

  void _applySuggestedName(String candidate) {
    _realName.text = candidate;
    _realName.selection = TextSelection.collapsed(offset: candidate.length);
    widget.store.clearError();
    widget.store.clearSuggestions();
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

  Future<void> _submitAuth() async {
    final outcome = await widget.store.authenticate(
      unitName: _unitName.text,
      realName: _realName.text,
      unitCode: _unitCode.text,
    );
    if (!mounted) return;
    switch (outcome.action) {
      case OnboardingAuthAction.rosterOnlyPrompt:
        final confirmed = await showRosterOnlyApplySheet(
          context,
          unitName: outcome.unitName,
          realName: outcome.realName,
        );
        if (confirmed == true && mounted) {
          await _submitApplication(
            unitName: outcome.unitName,
            realName: outcome.realName,
            unitCode: outcome.unitCode,
          );
        }
      case OnboardingAuthAction.nameSuggestionsPrompt:
        final choice = await showNameSuggestionsSheet(
          context,
          realName: outcome.realName,
          suggestions: outcome.suggestions,
        );
        if (!mounted || choice == null) return;
        if (choice.selectedName != null) {
          _applySuggestedName(choice.selectedName!);
        } else if (choice.applyAnyway) {
          final confirmed = await showMembershipApplyConfirmSheet(
            context,
            unitName: outcome.unitName,
            realName: outcome.realName,
          );
          if (confirmed == true && mounted) {
            await _submitApplication(
              unitName: outcome.unitName,
              realName: outcome.realName,
              unitCode: outcome.unitCode,
            );
          }
        }
      case OnboardingAuthAction.submitApplicationPrompt:
        final confirmed = await showMembershipApplyConfirmSheet(
          context,
          unitName: outcome.unitName,
          realName: outcome.realName,
        );
        if (confirmed == true && mounted) {
          await _submitApplication(
            unitName: outcome.unitName,
            realName: outcome.realName,
            unitCode: outcome.unitCode,
          );
        }
      case OnboardingAuthAction.authenticated:
      case OnboardingAuthAction.pendingApproval:
      case OnboardingAuthAction.validationError:
      case OnboardingAuthAction.rejected:
      case OnboardingAuthAction.failed:
      case OnboardingAuthAction.ignored:
        break;
    }
  }

  Future<void> _openDirectApplySheet() async {
    if (widget.store.busy) return;
    final draft = await showMembershipApplyFormSheet(
      context,
      initialUnitName: _unitName.text.trim(),
      initialRealName: _realName.text.trim(),
      initialUnitCode: _unitCode.text.trim(),
    );
    if (!mounted || draft == null) return;
    _unitName.text = draft.unitName;
    _realName.text = draft.realName;
    _unitCode.text = draft.unitCode;
    await _submitApplication(
      unitName: draft.unitName,
      realName: draft.realName,
      unitCode: draft.unitCode,
      stationName: draft.stationName,
      phone: draft.phone,
      applyReason: draft.applyReason,
    );
  }

  Future<void> _submitApplication({
    required String unitName,
    required String realName,
    required String unitCode,
    String? stationName,
    String? phone,
    String? applyReason,
  }) async {
    final submitted = await widget.store.submitApplication(
      unitName: unitName,
      realName: realName,
      unitCode: unitCode,
      stationName: stationName,
      phone: phone,
      applyReason: applyReason,
    );
    if (submitted && mounted) {
      _showToast('已提交至$unitName，等待管理员审批');
    }
  }

  Widget _buildHero(BuildContext context, {required bool compact}) {
    final ds = context.ds;
    final colors = ds.colors;
    if (compact) {
      final brandTint = Color.alphaBlend(
        colors.brand.withValues(alpha: 0.12),
        colors.surface,
      );
      return Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: brandTint,
              borderRadius: DsRadius.borderMd,
              border: Border.all(color: colors.brand.withValues(alpha: 0.28)),
            ),
            child: Icon(
              Icons.verified_user_outlined,
              size: DsSizes.iconMd,
              color: colors.brandText,
            ),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '用户认证',
                  style: ds.typography.headline.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  '使用单位账号继续',
                  style: ds.typography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AuthHeaderBadgeRow(
          icon: Icons.verified_user_outlined,
          pillLabel: '单位实名接入',
          pillIcon: Icons.shield_outlined,
        ),
        const SizedBox(height: DsSpacing.lg),
        Text(
          '先完成用户认证',
          style: ds.typography.display.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          '认证后即可同步查看和记录本单位的现场警情与空呼监控数据。',
          style: ds.typography.body.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final hasKeyboard = MediaQuery.viewInsetsOf(context).bottom > 80;
    final fieldStyle = ds.typography.body.copyWith(color: colors.textPrimary);

    return ListenableBuilder(
      listenable: widget.store,
      builder: (BuildContext context, _) {
        final store = widget.store;
        return CommandScaffold(
          body: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              DsSpacing.pageMargin,
              hasKeyboard ? DsSpacing.md : DsSpacing.xxl,
              DsSpacing.pageMargin,
              DsSpacing.xxl,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildHero(context, compact: hasKeyboard),
                    SizedBox(height: hasKeyboard ? DsSpacing.md : DsSpacing.xl),
                    SurfaceCard(
                      level: DsSurfaceLevel.outlined,
                      padding: const EdgeInsets.all(DsSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          TextField(
                            key: const Key('auth-unit-name'),
                            controller: _unitName,
                            enabled: !store.busy,
                            maxLength: 120,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => store.clearError(),
                            style: fieldStyle,
                            decoration: authInputDecoration(
                              context,
                              label: '单位名称',
                              hint: '请输入所属消防救援单位全称',
                              icon: Icons.business_outlined,
                            ),
                          ),
                          const SizedBox(height: DsSpacing.md),
                          TextField(
                            key: const Key('auth-real-name'),
                            controller: _realName,
                            enabled: !store.busy,
                            maxLength: 20,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => store.clearError(),
                            style: fieldStyle,
                            decoration: authInputDecoration(
                              context,
                              label: '真实姓名',
                              hint: '请输入姓名，用于现场记录署名',
                              icon: Icons.person_outline_rounded,
                            ),
                          ),
                          if (store.recentSuggestions.isNotEmpty)
                            AuthSuggestionChips(
                              suggestions: store.recentSuggestions,
                              enabled: !store.busy,
                              onSelected: _applySuggestedName,
                            ),
                          const SizedBox(height: DsSpacing.md),
                          TextField(
                            key: const Key('auth-unit-code'),
                            controller: _unitCode,
                            enabled: !store.busy,
                            maxLength: 12,
                            obscureText: _obscureUnitCode,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => unawaited(_submitAuth()),
                            onChanged: (_) => store.clearError(),
                            style: fieldStyle,
                            decoration: authInputDecoration(
                              context,
                              label: '单位验证码',
                              hint: '请输入单位验证码',
                              icon: Icons.password_outlined,
                              suffixIcon: IconButton(
                                key: const Key('auth-code-visibility-toggle'),
                                constraints: const BoxConstraints(
                                  minWidth: DsSizes.touchTarget,
                                  minHeight: DsSizes.touchTarget,
                                ),
                                icon: Icon(
                                  _obscureUnitCode
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: DsSizes.iconMd,
                                  color: colors.textTertiary,
                                ),
                                tooltip: _obscureUnitCode ? '显示验证码' : '隐藏验证码',
                                onPressed: () => setState(
                                  () => _obscureUnitCode = !_obscureUnitCode,
                                ),
                              ),
                            ),
                          ),
                          if (store.error != null) ...<Widget>[
                            const SizedBox(height: DsSpacing.md),
                            AuthNoticeBanner(
                              key: const Key('auth-error'),
                              message: store.error!,
                            ),
                          ],
                          const SizedBox(height: DsSpacing.lg),
                          CommandButton(
                            key: const Key('auth-submit'),
                            label: '认证并继续',
                            icon: Icons.arrow_forward_rounded,
                            variant: CommandButtonVariant.primary,
                            size: CommandButtonSize.large,
                            expanded: true,
                            isLoading: store.busy,
                            enabled: !store.busy,
                            onPressed: () => unawaited(_submitAuth()),
                          ),
                          if (store.canApplyMembership) ...<Widget>[
                            const SizedBox(height: DsSpacing.sm),
                            CommandButton(
                              key: const Key('auth-apply-membership'),
                              label: '不在单位名单？申请加入单位',
                              icon: Icons.person_add_alt_1_outlined,
                              variant: CommandButtonVariant.ghost,
                              size: CommandButtonSize.standard,
                              expanded: true,
                              enabled: !store.busy,
                              onPressed: () => unawaited(_openDirectApplySheet()),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (!hasKeyboard && store.canEnterGuestMode) ...<Widget>[
                      const SizedBox(height: DsSpacing.md),
                      CommandButton(
                        key: const Key('auth-guest-mode'),
                        label: '先以游客身份体验（单机可用）',
                        icon: Icons.explore_outlined,
                        variant: CommandButtonVariant.secondary,
                        size: CommandButtonSize.large,
                        expanded: true,
                        enabled: !store.busy,
                        onPressed: () => unawaited(store.enterGuestMode()),
                      ),
                    ],
                    if (!hasKeyboard) ...<Widget>[
                      const SizedBox(height: DsSpacing.md),
                      Text(
                        '首次认证成功后，本机将记住当前单位和姓名。',
                        textAlign: TextAlign.center,
                        style: ds.typography.caption.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
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
