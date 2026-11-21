import 'package:flutter/foundation.dart';

import '../../services/sync_coordinator.dart' show SyncConnectionState;

export '../../services/sync_coordinator.dart' show SyncConnectionState;

/// 同步状态指示器统一计算规则：
/// - 已释放或游客模式 -> false；
/// - 主动手动刷新（refreshNow）或旧路径同步进行中 -> true；
/// - 未认证或已停止且无启动任务 -> false；
/// - 实时通道已连接（connected）-> false；
/// - 首次快照尚未就绪时：未超过 30 秒断线阈值且仍在同步/启动/连接中 -> true，超时后 -> false（转「已中断」）；
/// - 首次快照就绪后：返回 false（30 秒内保「已连接」，超 30 秒转「已中断」）。
@visibleForTesting
bool shouldShowSyncingIndicator({
  required bool disposed,
  required bool isGuest,
  required bool authenticated,
  required SyncConnectionState syncConnectionState,
  required bool syncSnapshotApplied,
  required bool connectionLost,
  required bool coordinatorRunning,
  required bool realtimeStarting,
  required bool manualRefreshInFlight,
  required bool legacySyncInFlight,
}) {
  if (disposed || isGuest) return false;
  if (manualRefreshInFlight || legacySyncInFlight) return true;
  if (!authenticated) return false;
  if (syncConnectionState == SyncConnectionState.connected) return false;
  if (syncConnectionState == SyncConnectionState.stopped &&
      !coordinatorRunning &&
      !realtimeStarting) {
    return false;
  }
  if (!syncSnapshotApplied) {
    if (connectionLost) return false;
    return coordinatorRunning ||
        realtimeStarting ||
        syncConnectionState == SyncConnectionState.bootstrapping ||
        syncConnectionState == SyncConnectionState.connecting;
  }
  return false;
}

/// 平滑断线判定纯函数（可单测）：
/// 实时同步连接已建立时保持在线；从未同步成功（lastSyncSuccessAt == 0）
/// → 乐观视为已连接；距上次成功超过 [thresholdMs] 毫秒 → 断线。
bool isConnectionLost({
  required int lastSyncSuccessAt,
  required int nowMs,
  int thresholdMs = 30000,
  bool syncConnected = false,
  int firstSyncFailureAt = 0,
}) {
  if (syncConnected) return false;
  if (lastSyncSuccessAt <= 0) {
    // 首次启动的冷启动、网关实例唤醒或瞬时网络抖动不应立刻显示红色。
    return firstSyncFailureAt > 0 && nowMs - firstSyncFailureAt > thresholdMs;
  }
  return nowMs - lastSyncSuccessAt > thresholdMs;
}

/// 后台值守只属于当前已认证且已选择的警情；开关偏好本身不因退出警情而改变。
bool shouldRunForegroundKeepAlive({
  required bool enabled,
  required bool authenticated,
  required String incidentId,
}) => enabled && authenticated && incidentId.trim().isNotEmpty;

/// 实时同步连接态与 30 秒平滑断线健康度 Store。
///
/// 仅持有同步通道健康指标与在途刷新状态，由上层编排器驱动状态跃迁，
/// 不反向依赖任何业务 Store、模型或 API 客户端。
class SyncStore extends ChangeNotifier {
  /// 平滑断线判定：实时 WebSocket 已建立时保持在线；连接进入错误/重连后，
  /// 连续超过 [connectionLostThreshold] 毫秒没有同步成功才视为断线，避免网络
  /// 瞬时抖动导致连接状态频繁变红。从未成功过时乐观视为已连接。
  static const int connectionLostThreshold = 30000;

  /// 重试告警日志最小节流间隔（毫秒），避免断网重连期刷爆操作日志。
  static const int defaultErrorLogThrottleMs = 15000;

  final int Function() _nowMs;

  SyncConnectionState _syncConnectionState = SyncConnectionState.stopped;
  bool _syncing = false;
  String? _syncError;
  int _lastSyncSuccessAt = 0;
  int _firstSyncFailureAt = 0;
  int _lastSyncErrorLogAt = 0;
  bool _syncSnapshotApplied = false;
  bool _lastConnectionLost = false;
  bool _syncStarted = false;

  int _nextSyncOpToken = 0;
  final Set<int> _activeManualRefreshOps = <int>{};
  final Set<int> _activeLegacySyncOps = <int>{};
  bool _manualRefreshInFlight = false;
  bool _legacySyncInFlight = false;

  bool _authenticated = false;
  bool _isGuest = false;
  bool _coordinatorRunning = false;
  bool _realtimeStarting = false;
  bool _disposed = false;

  SyncStore({int Function()? nowMs}) : _nowMs = nowMs ?? _defaultNowMs;

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

