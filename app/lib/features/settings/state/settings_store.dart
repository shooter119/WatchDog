import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../services/alarm_service.dart';
import '../../../services/foreground_keep_alive.dart';
import '../../../services/local_asr_service.dart';
import '../../../services/op_log_service.dart';
import '../../../services/screen_on.dart';
import '../../../services/settings.dart';
import '../../../services/storage_service.dart';
import '../../../services/theme_controller.dart';
import '../../../services/update_service.dart';

export '../../../services/update_service.dart' show UpdateInfo;

/// 设置自动保存状态。
enum SettingsSaveState { idle, saving, saved, failed }

/// 身份与权限只读快照（由外壳注入，零跨 Feature 与零 Store 互调）。
@immutable
class SettingsIdentitySnapshot {
  const SettingsIdentitySnapshot({
    this.isGuest = false, this.authenticated = false,
    this.protectedDataRevoked = false, this.needsAuthentication = false,
    this.protectedDataEpoch = 0, this.realName = '', this.unitName = '',
    this.userRole = 'member', this.canScanAdmin = false,
    this.canReviewMembers = false, this.memberReviewError,
    this.pendingMemberCount = 0, this.offlineReviewCount = 0, this.hasApi = false,
  });

  final bool isGuest, authenticated, protectedDataRevoked, needsAuthentication;
  final bool canScanAdmin, canReviewMembers, hasApi;
  final int protectedDataEpoch, pendingMemberCount, offlineReviewCount;
  final String realName, unitName, userRole;
  final String? memberReviewError;

  bool get effectiveAuthenticated => !isGuest && authenticated && !protectedDataRevoked;
  bool get canManageVideoResources => userRole == 'manager' || userRole == 'admin';
  String get displayName => isGuest ? '游客模式' : effectiveAuthenticated && realName.trim().isNotEmpty ? realName.trim() : '未认证';
  String get displayUnit => effectiveAuthenticated && unitName.trim().isNotEmpty ? unitName.trim() : '未选择单位';
  String get displayRole => isGuest ? '游客' : !effectiveAuthenticated ? '未认证' : (userRole == 'admin' || userRole == 'manager' || canScanAdmin) ? '管理员' : '队员';

  SettingsIdentitySnapshot copyWith({
    bool? authenticated, String? realName, String? unitName, String? userRole, bool? canScanAdmin,
  }) => SettingsIdentitySnapshot(
    isGuest: isGuest, authenticated: authenticated ?? this.authenticated,
    protectedDataRevoked: protectedDataRevoked, needsAuthentication: needsAuthentication,
    protectedDataEpoch: protectedDataEpoch, realName: realName ?? this.realName,
    unitName: unitName ?? this.unitName, userRole: userRole ?? this.userRole,
    canScanAdmin: canScanAdmin ?? this.canScanAdmin, canReviewMembers: canReviewMembers,
    memberReviewError: memberReviewError, pendingMemberCount: pendingMemberCount,
    offlineReviewCount: offlineReviewCount, hasApi: hasApi,
  );
}

/// 服务连接状态快照。
@immutable
class SettingsConnectionSnapshot {
  const SettingsConnectionSnapshot({
    this.isGuest = false, this.connectionLost = false,
    this.syncing = false, this.syncError, this.pendingOfflineCount = 0,
  });

  final bool isGuest, connectionLost, syncing;
  final String? syncError;
  final int pendingOfflineCount;

  String get summary => isGuest ? '单机模式' : syncing ? '同步中' : syncError != null ? '同步失败' : connectionLost ? '已中断' : '已连接';
}

/// 应用更新检查态快照（与外部 UpdateStore 解耦）。
@immutable
class SettingsUpdateSnapshot {
  const SettingsUpdateSnapshot({this.pendingUpdate, this.checkDone = false, this.checkError});
  final UpdateInfo? pendingUpdate;
  final bool checkDone;
  final String? checkError;
}

/// 提醒权限能力快照。
@immutable
class SettingsAlarmCapabilities {
  const SettingsAlarmCapabilities({
    this.exactAlarmAvailable = true,
    this.policyAccessGranted = true,
    this.fullScreenIntentEnabled = true,
  });

