import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/network.dart';
import '../../../services/key_site_recents.dart';
import '../../../services/settings.dart';
import '../data/models/admin_login.dart';
import '../data/models/unit_member.dart';

/// 认证会话、权限能力、成员审批收件箱与受保护数据代际（epoch）Store。
///
/// 关键并发/安全不变量：
/// 1. 吊销受保护数据（[revokeProtectedData]）必立即自增 [protectedDataEpoch]、
///    标记 [protectedDataRevoked] 为 true、清空审批个人数据与管理员能力，
///    并异步清理 [KeySiteRecents]；
/// 2. [adminCapabilityRequest] 与 [memberReviewGeneration] 严格阻止乱序迟到请求回写。
///
/// 不依赖任何其他业务 Store 或 `ApiClient`，跨城事务由 `SessionOrchestrator` /
/// `IncidentOrchestrator` 统筹调用本 Store 的受控状态变更接口。
class SessionStore extends ChangeNotifier {
  final KeySiteRecents _keySiteRecents;

  bool _authenticated = false;
  bool _isGuest = false;
  bool _enteredWithoutIncident = false;
  bool _hasCurrentIncident = false;
  ApiConfig? _config;

  AdminCapability? _adminCapability;
  int _adminCapabilityRequest = 0;

  int _offlineReviewCount = 0;
  bool _protectedDataRevoked = false;
  int _protectedDataEpoch = 0;

  String _memberReviewUnitName = '';
  bool _canReviewMembers = false;
  bool _memberReviewLoading = false;
  String? _memberReviewError;
  List<UnitMember> _pendingMembers = const <UnitMember>[];
  List<Map<String, dynamic>> _memberReviewHistory =
      const <Map<String, dynamic>>[];
  int _pendingMemberCount = 0;
  Future<void>? _memberReviewFuture;
  bool _memberReviewAgain = false;
  int _memberReviewGeneration = 0;

  bool _disposed = false;

  SessionStore({KeySiteRecents? keySiteRecents})
    : _keySiteRecents = keySiteRecents ?? KeySiteRecents.instance;

  bool get authenticated => _authenticated;
  bool get isGuest => _isGuest;
  bool get enteredWithoutIncident => _enteredWithoutIncident;
  bool get hasCurrentIncident => _hasCurrentIncident;
  ApiConfig? get config => _config;
  AdminCapability? get adminCapability => _adminCapability;
  int get adminCapabilityRequest => _adminCapabilityRequest;

  int get offlineReviewCount => _offlineReviewCount;
  bool get protectedDataRevoked => _protectedDataRevoked;
  int get protectedDataEpoch => _protectedDataEpoch;
  KeySiteRecents get keySiteRecents => _keySiteRecents;

  String get memberReviewUnitName => _memberReviewUnitName;
  bool get canReviewMembers => _canReviewMembers;
  bool get memberReviewLoading => _memberReviewLoading;
  String? get memberReviewError => _memberReviewError;
  List<UnitMember> get pendingMembers => _pendingMembers;
  List<Map<String, dynamic>> get memberReviewHistory => _memberReviewHistory;
  int get pendingMemberCount => _pendingMemberCount;
  int get memberReviewGeneration => _memberReviewGeneration;
  bool get isDisposed => _disposed;

  /// 受保护重点单位/管理数据的统一读权限门禁。
  bool get canReadKeySites =>
      !_protectedDataRevoked && _authenticated && !_isGuest && _config != null;

  /// 首次安装先完成单位验证码 + 实名认证，或选择游客模式，再进入警情选择。
  bool get needsAuthentication => !_authenticated && !_isGuest;

  /// 已认证用户也可明确选择暂不加入警情，先使用 App 的通用功能。
  bool get needsIncidentSelection =>
      needsIncidentSelectionFor(hasCurrentIncident: _hasCurrentIncident);

  /// 处警记录必须绑定警情；通用功能不受此限制。
  bool get requiresIncident =>
      requiresIncidentFor(hasCurrentIncident: _hasCurrentIncident);

  bool needsIncidentSelectionFor({required bool hasCurrentIncident}) =>
      !_isGuest && !hasCurrentIncident && !_enteredWithoutIncident;

  bool requiresIncidentFor({required bool hasCurrentIncident}) =>
      !_isGuest && !hasCurrentIncident;

  /// 由 `IncidentOrchestrator` / `SessionOrchestrator` 同步当前是否存在已选警情。
  void setHasCurrentIncident(bool value, {bool notify = false}) {
    if (_disposed) return;
    _hasCurrentIncident = value;
    if (notify) _notify();
  }

  /// 从启动层直接进入 App，不选择也不新建警情。
  bool enterWithoutIncident({bool? hasCurrentIncident, bool notify = true}) {
    if (_disposed) return false;
    final hasIncident = hasCurrentIncident ?? _hasCurrentIncident;
    if (hasIncident || _isGuest) return false;
    _enteredWithoutIncident = true;
    if (notify) _notify();
    return true;
  }