  SyncConnectionState get syncConnectionState => _syncConnectionState;
  bool get isSyncConnected =>
      _syncConnectionState == SyncConnectionState.connected;
  bool get syncing => _syncing;
  String? get syncError => _syncError;
  int get lastSyncSuccessAt => _lastSyncSuccessAt;
  int get firstSyncFailureAt => _firstSyncFailureAt;
  int get lastSyncErrorLogAt => _lastSyncErrorLogAt;
  bool get syncSnapshotApplied => _syncSnapshotApplied;
  bool get lastConnectionLost => _lastConnectionLost;
  bool get syncStarted => _syncStarted;
  bool get manualRefreshInFlight => _manualRefreshInFlight;
  bool get legacySyncInFlight => _legacySyncInFlight;
  bool get isDisposed => _disposed;

  bool get connectionLost => isConnectionLost(
    lastSyncSuccessAt: _lastSyncSuccessAt,
    firstSyncFailureAt: _firstSyncFailureAt,
    nowMs: _nowMs(),
    thresholdMs: connectionLostThreshold,
    syncConnected: _syncConnectionState == SyncConnectionState.connected,
  );

  /// 更新编排层传入的会话/协调器上下文，用于重算 [syncing]。
  void updateSyncContext({
    bool? authenticated,
    bool? isGuest,
    bool? coordinatorRunning,
    bool? realtimeStarting,
    bool notify = false,
  }) {
    if (_disposed) return;
    if (authenticated != null) _authenticated = authenticated;
    if (isGuest != null) _isGuest = isGuest;
    if (coordinatorRunning != null) _coordinatorRunning = coordinatorRunning;
    if (realtimeStarting != null) _realtimeStarting = realtimeStarting;
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  /// 重新计算 [syncing]（可选覆盖最新上下文开关）。
  bool recomputeSyncing({
    bool? authenticated,
    bool? isGuest,
    bool? coordinatorRunning,
    bool? realtimeStarting,
    bool notify = false,
  }) {
    if (authenticated != null) _authenticated = authenticated;
    if (isGuest != null) _isGuest = isGuest;
    if (coordinatorRunning != null) _coordinatorRunning = coordinatorRunning;
    if (realtimeStarting != null) _realtimeStarting = realtimeStarting;
    _recomputeSyncingInternal();
    if (notify) _notify();
    return _syncing;
  }

  /// 处理实时通道状态变更。返回值表示本次错误是否通过 15 秒日志节流闸门。
  bool applyConnectionState(
    SyncConnectionState state, {
    Object? error,
    bool? coordinatorRunning,
    int errorLogThrottleMs = defaultErrorLogThrottleMs,
    bool notify = true,
  }) {
    if (_disposed) return false;
    if (coordinatorRunning != null) {
      _coordinatorRunning = coordinatorRunning;
    }
    final now = _nowMs();
    final wasConnected = _syncConnectionState == SyncConnectionState.connected;
    _syncConnectionState = state;
    var shouldLogError = false;
    if (state == SyncConnectionState.connected) {
      _lastSyncSuccessAt = now;
      _firstSyncFailureAt = 0;
      _syncError = null;
    } else if (state == SyncConnectionState.stopped) {
      // 由 shouldShowSyncingIndicator 统一收口状态计算
    } else {
      if (wasConnected) {
        // 实时通道刚掉线：从掉线时刻重新起算 30 秒平滑窗口
        _lastSyncSuccessAt = now;
        _firstSyncFailureAt = now;
      }
      _syncError = null;
      if (error != null ||
          state == SyncConnectionState.reconnecting ||
          state == SyncConnectionState.error) {
        _firstSyncFailureAt = _firstSyncFailureAt == 0
            ? now
            : _firstSyncFailureAt;
      }
      if (error != null && now - _lastSyncErrorLogAt >= errorLogThrottleMs) {
        _lastSyncErrorLogAt = now;
        shouldLogError = true;
      }
    }
    _lastConnectionLost = connectionLost;
    _recomputeSyncingInternal();
    if (notify) _notify();
    return shouldLogError;
  }

  /// 记录一次同步成功（快照落位、实时事件或旧路径拉取成功）。
  void recordSyncSuccess({bool snapshotApplied = false, bool notify = true}) {
    if (_disposed) return;
    if (snapshotApplied) {
      _syncSnapshotApplied = true;
    }
    _lastSyncSuccessAt = _nowMs();
    _firstSyncFailureAt = 0;
    _syncError = null;
    _lastConnectionLost = connectionLost;
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  /// 记录旧路径拉取失败；返回是否应写入节流告警日志。
  bool recordLegacySyncFailure({
    Object? error,
    bool clearFailureWindow = false,
    int errorLogThrottleMs = defaultErrorLogThrottleMs,
    bool notify = false,
  }) {
    if (_disposed) return false;
    if (clearFailureWindow) {
      _syncError = null;
      _firstSyncFailureAt = 0;
      if (notify) _notify();
      return false;
    }
    final now = _nowMs();
    _firstSyncFailureAt = _firstSyncFailureAt == 0 ? now : _firstSyncFailureAt;
    _syncError = null;
    var shouldLogError = false;
    if (error != null && now - _lastSyncErrorLogAt >= errorLogThrottleMs) {
      _lastSyncErrorLogAt = now;
      shouldLogError = true;
    }
    if (notify) _notify();
    return shouldLogError;
  }

  /// 在时钟滴答或回到前台时检查是否跨越 30 秒平滑断线阈值。
  /// 仅当断线态发生变化时更新状态并返回 true。
  bool checkConnectionLostTransition({bool notify = true}) {
    if (_disposed) return false;
    final lost = connectionLost;
    if (lost == _lastConnectionLost) return false;
    _lastConnectionLost = lost;
    _recomputeSyncingInternal();
    if (notify) _notify();
    return true;
  }

  /// 标记一次手动下拉刷新开始，返回用于配对结束的令牌。
  int beginManualRefresh({bool notify = true}) {
    final opToken = ++_nextSyncOpToken;
    _activeManualRefreshOps.add(opToken);
    _manualRefreshInFlight = true;
    _recomputeSyncingInternal();
    if (notify) _notify();
    return opToken;
  }

  /// 结束对应的手动刷新令牌。
  void endManualRefresh(int opToken, {bool notify = true}) {
    _activeManualRefreshOps.remove(opToken);
    _manualRefreshInFlight = _activeManualRefreshOps.isNotEmpty;
    _lastConnectionLost = connectionLost;
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  /// 标记一次旧路径全量同步开始，返回用于配对结束的令牌。
  int beginLegacySync({bool notify = true}) {
    final opToken = ++_nextSyncOpToken;
    _activeLegacySyncOps.add(opToken);
    _legacySyncInFlight = true;
    _recomputeSyncingInternal();
    if (notify) _notify();
    return opToken;
  }

  /// 结束对应的旧路径全量同步令牌。
  void endLegacySync(int opToken, {bool notify = true}) {
    _activeLegacySyncOps.remove(opToken);
    _legacySyncInFlight = _activeLegacySyncOps.isNotEmpty;
    _lastConnectionLost = connectionLost;
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  void setSyncStarted(bool value, {bool notify = false}) {
    if (_disposed) return;
    _syncStarted = value;
    if (notify) _notify();
  }

  void setSyncSnapshotApplied(bool value, {bool notify = false}) {
    if (_disposed) return;
    _syncSnapshotApplied = value;
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  void setSyncError(String? value, {bool notify = true}) {
    if (_disposed) return;
    _syncError = value;
    if (notify) _notify();
  }

  void clearInFlightOps({bool notify = false}) {
    _activeManualRefreshOps.clear();
    _manualRefreshInFlight = false;
    _activeLegacySyncOps.clear();
    _legacySyncInFlight = false;
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  /// 重置会话级同步健康时间戳与错误标记（退单/吊销时调用）。
  void resetSessionHealth({bool notify = false}) {
    _lastSyncSuccessAt = 0;
    _firstSyncFailureAt = 0;
    _lastSyncErrorLogAt = 0;
    _syncSnapshotApplied = false;
    _lastConnectionLost = false;
    _syncError = null;
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  /// 停止同步并清空在途状态（退出单位或认证失效时调用）。
  void resetForStop({bool resetHealth = false, bool notify = false}) {
    _syncStarted = false;
    _syncSnapshotApplied = false;
    _coordinatorRunning = false;
    _realtimeStarting = false;
    _syncConnectionState = SyncConnectionState.stopped;
    _activeManualRefreshOps.clear();
    _manualRefreshInFlight = false;
    _activeLegacySyncOps.clear();
    _legacySyncInFlight = false;
    if (resetHealth) {
      _lastSyncSuccessAt = 0;
      _firstSyncFailureAt = 0;
      _lastSyncErrorLogAt = 0;
      _lastConnectionLost = false;
      _syncError = null;
    }
    _recomputeSyncingInternal();
    if (notify) _notify();
  }

  void notifyStateChanged() => _notify();

  void _recomputeSyncingInternal() {
    _syncing = shouldShowSyncingIndicator(
      disposed: _disposed,
      isGuest: _isGuest,
      authenticated: _authenticated,
      syncConnectionState: _syncConnectionState,
      syncSnapshotApplied: _syncSnapshotApplied,
      connectionLost: connectionLost,
      coordinatorRunning: _coordinatorRunning,
      realtimeStarting: _realtimeStarting,
      manualRefreshInFlight: _manualRefreshInFlight,
      legacySyncInFlight: _legacySyncInFlight,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _activeManualRefreshOps.clear();
    _manualRefreshInFlight = false;
    _activeLegacySyncOps.clear();
    _legacySyncInFlight = false;
    _recomputeSyncingInternal();
    super.dispose();
  }
}