  final bool exactAlarmAvailable, policyAccessGranted, fullScreenIntentEnabled;
  SettingsAlarmCapabilities copyWith({bool? policyAccessGranted}) => SettingsAlarmCapabilities(
    exactAlarmAvailable: exactAlarmAvailable,
    policyAccessGranted: policyAccessGranted ?? this.policyAccessGranted,
    fullScreenIntentEnabled: fullScreenIntentEnabled,
  );
}

/// 本地离线语音模型能力注入接口。
class SettingsLocalAsrGateway {
  const SettingsLocalAsrGateway({
    required this.isModelInstalled,
    required this.downloadModel,
    required this.removeModel,
  });

  factory SettingsLocalAsrGateway.fromService(LocalAsrService s) => SettingsLocalAsrGateway(
    isModelInstalled: s.isModelInstalled,
    downloadModel: s.downloadModel,
    removeModel: s.removeModel,
  );

  final Future<bool> Function() isModelInstalled;
  final Future<void> Function({void Function(int received, int total)? onProgress}) downloadModel;
  final Future<void> Function() removeModel;
}

/// 宿主集成与系统能力网关（通过回调注入实现零 Store 互调与零 AppController 依赖）。
class SettingsGateway {
  const SettingsGateway({
    this.onRefreshConfig, this.onStartSync, this.onSyncSettings, this.onSyncKeepAlive,
    this.onTtsEnabledChanged, this.onRefreshNow, this.onRefreshPendingMembersCount,
    this.onLeaveUnit, this.onRefreshAndCheckAdminScan, this.onRecordUpdateCheck,
    this.onSelectThemeId, this.readThemeId, this.themeListenable, this.readRuntimeVersion,
    this.checkPolicyAccess, this.openPolicySettings, this.openNotificationSettings,
    this.requestNotificationPermission, this.requestIgnoreBatteryOptimization,
    this.openAlarmsSettings, this.availableStorageBytes, this.openStorageSettings,
    this.updateServiceFactory, this.canRequestPackageInstalls,
    this.openUnknownAppSourcesSettings, this.localAsr, this.isDebugMode = kDebugMode, this.nowMs,
  });

  final Future<void> Function()? onRefreshConfig, onSyncKeepAlive, onRefreshNow;
  final Future<void> Function()? onRefreshPendingMembersCount, onLeaveUnit;
  final Future<void> Function()? openPolicySettings, openNotificationSettings;
  final Future<void> Function()? requestNotificationPermission, requestIgnoreBatteryOptimization;
  final Future<void> Function()? openAlarmsSettings, openStorageSettings, openUnknownAppSourcesSettings;
  final Future<bool> Function()? onRefreshAndCheckAdminScan, checkPolicyAccess, canRequestPackageInstalls;
  final Future<String> Function()? readRuntimeVersion;
  final Future<int?> Function()? availableStorageBytes;
  final VoidCallback? onStartSync, onSyncSettings;
  final ValueChanged<bool>? onTtsEnabledChanged;
  final ValueChanged<String>? onSelectThemeId;
  final String Function()? readThemeId;
  final Listenable? themeListenable;
  final void Function(UpdateInfo? info, String? error)? onRecordUpdateCheck;
  final UpdateService Function(UpdateEventLogger logger)? updateServiceFactory;
  final SettingsLocalAsrGateway? localAsr;
  final bool isDebugMode;
  final int Function()? nowMs;
}

/// 设置域核心状态 Store（失焦自动保存、开关即时保存、后台值守、离线模型与 OTA 编排）。
class SettingsStore extends ChangeNotifier {
  SettingsStore({
    SettingsGateway gateway = const SettingsGateway(),
    SettingsIdentitySnapshot identity = const SettingsIdentitySnapshot(),
    SettingsConnectionSnapshot connection = const SettingsConnectionSnapshot(),
    SettingsUpdateSnapshot update = const SettingsUpdateSnapshot(),
    SettingsAlarmCapabilities alarmCaps = const SettingsAlarmCapabilities(),
  }) : _gateway = gateway,
       _identity = identity,
       _connection = connection,
       _update = update,
       _alarmCaps = alarmCaps,
       themeId = gateway.readThemeId?.call() ?? ThemeController.instance.currentId {
    _themeListenable = gateway.themeListenable ?? ThemeController.instance;
    _themeListenable?.addListener(_handleExternalThemeChange);
  }