  /// 从首页或其他处警入口重新打开警情选择层。
  bool requestIncidentSelection({
    bool? hasCurrentIncident,
    bool notify = true,
  }) {
    if (_disposed) return false;
    final hasIncident = hasCurrentIncident ?? _hasCurrentIncident;
    if (hasIncident || _isGuest) return false;
    _enteredWithoutIncident = false;
    if (notify) _notify();
    return true;
  }

  void setEnteredWithoutIncident(bool value, {bool notify = false}) {
    if (_disposed) return;
    _enteredWithoutIncident = value;
    if (notify) _notify();
  }

  void setConfig(ApiConfig? value, {bool notify = false}) {
    if (_disposed) return;
    _config = value;
    if (notify) _notify();
  }

  void setAuthenticated(bool value, {bool notify = false}) {
    if (_disposed) return;
    _authenticated = value;
    if (notify) _notify();
  }

  void setGuestMode(bool value, {bool notify = false}) {
    if (_disposed) return;
    _isGuest = value;
    if (notify) _notify();
  }

  void setOfflineReviewCount(int count, {bool notify = false}) {
    if (_disposed) return;
    _offlineReviewCount = count;
    if (notify) _notify();
  }

  /// 吊销受保护数据：递增 [protectedDataEpoch]、标记吊销、清空敏感缓存与最近访问记录。
  void revokeProtectedData({bool notify = true}) {
    if (_disposed) return;
    _offlineReviewCount = 0;
    _adminCapability = null;
    _adminCapabilityRequest++;
    _clearMemberReviewInternal();
    _protectedDataRevoked = true;
    _protectedDataEpoch++;
    unawaited(_keySiteRecents.clearAll());
    if (notify) _notify();
  }

  /// 认证成功后恢复受保护数据读权限并开启新代际。
  void grantProtectedDataAccess({bool notify = false}) {
    if (_disposed) return;
    _protectedDataRevoked = false;
    _protectedDataEpoch++;
    if (notify) _notify();
  }

  /// 认证完成后的原子状态迁移（由 `SessionOrchestrator` 调用）。
  void markAuthenticated({
    ApiConfig? config,
    bool grantProtectedData = true,
    bool notify = true,
  }) {
    if (_disposed) return;
    _isGuest = false;
    _enteredWithoutIncident = false;
    if (grantProtectedData) {
      _protectedDataRevoked = false;
      _protectedDataEpoch++;
    }
    _authenticated = true;
    if (config != null) _config = config;
    if (notify) _notify();
  }

  /// 切入游客模式的原子状态迁移（由 `SessionOrchestrator` 调用）。
  void markGuestMode({bool hasCurrentIncident = true, bool notify = true}) {
    if (_disposed) return;
    revokeProtectedData(notify: false);
    _authenticated = false;
    _isGuest = true;
    _hasCurrentIncident = hasCurrentIncident;
    if (notify) _notify();
  }

  /// 退出单位或认证失效时的原子重置（由 `SessionOrchestrator` 调用）。
  void resetUnauthenticated({
    bool revokeData = true,
    bool clearConfig = true,
    bool notify = true,
  }) {
    if (_disposed) return;
    if (revokeData) {
      revokeProtectedData(notify: false);
    } else {
      _clearMemberReviewInternal();
    }
    _authenticated = false;
    _isGuest = false;
    _enteredWithoutIncident = false;
    _hasCurrentIncident = false;
    if (clearConfig) _config = null;
    if (notify) _notify();
  }

  /// 为一次管理员能力拉取分配代际与请求序号；若当前无读权限则返回 null。
  ({int epoch, int request})? beginAdminCapabilityRequest() {
    if (_disposed || !canReadKeySites) return null;
    return (
      epoch: _protectedDataEpoch,
      request: ++_adminCapabilityRequest,
    );
  }

  /// 带代际与请求号校验回写管理员能力，拦截乱序迟到响应。
  bool applyAdminCapability(
    AdminCapability? capability, {
    required int epoch,
    required int request,
    bool requireCanReadKeySites = true,
    bool notify = true,
  }) {
    if (_disposed) return false;
    if (epoch != _protectedDataEpoch || request != _adminCapabilityRequest) {
      return false;
    }
    if (requireCanReadKeySites && !canReadKeySites) return false;
    _adminCapability = capability;
    if (notify) _notify();
    return true;
  }

  /// 刷新管理员能力（保留 `AppController.refreshAdminCapability` 乱序保护语义）。
  Future<void> refreshAdminCapability(
    Future<AdminCapability?> Function() fetcher, {
    bool Function()? isSessionActive,
  }) async {
    final token = beginAdminCapabilityRequest();
    if (token == null) return;
    final activeConfig = _config;
    bool sameClient() =>
        identical(_config, activeConfig) && (isSessionActive?.call() ?? true);
    try {
      final capability = await fetcher();
      if (!sameClient()) return;
      applyAdminCapability(
        capability,
        epoch: token.epoch,
        request: token.request,
      );
    } catch (_) {
      if (!sameClient()) return;
      applyAdminCapability(
        null,
        epoch: token.epoch,
        request: token.request,
        requireCanReadKeySites: false,
      );
    }
  }

