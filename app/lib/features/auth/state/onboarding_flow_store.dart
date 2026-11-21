import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/network.dart';
import '../../../services/settings.dart';

typedef OnboardingAuthenticateCallback =
    Future<void> Function(String unitName, String realName, String unitCode);

typedef OnboardingApplyCallback =
    Future<Map<String, dynamic>> Function(
      String unitName,
      String realName,
      String unitCode, {
      String? stationName,
      String? phone,
      String? applyReason,
    });

typedef OnboardingGuestCallback = Future<void> Function();

/// 启动引导所处的全屏步骤。
enum OnboardingStep { unitAuth, membershipPending, incidentPicker }

/// 本地持久化的待审批入队申请快照。
@immutable
class PendingMembershipApplication {
  const PendingMembershipApplication({
    required this.unitName,
    required this.unitCode,
    required this.realName,
    this.stationName = '',
    this.phone = '',
    this.submittedAt = '',
  });

  final String unitName, unitCode, realName, stationName, phone, submittedAt;

  factory PendingMembershipApplication.fromMap(Map<String, String> m) =>
      PendingMembershipApplication(
        unitName: (m['unit_name'] ?? '').trim(),
        unitCode: (m['unit_code'] ?? '').trim(),
        realName: (m['real_name'] ?? '').trim(),
        stationName: (m['station_name'] ?? '').trim(),
        phone: (m['phone'] ?? '').trim(),
        submittedAt: (m['submitted_at'] ?? '').trim(),
      );
}

/// 单位认证提交后的语义分流动作。
enum OnboardingAuthAction {
  authenticated,
  pendingApproval,
  rosterOnlyPrompt,
  nameSuggestionsPrompt,
  submitApplicationPrompt,
  validationError,
  rejected,
  failed,
  ignored,
}

/// 单位认证尝试的结构化结果，供 UI 拉起对应的 `CommandSheet`。
@immutable
class OnboardingAuthOutcome {
  const OnboardingAuthOutcome({
    required this.action,
    this.unitName = '',
    this.realName = '',
    this.unitCode = '',
    this.suggestions = const <String>[],
    this.message,
  });

  final OnboardingAuthAction action;
  final String unitName, realName, unitCode;
  final List<String> suggestions;
  final String? message;
}

/// 待审批状态刷新结果。
enum PendingCheckStatus { approved, stillPending, rejected, error, skipped }

@immutable
class PendingCheckResult {
  const PendingCheckResult({required this.status, this.message});
  final PendingCheckStatus status;
  final String? message;
}

/// 启动认证与入队审批共享状态机。
///
/// 负责单位认证校验、模糊姓名建议、仅名单入队申请、待审批持久化与前后台静默轮询，
/// 以及游客模式切换。所有外部能力均通过回调注入，零跨 Store / `AppController` 依赖。
class OnboardingFlowStore extends ChangeNotifier {
  OnboardingFlowStore({
    bool authenticationRequired = true,
    this.onAuthenticate,
    this.onApply,
    this.onEnterGuestMode,
    this.pendingPollInterval = const Duration(seconds: 30),
  }) : _authenticationRequired = authenticationRequired;

  final OnboardingAuthenticateCallback? onAuthenticate;
  final OnboardingApplyCallback? onApply;
  final OnboardingGuestCallback? onEnterGuestMode;
  final Duration? pendingPollInterval;

  bool _authenticationRequired;
  PendingMembershipApplication? _pendingApplication;
  bool _initialized = false, _busy = false, _silentChecking = false;
  bool _inForeground = true, _disposed = false;
  String? _error;
  String _initialUnitName = '', _initialRealName = '';
  List<String> _recentSuggestions = const <String>[];
  Timer? _pollTimer;
  int _generation = 0;