  final SettingsGateway _gateway;
  Listenable? _themeListenable;
  SettingsIdentitySnapshot _identity;
  SettingsConnectionSnapshot _connection;
  SettingsUpdateSnapshot _update;
  SettingsAlarmCapabilities _alarmCaps;
  String serverUrl = Settings.defaultServerUrl, fullPressureText = '30.0', consumptionText = '80.0';
  String warnText = '10', alarmText = '5', runtimeVersion = '', themeId;
  double cylinderVolL = 6.8;
  bool ttsEnabled = true, alarmSoundEnabled = true, keepScreenOn = true, keepAliveEnabled = false;
  bool asrCloudEnabled = true, parseCloudEnabled = true, loaded = false, _saving = false;
  bool _saveQueued = false, checkingUpdate = false, downloadingModel = false, _disposed = false;
  bool? modelInstalled;
  double? downloadProgress;
  String? downloadError;
  SettingsSaveState saveState = SettingsSaveState.idle;

  SettingsGateway get gateway => _gateway;
  SettingsIdentitySnapshot get identity => _identity;
  SettingsConnectionSnapshot get connection => _connection;
  SettingsUpdateSnapshot get update => _update;
  SettingsAlarmCapabilities get alarmCaps => _alarmCaps;
  bool get hasLocalAsr => _gateway.localAsr != null;
  bool get isDebugMode => _gateway.isDebugMode;
  int get _nowMs => _gateway.nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
  String displayVersion(String fallback) => runtimeVersion.isEmpty ? fallback : runtimeVersion;
  String get voiceSummary => asrCloudEnabled ? '在线识别' : '离线识别';
  String get serverSummary => _connection.summary;
  String get calcSummary =>
      '${cylinderVolL == 9.0 ? '9' : '6.8'}L · ${warnText.trim().isEmpty ? '10' : warnText.trim()}/${alarmText.trim().isEmpty ? '5' : alarmText.trim()}分';
  String get alertSummary {
    final items = <String>[
      if (ttsEnabled) '播报',
      if (alarmSoundEnabled) '警报',
      if (keepAliveEnabled) '值守' else if (keepScreenOn) '常亮',
    ];
    return items.isEmpty ? '已关闭' : items.join('·');
  }

  void _handleExternalThemeChange() {
    if (_disposed) return;
    final nextId = _gateway.readThemeId?.call() ?? ThemeController.instance.currentId;
    if (nextId != themeId) { themeId = nextId; _notify(); }
  }

  void syncExternalState({
    SettingsIdentitySnapshot? identity, SettingsConnectionSnapshot? connection,
    SettingsUpdateSnapshot? update, SettingsAlarmCapabilities? alarmCaps,
  }) {
    if (_disposed) return;
    if (identity != null) {
      _identity = (identity.protectedDataRevoked || identity.needsAuthentication)
          ? identity.copyWith(authenticated: false, realName: '', unitName: '', userRole: 'member')
          : identity;
    }
    if (connection != null) _connection = connection;
    if (update != null) _update = update;
    if (alarmCaps != null) _alarmCaps = alarmCaps;
    _notify();
  }

  Future<void> load() async {
    unawaited(_gateway.onRefreshPendingMembersCount?.call());
    serverUrl = await Settings.serverUrl;
    cylinderVolL = await Settings.cylinderVolL;
    fullPressureText = (await Settings.fullPressureMpa).toString();
    consumptionText = (await Settings.consumptionLpm).toString();
    warnText = (await Settings.warnMin).toString();
    alarmText = (await Settings.alarmMin).toString();
    ttsEnabled = await Settings.ttsEnabled;
    alarmSoundEnabled = await Settings.alarmSoundEnabled;
    keepScreenOn = await Settings.keepScreenOn;
    keepAliveEnabled = await Settings.keepAliveEnabled;
    asrCloudEnabled = await Settings.asrCloudEnabled;
    parseCloudEnabled = await Settings.parseCloudEnabled;
    await loadIdentity(expectedEpoch: _identity.protectedDataEpoch, notify: false);
    await refreshModelStatus(notify: false);
    if (_disposed) return;
    loaded = true;
    _notify();
    unawaited(refreshAlarmCapabilities());
    unawaited(loadRuntimeVersion());
  }

