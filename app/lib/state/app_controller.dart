import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../app/app_scope.dart';
import '../core/diagnostics/app_logger.dart';
import '../core/sync/sync_store.dart' show SyncStore;
import '../features/auth/state/session_store.dart' show SessionStore;
import '../features/incident/state/incident_store.dart' show IncidentStore;
import '../features/roster/state/roster_store.dart' show RosterStore;
import '../features/settings/state/update_store.dart' show UpdateStore;
import '../models/models.dart';
import '../models/key_sites.dart';
import '../models/admin_login.dart';
import '../services/alarm_service.dart';
import '../services/chat_history.dart';
import '../services/key_site_recents.dart';
import '../services/diagnostic_log_service.dart';
import '../services/foreground_keep_alive.dart';
import '../services/local_asr_service.dart';
import '../services/media_capture_service.dart';
import '../services/local_parser.dart';
import '../services/op_log_service.dart';
import '../services/offline_queue.dart';
import '../services/note_media_upload_queue.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/scoped_json_cache.dart';
import '../services/tts_service.dart';
import '../services/update_service.dart';
import '../services/org_directory.dart';
import '../services/sync_coordinator.dart';
import '../services/sync_reducer.dart';


part 'app_controller_state.dart';
part 'app_controller_lifecycle.dart';
part 'app_controller_config.dart';
part 'app_controller_auth.dart';
part 'app_controller_sync.dart';
part 'app_controller_realtime.dart';
part 'app_controller_monitor.dart';
part 'app_controller_incident.dart';
part 'app_controller_external_incident.dart';
part 'app_controller_notes_chat.dart';
part 'app_controller_roster_voice.dart';

typedef OfflineOperationEnqueuer =
    Future<void> Function({
      required String incidentId,
      required String type,
      required int occurredAt,
      required String clientOpId,
      required Map<String, dynamic> payload,
    });
typedef OfflineQueueDrainer = Future<void> Function();
typedef ApiClientFactory =
    ApiClient Function({
      required String baseUrl,
      required String incidentId,
      required String sessionToken,
      required String deviceId,
      required String actorName,
      required String unitId,
      required String unitCode,
      void Function(ApiException error)? onAuthenticationFailure,
    });


class AppController extends _AppControllerBase
    with
        _AppControllerLifecycleMixin,
        _AppControllerConfigMixin,
        _AppControllerAuthMixin,
        _AppControllerSyncMixin,
        _AppControllerRealtimeMixin,
        _AppControllerMonitorMixin,
        _AppControllerIncidentMixin,
        _AppControllerExternalIncidentMixin,
        _AppControllerNotesChatMixin,
        _AppControllerRosterVoiceMixin {
  static const int connectionLostThreshold = 30000;
  static const Duration foregroundTickInterval = Duration(seconds: 1);
  static const Duration backgroundTickInterval = Duration(seconds: 5);
  static const Duration sessionRefreshCheckInterval = Duration(minutes: 15);
  static const Duration sessionRefreshLeadTime = Duration(hours: 1);

  AppController({
    super.localAsr,
    super.offlineOperationEnqueuer,
    super.offlineQueueDrainer,
    @visibleForTesting super.syncClientFactory,
    @visibleForTesting super.apiFactory,
    @visibleForTesting super.nowMs,
    super.appScope,
  }) {
    NoteMediaUploadQueue.instance.addListener(_onNoteMediaQueueChanged);
  }

  /// 通知只在 exitAt 变化时重排；同一到期时间重复同步不得反复 cancel+schedule。
  @visibleForTesting
  static bool shouldRescheduleNotification({
    required int? scheduledExitAt,
    required int exitAt,
  }) => scheduledExitAt != exitAt;

  /// 将尚未上传成功的离线队列操作投影到本地在场人员与日志快照。
  static (List<Entry>, List<Note>) applyOfflineOperationProjection({
    required Iterable<Map<String, Object?>> rows,
    required List<Entry> entries,
    required List<Note> notes,
    required CalcConfig calcConfig,
    required String author,
  }) => _applyOfflineOperationProjection(
    rows: rows,
    entries: entries,
    notes: notes,
    calcConfig: calcConfig,
    author: author,
  );

  @override
  void dispose() {
    _disposed = true;
    NoteMediaUploadQueue.instance.removeListener(_onNoteMediaQueueChanged);
    _adminCapabilityTimer?.cancel();
    _sessionGeneration++;
    _activeManualRefreshOps.clear();
    _manualRefreshInFlight = false;
    _activeLegacySyncOps.clear();
    _legacySyncInFlight = false;
    _recomputeSyncing();
    unawaited(OpLogService.instance.flushLocal());
    unawaited(_syncCoordinator?.stop() ?? Future<void>.value());
    _tickTimer?.cancel();
    _sessionRefreshTimer?.cancel();
    _syncFuture = null;
    _keepAliveFuture = null;
    api?.dispose();
    unawaited(_stopKeepAliveSafely());
    unawaited(_clearScheduledNotifications());
    unawaited(localAsr?.dispose());
    if (_ownsAppScope) {
      _appScope?.dispose();
    }
    _appScope = null;
    tts.stop();
    clockTick.dispose();
    super.dispose();
  }
}

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
