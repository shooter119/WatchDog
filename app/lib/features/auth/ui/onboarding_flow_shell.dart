import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/onboarding_flow_store.dart';
import 'membership_pending_page.dart';
import 'unit_auth_page.dart';

/// Design System v3.0 全屏启动引导流外壳。
///
/// 按 [OnboardingFlowStore.step] 无缝切换三大全屏步骤：
/// 1. [UnitAuthPage]（未认证单位实名认证）
/// 2. [MembershipPendingPage]（入队申请待审批等待页）
/// 3. [incidentPickerBuilder]（已认证后由外部注入的警情选择页槽位，零跨 Feature 依赖）
class OnboardingFlowShell extends StatefulWidget {
  const OnboardingFlowShell({
    super.key,
    required this.incidentPickerBuilder,
    this.store,
    this.authenticationRequired = true,
    this.onAuthenticate,
    this.onApply,
    this.onEnterGuestMode,
    this.onShowMessage,
    this.pendingPollInterval = const Duration(seconds: 30),
  });

  /// 已通过认证后渲染的警情选择全屏步骤槽位。
  final WidgetBuilder incidentPickerBuilder;

  /// 可选外部共享状态机；未传时由本组件创建、hydrate 并负责销毁。
  final OnboardingFlowStore? store;

  /// 当前是否仍需单位认证（未传外部 [store] 时作为权威输入；传外部 [store] 时同步更新）。
  final bool authenticationRequired;

  final OnboardingAuthenticateCallback? onAuthenticate;
  final OnboardingApplyCallback? onApply;
  final OnboardingGuestCallback? onEnterGuestMode;
  final void Function(String message)? onShowMessage;
  final Duration? pendingPollInterval;

  @override
  State<OnboardingFlowShell> createState() => _OnboardingFlowShellState();
}

class _OnboardingFlowShellState extends State<OnboardingFlowShell>
    with WidgetsBindingObserver {
  late OnboardingFlowStore _store;
  late bool _ownsStore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachStore(initial: true);
  }

  void _attachStore({required bool initial}) {
    if (widget.store != null) {
      _ownsStore = false;
      _store = widget.store!;
      if (!initial) {
        _store.setAuthenticationRequired(widget.authenticationRequired);
      }
      if (!_store.initialized) {
        unawaited(_store.hydrate());
      }
      return;
    }
    _ownsStore = true;
    _store = OnboardingFlowStore(
      authenticationRequired: widget.authenticationRequired,
      onAuthenticate: widget.onAuthenticate,
      onApply: widget.onApply,
      onEnterGuestMode: widget.onEnterGuestMode,
      pendingPollInterval: widget.pendingPollInterval,
    );
    unawaited(_store.hydrate());
  }

  @override
  void didUpdateWidget(covariant OnboardingFlowShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final externalStoreChanged = !identical(oldWidget.store, widget.store);
    final callbacksChanged =
        widget.store == null &&
        (oldWidget.onAuthenticate != widget.onAuthenticate ||
            oldWidget.onApply != widget.onApply ||
            oldWidget.onEnterGuestMode != widget.onEnterGuestMode ||
            oldWidget.pendingPollInterval != widget.pendingPollInterval);
    if (externalStoreChanged || callbacksChanged) {
      if (_ownsStore) _store.dispose();
      _attachStore(initial: false);
      return;
    }
    if (oldWidget.authenticationRequired != widget.authenticationRequired) {
      _store.setAuthenticationRequired(widget.authenticationRequired);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store.handleAppResumed();
    } else {
      _store.handleAppPaused();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsStore) _store.dispose();
    super.dispose();
  }

  String _semanticLabel(OnboardingStep step) => switch (step) {
    OnboardingStep.unitAuth => '用户认证',
    OnboardingStep.membershipPending => '入队申请审核中',
    OnboardingStep.incidentPicker => '选择警情',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (BuildContext context, _) {
        final step = _store.step;
        final Widget activeStep = switch (step) {
          OnboardingStep.unitAuth => UnitAuthPage(
            key: const ValueKey<String>('onboarding-step-unit-auth'),
            store: _store,
            onShowMessage: widget.onShowMessage,
          ),
          OnboardingStep.membershipPending => MembershipPendingPage(
            key: const ValueKey<String>('onboarding-step-pending'),
            store: _store,
            observeLifecycle: false,
            onShowMessage: widget.onShowMessage,
          ),
          OnboardingStep.incidentPicker => KeyedSubtree(
            key: const ValueKey<String>('onboarding-step-incident-picker'),
            child: widget.incidentPickerBuilder(context),
          ),
        };

        return Semantics(
          container: true,
          scopesRoute: true,
          explicitChildNodes: true,
          namesRoute: true,
          label: _semanticLabel(step),
          child: AnimatedSwitcher(
            duration: DsMotion.resolve(context, DsMotion.fast),
            switchInCurve: DsMotion.enter,
            switchOutCurve: DsMotion.standard,
            child: activeStep,
          ),
        );
      },
    );
  }
}