  Future<void> loadIdentity({required int expectedEpoch, bool notify = true}) async {
    if (_identity.protectedDataRevoked || _identity.needsAuthentication) return;
    final name = await Settings.realName;
    final unit = await Settings.unitName;
    final role = await Settings.userRole;
    final auth = (await Settings.unitId).isNotEmpty && unit.isNotEmpty && (await Settings.unitCode).isNotEmpty;
    if (_disposed || _identity.protectedDataRevoked || expectedEpoch != _identity.protectedDataEpoch) return;
    _identity = _identity.copyWith(
      realName: name.isNotEmpty ? name : _identity.realName,
      unitName: unit.isNotEmpty ? unit : _identity.unitName,
      userRole: role,
      authenticated: auth || _identity.authenticated,
    );
    if (notify) _notify();
  }

  Future<void> loadRuntimeVersion() async {
    try {
      final v = _gateway.readRuntimeVersion != null
          ? await _gateway.readRuntimeVersion!()
          : await PackageInfo.fromPlatform().then((i) => i.version.isEmpty ? '' : '${i.version}+${i.buildNumber}');
      if (!_disposed && v.isNotEmpty) { runtimeVersion = v; _notify(); }
    } catch (_) {}
  }

  Future<void> refreshAlarmCapabilities() async {
    final policy = await (_gateway.checkPolicyAccess?.call() ?? AlarmNative.isNotificationPolicyAccessGranted());
    if (_disposed) return;
    _alarmCaps = _alarmCaps.copyWith(policyAccessGranted: policy);
    _notify();
  }

  void updateDraftInputs({
    String? serverUrl, String? fullPressureText, String? consumptionText,
    String? warnText, String? alarmText, bool notify = false,
  }) {
    if (serverUrl != null) this.serverUrl = serverUrl;
    if (fullPressureText != null) this.fullPressureText = fullPressureText;
    if (consumptionText != null) this.consumptionText = consumptionText;
    if (warnText != null) this.warnText = warnText;
    if (alarmText != null) this.alarmText = alarmText;
    if (notify) _notify();
  }

  Future<bool> autoSave() async {
    _gateway.onTtsEnabledChanged?.call(ttsEnabled);
    if (_saving) { _saveQueued = true; return false; }
    _saving = true;
    _setSaveState(SettingsSaveState.saving);
    var ok = false;
    try {
      final fullPressure = double.tryParse(fullPressureText.trim());
      final consumption = double.tryParse(consumptionText.trim());
      final warn = int.tryParse(warnText.trim());
      final alarm = int.tryParse(alarmText.trim());
      if (fullPressure == null || consumption == null) throw ArgumentError('满压和消耗率必须填写有效数字');
      if (warn == null || alarm == null) throw ArgumentError('提醒和报警阈值必须填写整数');
      Settings.validateCalculationParameters(
        cylinderVolL: cylinderVolL, fullPressureMpa: fullPressure, consumptionLpm: consumption,
      );
      if (warn < 0 || alarm < 0 || warn > Settings.maxThresholdMin ||
          alarm > Settings.maxThresholdMin || warn < alarm) {
        throw ArgumentError('提醒阈值必须满足 0 ≤ 报警阈值 ≤ 提醒阈值 ≤ 1440');
      }
      await Settings.setServerUrl(serverUrl.trim());
      await Settings.setCylinderVolL(cylinderVolL);
      await Settings.setFullPressureMpa(fullPressure);
      await Settings.setConsumptionLpm(consumption);
      await Settings.setThresholds(warn, alarm);
      await Settings.setTtsEnabled(ttsEnabled);
      await Settings.setAlarmSoundEnabled(alarmSoundEnabled);
      await Settings.setKeepScreenOn(keepScreenOn);
      await Settings.setAsrCloudEnabled(asrCloudEnabled);
      await Settings.setParseCloudEnabled(parseCloudEnabled);
      await Settings.setRealName(_identity.realName);
      try { await ScreenOn.setKeepScreenOn(keepScreenOn); } catch (_) {}
      await Settings.markModified(_nowMs);
      await _gateway.onRefreshConfig?.call();
      _gateway.onStartSync?.call();
      _gateway.onSyncSettings?.call();
      ok = true;
      _setSaveState(SettingsSaveState.saved);
    } catch (_) {
      _setSaveState(SettingsSaveState.failed);
    } finally {
      _saving = false;
      if (_saveQueued && !_disposed) { _saveQueued = false; unawaited(autoSave()); }
    }
    return ok;
  }

