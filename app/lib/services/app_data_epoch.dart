import 'package:shared_preferences/shared_preferences.dart';

import 'chat_history.dart';
import 'diagnostic_log_service.dart';
import 'foreground_keep_alive.dart';
import 'local_asr_service.dart';
import 'offline_queue.dart';
import 'op_log_service.dart';
import 'secure_store.dart';

/// 新版协议的数据纪元。只执行一次，保证旧 APK 的轮询状态、会话和离线
/// 队列不会以错误单位身份进入 PostgreSQL + WebSocket 架构。
const currentAppDataEpoch = 2;
const _epochKey = 'app_data_epoch';

Future<void> ensureAppDataEpoch() async {
  final sp = await SharedPreferences.getInstance();
  if (sp.getInt(_epochKey) == currentAppDataEpoch) return;

  try {
    await ForegroundKeepAlive.stop();
  } catch (_) {}
  await sp.clear();
  for (final key in [
    'api_token',
    'session_token',
    'unit_code',
    'keepalive_token',
    'keepalive_session_token',
  ]) {
    await SecureStore.delete(key);
  }
  await OfflineQueue.instance.clearAll();
  await ChatHistory.clear();
  await OpLogService.instance.clearLocal();
  await DiagnosticLogService.instance.clearLocal();
  await LocalAsrService.clearDownloadedModelCache();

  // clearLocal 会重新写入其专属日志键；纪元标记最后写入，确保中途失败时
  // 下次启动仍会重试完整清理，而不会留下半迁移状态。
  await sp.setInt(_epochKey, currentAppDataEpoch);
}