  bool get authenticationRequired => _authenticationRequired;
  PendingMembershipApplication? get pendingApplication => _pendingApplication;
  bool get hasPendingApplication => _pendingApplication != null;
  bool get initialized => _initialized;
  bool get busy => _busy;
  bool get silentChecking => _silentChecking;
  String? get error => _error;
  String get initialUnitName => _initialUnitName;
  String get initialRealName => _initialRealName;
  List<String> get recentSuggestions => _recentSuggestions;
  bool get canEnterGuestMode => onEnterGuestMode != null;
  bool get canApplyMembership => onApply != null;
  bool get isDisposed => _disposed;

  OnboardingStep get step => !_authenticationRequired
      ? OnboardingStep.incidentPicker
      : _pendingApplication != null
      ? OnboardingStep.membershipPending
      : OnboardingStep.unitAuth;

  bool _isStale(int gen) => _disposed || gen != _generation;
  bool get _canSilentPoll =>
      !_disposed &&
      _inForeground &&
      step == OnboardingStep.membershipPending &&
      !_busy &&
      !_silentChecking;

  /// 冷启动恢复本地默认单位/姓名及未完成的待审批入队申请。
  Future<void> hydrate() async {
    final gen = _generation;
    final res = await Future.wait<Object?>(<Future<Object?>>[
      Settings.unitName,
      Settings.realName,
      Settings.pendingApplication,
    ]);
    if (_isStale(gen)) return;
    _initialUnitName = (res[0] as String? ?? '').trim();
    _initialRealName = (res[1] as String? ?? '').trim();
    final map = res[2] as Map<String, String>?;
    _pendingApplication =
        map == null ? null : PendingMembershipApplication.fromMap(map);
    _initialized = true;
    _syncPollTimer();
    _notify();
  }

  void setAuthenticationRequired(bool value) {
    if (_disposed || _authenticationRequired == value) return;
    _authenticationRequired = value;
    if (!value) {
      _error = null;
      _recentSuggestions = const <String>[];
    }
    _syncPollTimer();
    _notify();
  }

  void clearError() {
    if (_disposed || _error == null) return;
    _error = null;
    _notify();
  }

  void clearSuggestions() {
    if (_disposed || _recentSuggestions.isEmpty) return;
    _recentSuggestions = const <String>[];
    _notify();
  }

  String? _validate(String unit, String name, String code) {
    if (unit.isEmpty) return '请输入单位名称';
    if (name.isEmpty) return '请输入真实姓名';
    if (code.isEmpty) return '请输入单位验证码';
    return null;
  }

  void _setPending(PendingMembershipApplication? value) {
    _pendingApplication = value;
    _syncPollTimer();
  }

  /// 提交单位名称、真实姓名与单位验证码进行实名认证。
  Future<OnboardingAuthOutcome> authenticate({
    required String unitName,
    required String realName,
    required String unitCode,
  }) async {
    const ignored = OnboardingAuthOutcome(action: OnboardingAuthAction.ignored);
    if (_disposed || _busy) return ignored;
    final unit = unitName.trim(), name = realName.trim(), code = unitCode.trim();
    final invalid = _validate(unit, name, code);
    if (invalid != null) return _fail(OnboardingAuthAction.validationError, invalid);
    final callback = onAuthenticate;
    if (callback == null) return _fail(OnboardingAuthAction.failed, '认证服务未就绪，请稍后重试');

    final gen = _generation;
    _busy = true;
    _error = null;
    _recentSuggestions = const <String>[];
    _notify();
    try {
      await callback(unit, name, code);
      await Settings.clearPendingApplication();
      if (_isStale(gen)) return ignored;
      _error = null;
      _recentSuggestions = const <String>[];
      _setPending(null);
      return OnboardingAuthOutcome(
        action: OnboardingAuthAction.authenticated,
        unitName: unit,
        realName: name,
        unitCode: code,
      );
    } catch (error) {
      return _isStale(gen) ? ignored : _handleAuthError(error, unit, name, code, gen);
    } finally {
      if (!_isStale(gen)) {
        _busy = false;
        _notify();
      }
    }
  }