  void _setSaveState(SettingsSaveState state) { if (!_disposed) { saveState = state; _notify(); } }
  Future<void> _commit(VoidCallback mutate) async { mutate(); _notify(); await autoSave(); }
  Future<void> setCylinderVolL(double v) => _commit(() => cylinderVolL = v);
  Future<void> setTtsEnabled(bool v) => _commit(() => ttsEnabled = v);
  Future<void> setAlarmSoundEnabled(bool v) => _commit(() => alarmSoundEnabled = v);
  Future<void> setKeepScreenOn(bool v) => _commit(() => keepScreenOn = v);
  Future<void> setParseCloudEnabled(bool v) => _commit(() => parseCloudEnabled = v);
  Future<void> setAsrCloudEnabled(bool v) => _commit(() => asrCloudEnabled = v);

  /// 后台值守开关：本地设备级偏好，不写 `Settings.modifiedAt`。
  Future<void> toggleKeepAlive(bool value) async {
    keepAliveEnabled = value;
    _notify();
    await Settings.setKeepAliveEnabled(value);
    if (value) {
      await (_gateway.requestNotificationPermission?.call() ?? ForegroundKeepAlive.requestNotificationPermission());
      await (_gateway.requestIgnoreBatteryOptimization?.call() ?? ForegroundKeepAlive.requestIgnoreBatteryOptimization());
      if (!_alarmCaps.exactAlarmAvailable) await openAlarmsSettings();
    }
    await _gateway.onRefreshConfig?.call();
    await _gateway.onSyncKeepAlive?.call();
  }

  /// 切换外观配色：仅本机生效，严禁触发自动保存或写入 `Settings.modifiedAt`。
  void selectTheme(String id) {
    if (_disposed) return;
    themeId = id;
    if (_gateway.onSelectThemeId != null) { _gateway.onSelectThemeId!(id); } else { unawaited(Settings.setAppThemeId(id)); }
    _notify();
  }

  Future<void> refreshConnection() async => _gateway.onRefreshNow?.call();
  Future<void> leaveUnit() async {
    await _gateway.onLeaveUnit?.call();
    if (_disposed) return;
    _identity = _identity.copyWith(authenticated: false, unitName: '', realName: '', canScanAdmin: false);
    _notify();
  }

  Future<bool> prepareAdminScan() async =>
      _gateway.onRefreshAndCheckAdminScan != null ? await _gateway.onRefreshAndCheckAdminScan!() : _identity.canScanAdmin;
  Future<void> openAlarmsSettings() => _gateway.openAlarmsSettings?.call() ?? ForegroundKeepAlive.openAlarmsAndRemindersSettings();
  Future<void> openPolicySettings() => _gateway.openPolicySettings?.call() ?? AlarmNative.openNotificationPolicySettings();
  Future<void> openNotificationSettings() => _gateway.openNotificationSettings?.call() ?? AlarmNative.openNotificationSettings();
  Future<void> openStorageSettings() => _gateway.openStorageSettings?.call() ?? StorageService.openStorageSettings();
  Future<bool> canRequestPackageInstalls() => _gateway.canRequestPackageInstalls?.call() ?? UpdateService.canRequestPackageInstalls();
  Future<void> openUnknownAppSourcesSettings() => _gateway.openUnknownAppSourcesSettings?.call() ?? UpdateService.openUnknownAppSourcesSettings();