  bool shouldRefreshAdminCapabilityForEvent(String? memberId) =>
      _adminCapability == null || memberId == _adminCapability!.memberId;

  void clearAdminCapability({
    bool invalidateInFlight = false,
    bool notify = true,
  }) {
    if (_disposed) return;
    if (invalidateInFlight) _adminCapabilityRequest++;
    _adminCapability = null;
    if (notify) _notify();
  }

  void clearMemberReview({bool notify = false}) {
    if (_disposed) return;
    _clearMemberReviewInternal();
    if (notify) _notify();
  }

  /// 共享单位审批收件箱刷新：并发合并并在在途收到新事件时自动补拉一轮。
  Future<void> refreshPendingMembers({
    required Future<bool> Function() fetchCapability,
    required Future<List<UnitMember>> Function() fetchPending,
    required Future<List<Map<String, dynamic>>> Function() fetchHistory,
    Future<String> Function()? fetchUnitName,
    bool Function()? isSessionActive,
  }) {
    if (_disposed ||
        !_authenticated ||
        _config == null ||
        _isGuest ||
        _protectedDataRevoked) {
      return Future<void>.value();
    }
    final existing = _memberReviewFuture;
    if (existing != null) {
      _memberReviewAgain = true;
      return existing;
    }
    final generation = _memberReviewGeneration;
    Future<void> drain() async {
      try {
        do {
          _memberReviewAgain = false;
          await _refreshMemberReviewOnce(
            fetchCapability: fetchCapability,
            fetchPending: fetchPending,
            fetchHistory: fetchHistory,
            fetchUnitName: fetchUnitName ?? () => Settings.unitName,
            isSessionActive: isSessionActive,
          );
        } while (_memberReviewAgain &&
            !_disposed &&
            generation == _memberReviewGeneration);
      } finally {
        if (generation == _memberReviewGeneration) {
          _memberReviewFuture = null;
        }
      }
    }

    final future = drain();
    _memberReviewFuture = future;
    return future;
  }

  Future<void> _refreshMemberReviewOnce({
    required Future<bool> Function() fetchCapability,
    required Future<List<UnitMember>> Function() fetchPending,
    required Future<List<Map<String, dynamic>>> Function() fetchHistory,
    required Future<String> Function() fetchUnitName,
    bool Function()? isSessionActive,
  }) async {
    final activeConfig = _config;
    final epoch = _protectedDataEpoch;
    final generation = _memberReviewGeneration;
    bool current() =>
        !_disposed &&
        _authenticated &&
        !_isGuest &&
        !_protectedDataRevoked &&
        identical(_config, activeConfig) &&
        (isSessionActive?.call() ?? true) &&
        epoch == _protectedDataEpoch &&
        generation == _memberReviewGeneration;
    _memberReviewLoading = true;
    _notify();
    try {
      final allowed = await fetchCapability();
      if (!current()) return;
      _canReviewMembers = allowed;
      if (!allowed) {
        _pendingMembers = const <UnitMember>[];
        _memberReviewHistory = const <Map<String, dynamic>>[];
        _pendingMemberCount = 0;
        _memberReviewError = null;
        return;
      }
      final unitName = await fetchUnitName();
      final pending = await fetchPending();
      final history = await fetchHistory();
      if (!current()) return;
      _memberReviewUnitName = unitName;
      _pendingMembers = List<UnitMember>.unmodifiable(pending);
      _pendingMemberCount = pending.length;
      _memberReviewHistory = List<Map<String, dynamic>>.unmodifiable(history);
      _memberReviewError = null;
    } catch (error) {
      if (!current()) return;
      _memberReviewError = error.toString();
      // 鉴权失败或不确定时立即清空成员个人数据，绝不残留。
      if (error is ApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        _canReviewMembers = false;
        _pendingMembers = const <UnitMember>[];
        _memberReviewHistory = const <Map<String, dynamic>>[];
        _pendingMemberCount = 0;
      }
    } finally {
      if (current()) {
        _memberReviewLoading = false;
        _notify();
      }
    }
  }

  void notifyStateChanged() => _notify();

  void _clearMemberReviewInternal() {
    _memberReviewUnitName = '';
    _memberReviewGeneration++;
    _memberReviewFuture = null;
    _memberReviewAgain = false;
    _canReviewMembers = false;
    _memberReviewLoading = false;
    _memberReviewError = null;
    _pendingMembers = const <UnitMember>[];
    _memberReviewHistory = const <Map<String, dynamic>>[];
    _pendingMemberCount = 0;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _adminCapabilityRequest++;
    _memberReviewGeneration++;
    _memberReviewFuture = null;
    _memberReviewAgain = false;
    super.dispose();
  }
}