  Future<OnboardingAuthOutcome> _handleAuthError(
    Object error,
    String unit,
    String name,
    String code,
    int gen,
  ) async {
    OnboardingAuthOutcome out(
      OnboardingAuthAction action, {
      List<String> suggestions = const <String>[],
      String? message,
    }) => OnboardingAuthOutcome(
      action: action, unitName: unit, realName: name, unitCode: code,
      suggestions: suggestions, message: message,
    );
    if (error is ApiException) {
      if (error.code == 'MEMBER_APPLICATION_PENDING') {
        await Settings.setPendingApplication(unitName: unit, unitCode: code, realName: name);
        if (_isStale(gen)) return out(OnboardingAuthAction.ignored);
        _setPending(PendingMembershipApplication(
          unitName: unit, unitCode: code, realName: name,
          submittedAt: DateTime.now().toIso8601String(),
        ));
        return out(OnboardingAuthAction.pendingApproval);
      }
      if (error.code == 'MEMBER_APPLICATION_REJECTED') {
        await Settings.clearPendingApplication();
        if (_isStale(gen)) return out(OnboardingAuthAction.ignored);
        _error = '您的入队申请已被站长驳回，请联系管理员或重新填写申请。';
        _setPending(null);
        return out(OnboardingAuthAction.rejected, message: _error);
      }
      if (error.code == 'MEMBER_ROSTER_ONLY') {
        return out(OnboardingAuthAction.rosterOnlyPrompt);
      }
      if (error.code == 'MEMBER_NOT_ALLOWED') {
        if (error.suggestions.isNotEmpty) {
          _recentSuggestions = List<String>.unmodifiable(error.suggestions);
          return out(OnboardingAuthAction.nameSuggestionsPrompt, suggestions: _recentSuggestions);
        }
        return out(OnboardingAuthAction.submitApplicationPrompt);
      }
    }
    _error = '$error';
    return out(OnboardingAuthAction.failed, message: _error);
  }

  /// 提交免登录入队申请，成功后落盘并切至待审批步骤。
  Future<bool> submitApplication({
    required String unitName,
    required String realName,
    required String unitCode,
    String? stationName,
    String? phone,
    String? applyReason,
  }) async {
    if (_disposed || _busy) return false;
    final unit = unitName.trim(), name = realName.trim(), code = unitCode.trim();
    final invalid = _validate(unit, name, code);
    if (invalid != null) {
      _fail(OnboardingAuthAction.validationError, invalid);
      return false;
    }
    final applyCallback = onApply;
    if (applyCallback == null) {
      _fail(OnboardingAuthAction.failed, '申请服务未就绪，请稍后重试');
      return false;
    }
    final gen = _generation;
    _busy = true;
    _error = null;
    _notify();
    try {
      final station = stationName?.trim(), tel = phone?.trim();
      await applyCallback(
        unit, name, code,
        stationName: station, phone: tel, applyReason: applyReason?.trim(),
      );
      if (_isStale(gen)) return false;
      var persisted = await Settings.pendingApplication;
      if (persisted == null) {
        await Settings.setPendingApplication(
          unitName: unit, unitCode: code, realName: name,
          stationName: station, phone: tel,
        );
        persisted = await Settings.pendingApplication;
      }
      if (_isStale(gen)) return false;
      _recentSuggestions = const <String>[];
      _setPending(
        persisted != null
            ? PendingMembershipApplication.fromMap(persisted)
            : PendingMembershipApplication(
                unitName: unit, unitCode: code, realName: name,
                stationName: station ?? '', phone: tel ?? '',
                submittedAt: DateTime.now().toIso8601String(),
              ),
      );
      return true;
    } catch (error) {
      if (!_isStale(gen)) _error = '$error';
      return false;
    } finally {
      if (!_isStale(gen)) {
        _busy = false;
        _notify();
      }
    }
  }