  Future<bool> ensureModelInstalledStatus() async {
    if (modelInstalled != null) return modelInstalled!;
    await refreshModelStatus();
    return modelInstalled == true;
  }

  Future<void> refreshModelStatus({bool notify = true}) async {
    if (_gateway.localAsr == null) return;
    final installed = await _gateway.localAsr!.isModelInstalled();
    if (_disposed) return;
    modelInstalled = installed;
    if (notify) _notify();
  }

  Future<({bool ok, int? insufficientStorageBytes})> downloadModel() async {
    final asr = _gateway.localAsr;
    if (asr == null) return (ok: false, insufficientStorageBytes: null);
    final available = await (_gateway.availableStorageBytes?.call() ?? StorageService.availableBytes());
    if (available != null && available < LocalAsrService.minimumRecommendedFreeBytes) {
      return (ok: false, insufficientStorageBytes: available);
    }
    downloadingModel = true; downloadError = null; downloadProgress = null;
    _notify();
    int? insufficientBytes;
    try {
      await asr.downloadModel(onProgress: (r, t) {
        if (!_disposed && t > 0) { downloadProgress = r / t; _notify(); }
      });
    } on InsufficientStorageException catch (e) {
      insufficientBytes = e.availableBytes;
      if (!_disposed) downloadError = e.userMessage;
    } catch (e) {
      if (!_disposed) downloadError = '$e';
    } finally {
      await refreshModelStatus(notify: false);
      if (!_disposed) { downloadingModel = false; downloadProgress = null; _notify(); }
    }
    return (ok: modelInstalled == true && insufficientBytes == null, insufficientStorageBytes: insufficientBytes);
  }

  Future<void> removeModel() async {
    if (_gateway.localAsr == null) return;
    await _gateway.localAsr!.removeModel();
    await refreshModelStatus();
  }

  Future<({UpdateInfo? info, String? error, bool blockedByDebugMode})> checkForUpdate() async {
    if (checkingUpdate) return (info: null, error: null, blockedByDebugMode: false);
    if (_gateway.isDebugMode) return (info: null, error: null, blockedByDebugMode: true);
    checkingUpdate = true;
    _notify();
    UpdateInfo? info;
    String? error;
    final opId = 'release-check-$_nowMs';
    void trace(String s, String m, String l) =>
        OpLogService.instance.record(opId, s, m, level: l, data: const {'source': 'ALI OTA'});
    try {
      (info, error) = await (_gateway.updateServiceFactory?.call(trace) ?? UpdateService(logger: trace)).checkForUpdate();
    } catch (e) { error = '$e'; }
    if (_disposed) return (info: info, error: error, blockedByDebugMode: false);
    checkingUpdate = false;
    _update = SettingsUpdateSnapshot(pendingUpdate: info, checkDone: true, checkError: error);
    _gateway.onRecordUpdateCheck?.call(info, error);
    _notify();
    return (info: info, error: error, blockedByDebugMode: false);
  }

  Future<({String? error, bool installPrompted})> downloadAndInstallUpdate(
    UpdateInfo info, {
    required ValueChanged<int> onProgress,
    required VoidCallback onInstalling,
  }) async {
    final opId = 'ota-$_nowMs';
    void trace(String s, String m, {String level = 'info'}) =>
        OpLogService.instance.record(opId, s, m, level: level, data: {'version': info.tagName});
    String? fail;
    var installPrompted = false;
    final svc = _gateway.updateServiceFactory?.call((s, m, l) => trace(s, m, level: l)) ??
        UpdateService(logger: (s, m, l) => trace(s, m, level: l));
    await svc.downloadAndInstall(
      info,
      onProgress: onProgress,
      onInstalling: () { installPrompted = true; onInstalling(); },
      onError: (m) => fail = m,
    );
    if (fail == null) trace('ota_done', installPrompted ? '安装流程已交系统处理' : '下载完成（未进入安装阶段）');
    return (error: fail, installPrompted: installPrompted);
  }

  void _notify() { if (!_disposed) notifyListeners(); }

  @override
  void dispose() {
    _disposed = true;
    _themeListenable?.removeListener(_handleExternalThemeChange);
    super.dispose();
  }
}
