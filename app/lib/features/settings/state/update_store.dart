import 'package:flutter/foundation.dart';

import '../../../services/op_log_service.dart';
import '../../../services/settings.dart';
import '../../../services/update_service.dart';

export '../../../services/update_service.dart' show UpdateInfo;

typedef UpdateServiceFactory = UpdateService Function(UpdateEventLogger logger);
typedef UpdateTraceRecorder =
    void Function(
      String opId,
      String stage,
      String message, {
      String level,
      Map<String, dynamic>? data,
    });

/// 应用更新检查态与语音/语义云端开关 Store。
///
/// 严格复用冻结引擎 [UpdateService]（含缺 `sha256` 清单整份拒收校验）与 [Settings]，
/// 不依赖任何其他业务 Store、模型或 API 客户端。
class UpdateStore extends ChangeNotifier {
  final UpdateServiceFactory _updateServiceFactory;
  final UpdateTraceRecorder _traceRecorder;
  final int Function() _nowMs;

  UpdateInfo? _pendingUpdate;
  bool _updateCheckDone = false;
  String? _updateCheckError;

  /// 语音识别联网开关：开 = 云端优先失败自动切本地；关 = 强制本地。
  /// 默认开启（云端优先，精度高）；手动关闭时提示下载本地模型。
  bool _asrCloudEnabled = true;

  /// 语义解析联网开关：开 = 云端优先失败自动切本地；关 = 强制本地。
  bool _parseCloudEnabled = true;

  bool _disposed = false;

  UpdateStore({
    UpdateServiceFactory? updateServiceFactory,
    UpdateTraceRecorder? traceRecorder,
    int Function()? nowMs,
  }) : _updateServiceFactory = updateServiceFactory ?? _defaultUpdateService,
       _traceRecorder = traceRecorder ?? _defaultTraceRecorder,
       _nowMs = nowMs ?? _defaultNowMs;

  static UpdateService _defaultUpdateService(UpdateEventLogger logger) =>
      UpdateService(logger: logger);

  static void _defaultTraceRecorder(
    String opId,
    String stage,
    String message, {
    String level = 'info',
    Map<String, dynamic>? data,
  }) {
    OpLogService.instance.record(
      opId,
      stage,
      message,
      level: level,
      data: data,
    );
  }

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// 启动时从 ALI OTA 检查到的新版本（非空 = 有新版本可更新）。
  UpdateInfo? get pendingUpdate => _pendingUpdate;

  /// 是否已完成一次版本检查（区分「未检查」与「已是最新」）。
  bool get updateCheckDone => _updateCheckDone;

  /// 最近一次检查失败的错误信息（非空 = 检查失败，设置页提示可重试）。
  String? get updateCheckError => _updateCheckError;

  bool get hasPendingUpdate => _pendingUpdate != null;
  bool get asrCloudEnabled => _asrCloudEnabled;
  bool get parseCloudEnabled => _parseCloudEnabled;
  bool get isDisposed => _disposed;

  void setPendingUpdate(UpdateInfo? value, {bool notify = false}) {
    if (_disposed) return;
    _pendingUpdate = value;
    if (notify) _notify();
  }

  void setUpdateCheckDone(bool value, {bool notify = false}) {
    if (_disposed) return;
    _updateCheckDone = value;
    if (notify) _notify();
  }

  void setUpdateCheckError(String? value, {bool notify = false}) {
    if (_disposed) return;
    _updateCheckError = value;
    if (notify) _notify();
  }

  /// 启动静默检查更新：失败不打扰用户，只更新状态供设置页展示。
  Future<void> checkUpdateSilently() async {
    final opId = 'release-check-${_nowMs()}';
    void trace(String stage, String message, String level) {
      _traceRecorder(
        opId,
        stage,
        message,
        level: level,
        data: const {'source': 'ALI OTA'},
      );
    }

    try {
      final (info, error) = await _updateServiceFactory(
        (stage, message, level) => trace(stage, message, level),
      ).checkForUpdate();
      if (_disposed) return;
      _pendingUpdate = info;
      _updateCheckError = error;
    } catch (e) {
      // 网络/解析失败静默，用户可在设置页手动检查
      if (_disposed) return;
      _updateCheckError = '$e';
      trace('release_check_fail', '$e', 'error');
    }
    _updateCheckDone = true;
    _notify();
  }

  /// 记录一次版本检查结果（设置页手动检查后调用，刷新共享提示状态）。
  void recordUpdateCheck(UpdateInfo? info, String? error) {
    if (_disposed) return;
    _pendingUpdate = info;
    _updateCheckError = error;
    _updateCheckDone = true;
    _notify();
  }

  /// 从 [Settings] 重新载入语音/语义云端开关（配置刷新时由编排器调用）。
  Future<void> loadCloudPreferences({bool notify = true}) async {
    final asr = await Settings.asrCloudEnabled;
    final parse = await Settings.parseCloudEnabled;
    if (_disposed) return;
    _asrCloudEnabled = asr;
    _parseCloudEnabled = parse;
    if (notify) _notify();
  }

  /// 同步应用已读取的云端开关值（供编排器批量刷新配置后统一通知）。
  void applyCloudPreferences({
    required bool asrCloudEnabled,
    required bool parseCloudEnabled,
    bool notify = false,
  }) {
    if (_disposed) return;
    _asrCloudEnabled = asrCloudEnabled;
    _parseCloudEnabled = parseCloudEnabled;
    if (notify) _notify();
  }

  /// 更新语音识别联网开关并持久化到 [Settings]。
  Future<void> setAsrCloudEnabled(
    bool value, {
    bool persist = true,
    bool markModified = false,
    bool notify = true,
  }) async {
    if (_disposed) return;
    if (persist) {
      await Settings.setAsrCloudEnabled(value);
      if (markModified) {
        await Settings.markModified(_nowMs());
      }
    }
    if (_disposed) return;
    _asrCloudEnabled = value;
    if (notify) _notify();
  }

  /// 更新语义解析联网开关并持久化到 [Settings]。
  Future<void> setParseCloudEnabled(
    bool value, {
    bool persist = true,
    bool markModified = false,
    bool notify = true,
  }) async {
    if (_disposed) return;
    if (persist) {
      await Settings.setParseCloudEnabled(value);
      if (markModified) {
        await Settings.markModified(_nowMs());
      }
    }
    if (_disposed) return;
    _parseCloudEnabled = value;
    if (notify) _notify();
  }

  /// 同步更新内存开关（供过渡门面属性转发或单元测试使用，不写盘）。
  void setAsrCloudEnabledSync(bool value, {bool notify = false}) {
    if (_disposed) return;
    _asrCloudEnabled = value;
    if (notify) _notify();
  }

  /// 同步更新内存开关（供过渡门面属性转发或单元测试使用，不写盘）。
  void setParseCloudEnabledSync(bool value, {bool notify = false}) {
    if (_disposed) return;
    _parseCloudEnabled = value;
    if (notify) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
