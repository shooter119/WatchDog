import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/alarm_service.dart';
import '../services/foreground_keep_alive.dart';
import '../services/op_log_service.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/update_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'about_page.dart';
import 'op_log_page.dart';
import 'roster_page.dart';
import 'stats_page.dart';

/// 当前版本号（fallback：运行时由 package_info_plus 读取 pubspec version 覆盖，测试环境用此常量）
const appVersion = '0.11.10+36';

class SettingsPage extends StatefulWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _server = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _volume = TextEditingController();
  final TextEditingController _full = TextEditingController();
  final TextEditingController _consumption = TextEditingController();
  final TextEditingController _warn = TextEditingController();
  final TextEditingController _alarm = TextEditingController();
  final TextEditingController _realName = TextEditingController();
  final FocusNode _serverFocus = FocusNode();
  final FocusNode _tokenFocus = FocusNode();
  final FocusNode _volumeFocus = FocusNode();
  final FocusNode _fullFocus = FocusNode();
  final FocusNode _consumptionFocus = FocusNode();
  final FocusNode _warnFocus = FocusNode();
  final FocusNode _alarmFocus = FocusNode();
  final FocusNode _realNameFocus = FocusNode();
  bool _tokenVisible = false;
  bool _tts = true;
  bool _sound = true;
  bool _keepScreenOn = true;
  bool _keepAlive = false;
  bool _asrCloud = false; // 默认离线优先（火场无信号场景）；本地模型需先下载
  bool _parseCloud = true;
  bool? _modelInstalled;
  bool _downloading = false;
  double? _downloadProgress;
  String? _downloadError;
  bool _policyAccess = true; // 勿扰策略访问是否授权（bypassDnd 生效前提）
  bool _fullScreenOk = true; // Android 14+ 全屏通知是否开启
  String _runtimeVersion = ''; // 运行时版本号（package_info_plus），空则用常量
  bool _checkingUpdate = false; // 检查更新进行中
  bool _loaded = false;
  bool _saving = false; // 防止失焦时 8 个输入框监听器并发触发多次保存
  _SaveState _saveState = _SaveState.idle; // 自动保存状态提示

  @override
  void initState() {
    super.initState();
    // 任一输入框失焦且全部输入框均无焦点（点空白处/收起键盘）→ 自动保存
    for (final n in [
      _serverFocus, _tokenFocus, _volumeFocus,
      _fullFocus, _consumptionFocus, _warnFocus, _alarmFocus, _realNameFocus,
    ]) {
      n.addListener(() {
        if (_loaded && !n.hasFocus && _allInputsUnfocused()) _autoSave();
      });
    }
    // 启动自动检查完成后刷新「检查更新」卡片提示（有新版/已最新）
    widget.controller.addListener(_onControllerChanged);
    _load();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  bool _allInputsUnfocused() {
    return [
      _serverFocus, _tokenFocus, _volumeFocus,
      _fullFocus, _consumptionFocus, _warnFocus, _alarmFocus, _realNameFocus,
    ].every((n) => !n.hasFocus);
  }

  Future<void> _load() async {
    _server.text = await Settings.serverUrl;
    _token.text = await Settings.apiToken;
    _volume.text = (await Settings.cylinderVolL).toString();
    _full.text = (await Settings.fullPressureMpa).toString();
    _consumption.text = (await Settings.consumptionLpm).toString();
    _warn.text = (await Settings.warnMin).toString();
    _alarm.text = (await Settings.alarmMin).toString();
    _tts = await Settings.ttsEnabled;
    _sound = await Settings.alarmSoundEnabled;
    _keepScreenOn = await Settings.keepScreenOn;
    _keepAlive = await Settings.keepAliveEnabled;
    _asrCloud = await Settings.asrCloudEnabled;
    _parseCloud = await Settings.parseCloudEnabled;
    _realName.text = await Settings.realName;
    _loaded = true;
    _refreshModelStatus();
    _refreshAlarmCaps();
    _loadRuntimeVersion();
    if (mounted) setState(() {});
  }

  /// 运行时版本号：优先 package_info_plus（真实安装包），失败保留常量兜底
  Future<void> _loadRuntimeVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted && info.version.isNotEmpty) {
        setState(() => _runtimeVersion = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      // 测试/异常环境用常量兜底
    }
  }

  /// 检查更新：GitHub Releases 最新版 → 提示/下载/安装
  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    String? error;
    UpdateInfo? info;
    try {
      (info, error) = await UpdateService().checkForUpdate();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    // 手动检查结果同步到共享状态，卡片提示保持一致
    widget.controller.recordUpdateCheck(info, error);
    if (error != null) {
      _showUpdateResult('检查更新失败', error);
      return;
    }
    if (info == null) {
      _showUpdateResult('已是最新版本', '当前版本 $_displayVersion 已是最新');
      return;
    }
    _showUpdateDialog(info);
  }

  String get _displayVersion => _runtimeVersion.isEmpty ? appVersion : _runtimeVersion;

  void _showUpdateResult(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好的')),
        ],
      ),
    );
  }

  void _showUpdateDialog(UpdateInfo info) {
    final sizeText = info.sizeBytes == null
        ? ''
        : '${(info.sizeBytes! / 1048576).toStringAsFixed(1)} MB';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 ${info.tagName}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sizeText.isNotEmpty)
                Text('安装包大小：$sizeText', style: const TextStyle(fontSize: 13, color: AppColors.textTertiary)),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    info.changelog ?? '点击立即更新下载安装',
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startDownload(info);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  /// 下载安装：进度对话框 → 安装阶段自动关闭进度框并提示用户在系统界面完成安装
  Future<void> _startDownload(UpdateInfo info) async {
    if (!mounted) return;
    // OTA 全链路操作日志埋点（服务器可查，定位设备版本与安装失败原因）
    final opId = 'ota-${DateTime.now().millisecondsSinceEpoch}';
    void trace(String stage, String msg, {String level = 'info'}) {
      OpLogService.instance.record(opId, stage, msg, level: level, data: {'version': info.tagName});
    }

    // 安装前置：Android 8+ 需"安装未知来源应用"授权，未授权先引导（否则下载完也弹不出安装界面）
    final canInstall = await UpdateService.canRequestPackageInstalls();
    trace('ota_permission_check', canInstall ? '安装权限已授权' : '未授权安装未知来源应用',
        level: canInstall ? 'info' : 'warn');
    if (!mounted) return;
    if (!canInstall) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要开启安装权限', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          content: const Text(
            '系统要求先允许本应用"安装未知来源应用"，否则下载完成后无法弹出安装界面。\n\n是否前往系统设置开启？',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (go == true) await UpdateService.openUnknownAppSourcesSettings();
      return; // 授权后需重新点击"立即更新"
    }
    final progress = ValueNotifier<int>(0);
    var installPrompted = false; // 已提示「安装中」（避免完成后重复弹框）
    var downloadStarted = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在下载更新', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (ctx, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v / 100),
              const SizedBox(height: 10),
              Text('$v%', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              const Text('下载中请保持应用在前台', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
            ],
          ),
        ),
      ),
    );
    String? fail;
    await UpdateService().downloadAndInstall(
      info,
      onProgress: (p) {
        if (!downloadStarted) {
          downloadStarted = true;
          trace('ota_download_start', '开始下载更新包');
        }
        progress.value = p;
      },
      onInstalling: () {
        installPrompted = true;
        trace('ota_installing', '下载完成，进入系统安装阶段');
        // 关闭进度对话框，提示用户去系统安装界面操作
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        if (mounted) _showUpdateResult('安装中', '安装包已就绪，请在弹出的系统界面完成安装');
      },
      onError: (m) => fail = m,
    );
    if (!mounted) return;
    if (fail != null) {
      trace('ota_fail', fail!, level: 'error');
      // 安装类失败（未授权/系统拦截）：提供一键跳转授权页，避免用户无从下手
      if (fail!.contains('安装未完成') || fail!.contains('未知来源')) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('安装未完成', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            content: Text(fail!, style: const TextStyle(fontSize: 14, height: 1.5)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('知道了')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('去设置开启'),
              ),
            ],
          ),
        );
        if (go == true) await UpdateService.openUnknownAppSourcesSettings();
      } else {
        _showUpdateResult('更新失败', fail!);
      }
    } else if (!installPrompted) {
      trace('ota_done', '下载完成（未进入安装阶段）');
      _showUpdateResult('下载完成', '请在弹出的系统界面完成安装');
    } else {
      trace('ota_done', '安装流程已交系统处理');
    }
  }

  /// 检测勿扰策略授权 / Android 14+ 全屏通知状态（不影响主流程，失败静默）
  Future<void> _refreshAlarmCaps() async {
    final policy = await AlarmNative.isNotificationPolicyAccessGranted();
    final fullScreen = widget.controller.alarm.fullScreenIntentEnabled;
    if (mounted) {
      setState(() {
        _policyAccess = policy;
        _fullScreenOk = fullScreen;
      });
    }
  }

  Future<void> _refreshModelStatus() async {
    final asr = widget.controller.localAsr;
    if (asr == null) return;
    final installed = await asr.isModelInstalled();
    if (mounted) setState(() => _modelInstalled = installed);
  }

  Future<void> _downloadModel() async {
    final asr = widget.controller.localAsr;
    if (asr == null) return;
    setState(() {
      _downloading = true;
      _downloadError = null;
      _downloadProgress = null;
    });
    try {
      await asr.downloadModel(onProgress: (received, total) {
        if (mounted && total > 0) {
          setState(() => _downloadProgress = received / total);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _downloadError = '$e');
    } finally {
      await _refreshModelStatus();
      if (mounted) {
        setState(() {
          _downloading = false;
          _downloadProgress = null;
        });
      }
    }
  }

  /// 自动保存：文本框失焦（点空白/收起键盘/焦点转移）或开关切换时立即保存本地并触发云端同步（静默）。
  /// 保存期间显示"保存中"，完成后显示"已保存"，异常显示"保存失败"。
  Future<void> _autoSave() async {
    if (_saving) return; // 已有保存在进行中（失焦会触发 8 个监听器，只保存一次）
    _saving = true;
    if (mounted) setState(() => _saveState = _SaveState.saving);
    try {
      await Settings.setServerUrl(_server.text.trim());
      await Settings.setApiToken(_token.text.trim());
      await Settings.setCylinderVolL(double.tryParse(_volume.text) ?? 6.8);
      await Settings.setFullPressureMpa(double.tryParse(_full.text) ?? 30);
      await Settings.setConsumptionLpm(double.tryParse(_consumption.text) ?? 80);
      await Settings.setThresholds(
        int.tryParse(_warn.text) ?? 10,
        int.tryParse(_alarm.text) ?? 5,
      );
      await Settings.setTtsEnabled(_tts);
      await Settings.setAlarmSoundEnabled(_sound);
      await Settings.setKeepScreenOn(_keepScreenOn);
      await Settings.setAsrCloudEnabled(_asrCloud);
      await Settings.setParseCloudEnabled(_parseCloud);
      await Settings.setRealName(_realName.text);
      try {
        await ScreenOn.setKeepScreenOn(_keepScreenOn);
      } catch (_) {
        // 平台通道失败（如无宿主环境）不阻断保存
      }
      await Settings.markModified(DateTime.now().millisecondsSinceEpoch);
      await widget.controller.refreshConfig();
      widget.controller.startSync();
      widget.controller.syncSettings();
      if (mounted) setState(() => _saveState = _SaveState.saved);
    } catch (e) {
      if (mounted) setState(() => _saveState = _SaveState.failed);
    } finally {
      _saving = false;
    }
  }

  /// 后台值守开关：开启时先引导权限（通知 → 电池白名单），再拉起前台服务；关闭即停止
  Future<void> _toggleKeepAlive(bool v) async {
    setState(() => _keepAlive = v);
    await Settings.setKeepAliveEnabled(v);
    if (v) {
      await ForegroundKeepAlive.requestNotificationPermission();
      await ForegroundKeepAlive.requestIgnoreBatteryOptimization();
      if (widget.controller.alarm.exactAlarmAvailable == false) {
        await ForegroundKeepAlive.openAlarmsAndRemindersSettings();
      }
    }
    await widget.controller.refreshConfig();
    await widget.controller.syncKeepAlive();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _server.dispose();
    _token.dispose();
    _volume.dispose();
    _full.dispose();
    _consumption.dispose();
    _warn.dispose();
    _alarm.dispose();
    _realName.dispose();
    _serverFocus.dispose();
    _tokenFocus.dispose();
    _volumeFocus.dispose();
    _fullFocus.dispose();
    _consumptionFocus.dispose();
    _warnFocus.dispose();
    _alarmFocus.dispose();
    _realNameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
          // 与日志/统计页一致，为悬浮语音按钮保留末尾安全距离。
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
          children: [
          Row(
            children: [
              const Text('设置', style: AppTextStyles.h1),
              const SizedBox(width: 10),
              _SaveStatusBadge(state: _saveState),
              const Spacer(),
              ConnectionStatus(
                connected: !widget.controller.connectionLost,
                onRetry: () => widget.controller.startSync(),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _CollapsibleSection(
            title: '服务端',
            child: AppCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _field(_server, '服务器地址', '默认 https://bytevirt.meiyou.xyz:8443', icon: Icons.dns_outlined, keyboard: TextInputType.url, focusNode: _serverFocus),
                  _field(
                    _token,
                    '访问令牌',
                    '与服务器 API_TOKEN 一致',
                    icon: Icons.key_outlined,
                    obscure: !_tokenVisible,
                    focusNode: _tokenFocus,
                    suffix: IconButton(
                      icon: Icon(_tokenVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _CollapsibleSection(
            title: '计算参数',
            initiallyExpanded: true,
            child: AppCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _GroupLabel('气瓶参数'),
                  Row(
                    children: [
                      Expanded(child: _field(_volume, '气瓶容量', '6.8 L', icon: Icons.local_fire_department_outlined, focusNode: _volumeFocus)),
                      const SizedBox(width: 10),
                      Expanded(child: _field(_full, '满压', '30 MPa', icon: Icons.speed, focusNode: _fullFocus)),
                    ],
                  ),
                  _field(_consumption, '消耗率', '80 L/min', icon: Icons.water_drop_outlined, focusNode: _consumptionFocus),
                  const _GroupLabel('提醒阈值'),
                  Row(
                    children: [
                      Expanded(child: _field(_warn, '提醒剩余', '10 min', icon: Icons.notifications_active_outlined, focusNode: _warnFocus)),
                      const SizedBox(width: 10),
                      Expanded(child: _field(_alarm, '报警剩余', '5 min', icon: Icons.warning_amber_rounded, focusNode: _alarmFocus)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _CollapsibleSection(
            title: '语音识别',
            initiallyExpanded: true,
            child: AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('联网语音识别', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('开：豆包云端识别，失败自动切本地；关：强制本地识别'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _asrCloud,
                    onChanged: (v) {
                      setState(() => _asrCloud = v);
                      _autoSave();
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: const Text('联网语义解析', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('开：DeepSeek 云端解析，失败自动切本地；关：强制本地规则解析'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _parseCloud,
                    onChanged: (v) {
                      setState(() => _parseCloud = v);
                      _autoSave();
                    },
                  ),
                  if (widget.controller.localAsr != null) ...[
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _buildModelTile(),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _CollapsibleSection(
            title: '提醒方式',
            initiallyExpanded: true,
            child: AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('语音播报', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('确认/提醒/报警时播报中文语音'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _tts,
                    onChanged: (v) {
                      setState(() => _tts = v);
                      _autoSave();
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: const Text('报警音', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('前台警报音 + 后台本地通知'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _sound,
                    onChanged: (v) {
                      setState(() => _sound = v);
                      _autoSave();
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: const Text('屏幕常亮', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('看板页保持屏幕常亮，适合火场值守'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _keepScreenOn,
                    onChanged: (v) {
                      setState(() => _keepScreenOn = v);
                      _autoSave();
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: const Text('后台值守模式', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('前台服务常驻：切后台/锁屏后轮询与报警不停，通知栏显示指挥状态'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _keepAlive,
                    onChanged: _toggleKeepAlive,
                  ),
                  if (!_keepAlive)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        '开启时请允许通知与电池白名单，否则保活可能被系统中断',
                        style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ),
                  if (!widget.controller.alarm.exactAlarmAvailable) ...[
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.notifications_off_outlined, color: AppColors.caution, size: 20),
                      title: const Text(
                        '系统已关闭精确闹钟权限，后台提醒可能延迟',
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text('请在系统设置-应用-火场智控中允许闹钟与提醒', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  if (!_policyAccess) ...[
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      dense: true,
                      onTap: AlarmNative.openNotificationPolicySettings,
                      leading: const Icon(Icons.do_not_disturb_on_outlined, color: AppColors.caution, size: 20),
                      title: const Text(
                        '未允许勿扰访问，勿扰模式下报警提醒将被静音',
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text('点击前往系统设置开启勿扰访问', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  if (!_fullScreenOk) ...[
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      dense: true,
                      onTap: AlarmNative.openNotificationSettings,
                      leading: const Icon(Icons.fullscreen_exit_outlined, color: AppColors.caution, size: 20),
                      title: const Text(
                        '未开启全屏通知，后台报警不会弹全屏提醒',
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text('点击前往通知设置开启全屏显示', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle(text: '实名认证'),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _field(
                  _realName,
                  '真实姓名',
                  '填写后日志显示你的姓名，留空为匿名',
                  icon: Icons.badge_outlined,
                  focusNode: _realNameFocus,
                ),
                const Text(
                  '实名后，你在火场日志发布的记录会以小字标注姓名；未填写则显示"匿名"。',
                  style: TextStyle(fontSize: 12, color: AppColors.textTertiary, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle(text: '名单与热词'),
          AppCard(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => RosterPage(controller: widget.controller)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surfaceSubtle,
                  ),
                  child: const Icon(Icons.group_outlined, size: 20, color: AppColors.textPrimary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('消防员与专业术语', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      SizedBox(height: 2),
                      Text('提前录入，语音识别更准', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle(text: '数据统计'),
          AppCard(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => StatsPage(controller: widget.controller)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surfaceSubtle,
                  ),
                  child: const Icon(Icons.bar_chart_outlined, size: 20, color: AppColors.textPrimary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('出场耗时与压力统计', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      SizedBox(height: 2),
                      Text('查看火场作业数据', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle(text: '操作日志'),
          AppCard(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => OpLogPage(controller: widget.controller)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surfaceSubtle,
                  ),
                  child: const Icon(Icons.receipt_long_outlined, size: 20, color: AppColors.textPrimary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('语音录入全流程记录', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      SizedBox(height: 2),
                      Text('可同步到服务器排查问题', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle(text: '关于'),
          AppCard(
            onTap: _checkingUpdate ? null : _checkUpdate,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.surfaceSubtle,
                        ),
                        child: _checkingUpdate
                            ? const Padding(
                                padding: EdgeInsets.all(10),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.system_update_alt_rounded, size: 20, color: AppColors.textPrimary),
                      ),
                      // 启动自动检查发现新版本：图标右上角红点提示
                      if (!_checkingUpdate && widget.controller.pendingUpdate != null)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.alarm,
                              border: Border.all(color: AppColors.surface, width: 1.5),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('检查更新', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      const SizedBox(height: 2),
                      Builder(builder: (_) {
                        final pending = widget.controller.pendingUpdate;
                        final String subtitle;
                        final Color color;
                        if (pending != null) {
                          subtitle = '发现新版本 ${pending.tagName}，点击更新';
                          color = AppColors.caution;
                        } else if (widget.controller.updateCheckError != null) {
                          subtitle = '检查更新失败，点击重试';
                          color = AppColors.alarm;
                        } else if (widget.controller.updateCheckDone) {
                          subtitle = '已是最新版本';
                          color = AppColors.textTertiary;
                        } else {
                          subtitle = '从 GitHub Releases 获取最新版本';
                          color = AppColors.textTertiary;
                        }
                        return Text(subtitle, style: TextStyle(fontSize: 12, color: color));
                      }),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppCard(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutPage()),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surfaceSubtle,
                  ),
                  child: const Icon(Icons.info_outline, size: 20, color: AppColors.textPrimary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('关于我们', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      SizedBox(height: 2),
                      Text('项目介绍与使用说明', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Column(
            children: [
              Text(
                '火场智控 v$_displayVersion',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                '一线消防员开发 · 开源项目',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label,
    String hint, {
    FocusNode? focusNode,
    IconData? icon,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        focusNode: focusNode,
        keyboardType: keyboard,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon != null ? Icon(icon) : null,
          suffixIcon: suffix,
        ),
      ),
    );
  }

  /// 本地语音模型：状态 + 下载/删除
  Widget _buildModelTile() {
    final installed = _modelInstalled;
    if (_downloading) {
      final pct = _downloadProgress == null ? null : (_downloadProgress! * 100).round();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pct == null ? '正在下载本地语音模型…' : '正在下载本地语音模型… $pct%',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _downloadProgress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
          ],
        ),
      );
    }
    if (installed == null) {
      return const ListTile(
        dense: true,
        leading: Icon(Icons.cloud_download_outlined, color: AppColors.textTertiary, size: 20),
        title: Text('检查本地语音模型…', style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
      );
    }
    if (installed) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.check_circle_outline, color: AppColors.safe, size: 20),
        title: const Text('本地语音模型已就绪（离线可用）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        trailing: TextButton(
          onPressed: () async {
            await widget.controller.localAsr!.removeModel();
            _refreshModelStatus();
          },
          child: const Text('删除'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.offline_bolt_outlined, color: AppColors.caution, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '本地语音模型未下载（约 75MB）\n下载后断网也能语音录入',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
                ),
              ),
            ],
          ),
          if (_downloadError != null) ...[
            const SizedBox(height: 8),
            Text(
              _downloadError!,
              style: const TextStyle(fontSize: 12, color: AppColors.alarm, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            child: FilledButton.tonalIcon(
              onPressed: _downloadModel,
              icon: const Icon(Icons.download_outlined, size: 20),
              label: const Text('下载本地模型'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 自动保存状态
enum _SaveState { idle, saving, saved, failed }

/// 保存状态轻量提示：保存中 / 已保存 / 保存失败（失焦自动保存的即时反馈）
class _SaveStatusBadge extends StatelessWidget {
  final _SaveState state;

  const _SaveStatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      _SaveState.idle => const SizedBox.shrink(),
      _SaveState.saving => const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 5),
            Text('保存中', style: TextStyle(fontSize: 11, color: AppColors.textTertiary, fontWeight: FontWeight.w600)),
          ],
        ),
      _SaveState.saved => const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 14, color: AppColors.safe),
            SizedBox(width: 5),
            Text('已保存', style: TextStyle(fontSize: 11, color: AppColors.safe, fontWeight: FontWeight.w600)),
          ],
        ),
      _SaveState.failed => const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 14, color: AppColors.alarm),
            SizedBox(width: 5),
            Text('保存失败', style: TextStyle(fontSize: 11, color: AppColors.alarm, fontWeight: FontWeight.w600)),
          ],
        ),
    };
  }
}

/// 卡片内子分组小标题（如"气瓶参数"、"提醒阈值"）
class _GroupLabel extends StatelessWidget {
  final String text;

  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 可折叠分区：点击标题展开/收起，标题文字后带方向箭头符号
class _CollapsibleSection extends StatefulWidget {
  final String title;
  final bool initiallyExpanded;
  final Widget child;

  const _CollapsibleSection({
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: SectionTitle(
            text: widget.title,
            inline: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: AppColors.textTertiary,
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: _expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          firstChild: widget.child,
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