  /// 检查当前待审批入队申请的最新状态（支持手动与前后台静默刷新）。
  Future<PendingCheckResult> checkPendingStatus({bool silent = false}) async {
    const skipped = PendingCheckResult(status: PendingCheckStatus.skipped);
    final pending = _pendingApplication, callback = onAuthenticate;
    if (_disposed || pending == null || callback == null || _busy || _silentChecking) {
      return skipped;
    }
    final gen = _generation;
    if (silent) {
      _silentChecking = true;
    } else {
      _busy = true;
      _error = null;
    }
    _notify();
    try {
      await callback(pending.unitName, pending.realName, pending.unitCode);
      await Settings.clearPendingApplication();
      if (_isStale(gen)) return skipped;
      _error = null;
      _setPending(null);
      return const PendingCheckResult(status: PendingCheckStatus.approved);
    } catch (error) {
      if (_isStale(gen)) return skipped;
      if (error is ApiException && error.code == 'MEMBER_APPLICATION_PENDING') {
        return PendingCheckResult(
          status: PendingCheckStatus.stillPending,
          message: silent ? null : '站长尚未审批，请稍候再试',
        );
      }
      if (error is ApiException && error.code == 'MEMBER_APPLICATION_REJECTED') {
        await Settings.clearPendingApplication();
        if (_isStale(gen)) return skipped;
        _error = '您的申请已被驳回，请重新申请';
        _setPending(null);
        return PendingCheckResult(status: PendingCheckStatus.rejected, message: _error);
      }
      if (!silent) {
        _error = '$error';
        return PendingCheckResult(status: PendingCheckStatus.error, message: _error);
      }
      return const PendingCheckResult(status: PendingCheckStatus.error);
    } finally {
      if (!_isStale(gen)) {
        if (silent) {
          _silentChecking = false;
        } else {
          _busy = false;
        }
        _notify();
      }
    }
  }

  /// 撤销本地待审批申请并返回单位认证页（切换账号 / 重新填写）。
  Future<void> cancelPendingApplication() async {
    if (_disposed) return;
    _generation++;
    _stopPoll();
    _busy = false;
    _silentChecking = false;
    _error = null;
    await Settings.clearPendingApplication();
    if (_disposed) return;
    _pendingApplication = null;
    _notify();
  }

  /// 进入单机游客体验模式。
  Future<bool> enterGuestMode() async {
    final callback = onEnterGuestMode;
    if (_disposed || _busy || callback == null) return false;
    final gen = _generation;
    _busy = true;
    _error = null;
    _notify();
    try {
      await callback();
      if (_isStale(gen)) return false;
      _stopPoll();
      return true;
    } catch (error) {
      if (!_isStale(gen)) _error = '$error';
      return false;
    } finally {
      if (!_isStale(gen)) {
        _busy = false;
        _notify();
      }
    }
  }

  /// App 回到前台时恢复轮询并立即静默检查待审批状态。
  void handleAppResumed() {
    if (_disposed) return;
    _inForeground = true;
    _syncPollTimer();
    if (_canSilentPoll) unawaited(checkPendingStatus(silent: true));
  }

  /// App 切入后台时暂停前台定时轮询。
  void handleAppPaused() {
    if (_disposed) return;
    _inForeground = false;
    _stopPoll();
  }

  OnboardingAuthOutcome _fail(OnboardingAuthAction action, String message) {
    _error = message;
    _notify();
    return OnboardingAuthOutcome(action: action, message: message);
  }

  void _syncPollTimer() {
    final interval = pendingPollInterval;
    if (_disposed ||
        !_inForeground ||
        step != OnboardingStep.membershipPending ||
        interval == null ||
        interval <= Duration.zero ||
        onAuthenticate == null) {
      _stopPoll();
      return;
    }
    _pollTimer ??= Timer.periodic(interval, (_) {
      if (_canSilentPoll) unawaited(checkPendingStatus(silent: true));
    });
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _stopPoll();
    super.dispose();
  }
}
