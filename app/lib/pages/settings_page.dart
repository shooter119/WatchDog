import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/models.dart';
import '../services/alarm_service.dart';
import '../services/foreground_keep_alive.dart';
import '../services/local_asr_service.dart';
import '../services/op_log_service.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/storage_service.dart';
import '../services/update_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import '../theme/fire_control_logo.dart';
import 'about_page.dart';
import 'archived_incidents_page.dart';
import 'op_log_page.dart';
import 'roster_page.dart';
import 'stats_page.dart';

/// 当前版本号（fallback：运行时由 package_info_plus 读取 pubspec version 覆盖，测试环境用此常量）
const appVersion = '1.2.3+59';

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
  bool _asrCloud = true; // 默认云端优先，精度高
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
  bool _saveQueued = false;
  _SaveState _saveState = _SaveState.idle; // 自动保存状态提示
  bool _editingName = false;
  String _unitName = '';
  bool _unitAuthenticated = false;

  @override
  void initState() {
    super.initState();
    // 任一输入框失焦且全部输入框均无焦点（点空白处/收起键盘）→ 自动保存
    for (final n in [
      _serverFocus,
      _tokenFocus,
      _volumeFocus,
      _fullFocus,
      _consumptionFocus,
      _warnFocus,
      _alarmFocus,
      _realNameFocus,
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
    if (!mounted) return;
    setState(() {});
    if (!widget.controller.needsAuthentication) unawaited(_loadIdentity());
  }

  Future<void> _loadIdentity() async {
    final name = await Settings.realName;
    final unit = await Settings.unitName;
    final authenticated =
        (await Settings.unitId).isNotEmpty &&
        (await Settings.unitName).isNotEmpty &&
        (await Settings.unitCode).isNotEmpty;
    if (!mounted) return;
    setState(() {
      _realName.text = name;
      _unitName = unit;
      _unitAuthenticated = authenticated;
    });
  }

  bool _allInputsUnfocused() {
    return [
      _serverFocus,
      _tokenFocus,
      _volumeFocus,
      _fullFocus,
      _consumptionFocus,
      _warnFocus,
      _alarmFocus,
      _realNameFocus,
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
    _unitName = await Settings.unitName;
    _unitAuthenticated =
        (await Settings.unitId).isNotEmpty &&
        (await Settings.unitName).isNotEmpty &&
        (await Settings.unitCode).isNotEmpty;
    await _refreshModelStatus();
    _loaded = true;
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

  /// 检查更新：国内 OTA 清单最新版 → 提示/下载/安装
  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    String? error;
    UpdateInfo? info;
    final opId = 'ota-check-${DateTime.now().millisecondsSinceEpoch}';
    void trace(String stage, String message, String level) {
      OpLogService.instance.record(
        opId,
        stage,
        message,
        level: level,
        data: {'source': '国内更新服务'},
      );
    }

    try {
      (info, error) = await UpdateService(
        logger: (stage, message, level) => trace(stage, message, level),
      ).checkForUpdate();
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

  String get _displayVersion =>
      _runtimeVersion.isEmpty ? appVersion : _runtimeVersion;

  void _showUpdateResult(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
          ),
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
        title: Text(
          '发现新版本 ${info.tagName}',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sizeText.isNotEmpty)
                Text(
                  '安装包大小：$sizeText',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textTertiary,
                  ),
                ),
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
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
      OpLogService.instance.record(
        opId,
        stage,
        msg,
        level: level,
        data: {'version': info.tagName},
      );
    }

    // 安装前置：Android 8+ 需"安装未知来源应用"授权，未授权先引导（否则下载完也弹不出安装界面）
    final canInstall = await UpdateService.canRequestPackageInstalls();
    trace(
      'ota_permission_check',
      canInstall ? '安装权限已授权' : '未授权安装未知来源应用',
      level: canInstall ? 'info' : 'warn',
    );
    if (!mounted) return;
    if (!canInstall) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(
            '需要开启安装权限',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          content: const Text(
            '系统要求先允许本应用"安装未知来源应用"，否则下载完成后无法弹出安装界面。\n\n是否前往系统设置开启？',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
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
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '正在下载更新',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (ctx, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v / 100),
              const SizedBox(height: 10),
              Text(
                '$v%',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '下载中请保持应用在前台',
                style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
    String? fail;
    await UpdateService(
      logger: (stage, message, level) => trace(stage, message, level: level),
    ).downloadAndInstall(
      info,
      onProgress: (p) {
        progress.value = p;
      },
      onInstalling: () {
        installPrompted = true;
        // 关闭进度对话框，提示用户去系统安装界面操作
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        if (mounted) _showUpdateResult('安装中', '安装包已就绪，请在弹出的系统界面完成安装');
      },
      onError: (m) => fail = m,
    );
    if (!mounted) return;
    if (fail != null) {
      // 安装类失败（未授权/系统拦截）：提供一键跳转授权页，避免用户无从下手
      if (fail!.contains('安装未完成') || fail!.contains('未知来源')) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text(
              '安装未完成',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            content: Text(
              fail!,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('知道了'),
              ),
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

  /// 关闭联网语音识别时：检查本地模型是否已安装，未安装则提示下载
  Future<bool> _checkModelBeforeOffline() async {
    final alreadyInstalled = _modelInstalled;
    if (alreadyInstalled == true) return true;
    // 尚未检查过：先查询
    final installed =
        alreadyInstalled ??
        await widget.controller.localAsr?.isModelInstalled() ??
        false;
    if (mounted) setState(() => _modelInstalled = installed);
    if (installed) return true;
    if (!mounted) return false;
    final download = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未下载本地语音模型'),
        content: const Text(
          '关闭联网识别后将使用本地模型，但本地 ASR 主模型尚未下载（约 75MB；另有可选的 9.8MB 降噪模型）。\n\n是否现在下载？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (download != true) return false;
    await _downloadModel();
    return _modelInstalled == true;
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
    final available = await StorageService.availableBytes();
    if (available != null &&
        available < LocalAsrService.minimumRecommendedFreeBytes) {
      await _showStorageRecovery(available);
      return;
    }
    setState(() {
      _downloading = true;
      _downloadError = null;
      _downloadProgress = null;
    });
    try {
      await asr.downloadModel(
        onProgress: (received, total) {
          if (mounted && total > 0) {
            setState(() => _downloadProgress = received / total);
          }
        },
      );
    } on InsufficientStorageException catch (e) {
      if (mounted) {
        setState(() => _downloadError = e.userMessage);
        await _showStorageRecovery(e.availableBytes);
      }
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

  Future<void> _showStorageRecovery(int availableBytes) async {
    if (!mounted) return;
    final availableMb = (availableBytes / (1024 * 1024)).floor();
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备存储空间不足'),
        content: Text(
          '当前可用空间约 ${availableMb}MB。为保护当前本地模型和现场数据，App 不会自动删除它们。\n\n'
          '清理空间后可重新下载；暂时也可以继续使用联网语音识别。',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续联网识别'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去系统存储设置'),
          ),
        ],
      ),
    );
    if (openSettings == true) await StorageService.openStorageSettings();
  }

  /// 自动保存：文本框失焦（点空白/收起键盘/焦点转移）或开关切换时立即保存本地并触发云端同步（静默）。
  /// 保存期间显示"保存中"，完成后显示"已保存"，异常显示"保存失败"。
  Future<void> _autoSave() async {
    // 开关变化立即作用于当前进程，不等待 SharedPreferences 和服务端同步完成。
    widget.controller.tts.enabled = _tts;
    if (_saving) {
      // 输入框在上一轮异步保存期间再次失焦时，不能静默丢掉第二次修改。
      _saveQueued = true;
      return;
    }
    _saving = true;
    if (mounted) setState(() => _saveState = _SaveState.saving);
    try {
      // 先整体解析和校验，再开始任何 SharedPreferences 写入，避免反向
      // 阈值或 0/负数参数导致“保存失败但部分设置已生效”。
      final volume = double.tryParse(_volume.text.trim());
      final fullPressure = double.tryParse(_full.text.trim());
      final consumption = double.tryParse(_consumption.text.trim());
      final warn = int.tryParse(_warn.text.trim());
      final alarm = int.tryParse(_alarm.text.trim());
      if (volume == null || fullPressure == null || consumption == null) {
        throw ArgumentError('气瓶容量、满压和消耗率必须填写有效数字');
      }
      if (warn == null || alarm == null) {
        throw ArgumentError('提醒和报警阈值必须填写整数');
      }
      Settings.validateCalculationParameters(
        cylinderVolL: volume,
        fullPressureMpa: fullPressure,
        consumptionLpm: consumption,
      );
      if (warn < 0 ||
          alarm < 0 ||
          warn > Settings.maxThresholdMin ||
          alarm > Settings.maxThresholdMin ||
          warn < alarm) {
        throw ArgumentError('提醒阈值必须满足 0 ≤ 报警阈值 ≤ 提醒阈值 ≤ 1440');
      }
      await Settings.setServerUrl(_server.text.trim());
      await Settings.setApiToken(_token.text.trim());
      await Settings.setCylinderVolL(volume);
      await Settings.setFullPressureMpa(fullPressure);
      await Settings.setConsumptionLpm(consumption);
      await Settings.setThresholds(warn, alarm);
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
      if (_saveQueued && mounted) {
        _saveQueued = false;
        unawaited(_autoSave());
      }
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
    final entries = widget.controller.entries;
    final activeEntries = entries.where((entry) => entry.isActive).length;
    final uniqueNames = entries
        .map((entry) => entry.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .length;
    final connected = !widget.controller.connectionLost;

    return SafeArea(
      child: ListView(
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
                syncing: widget.controller.syncing,
                syncError: widget.controller.syncError,
                onRetry: widget.controller.refreshNow,
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _SettingsEyebrow('现场处置 / 本机状态'),
          const SizedBox(height: 8),
          _SettingsHero(
            incident: widget.controller.currentIncident,
            connected: connected,
            syncError: widget.controller.syncError,
          ),
          const SizedBox(height: 22),
          const SectionTitle(text: '我的身份'),
          _buildIdentityCard(),
          const SizedBox(height: 22),
          const SectionTitle(text: '现场资料'),
          _buildFieldGrid(
            _SettingsShortcut(
              icon: Icons.group_outlined,
              title: '语音热词',
              subtitle:
                  '${widget.controller.firefighters.length} 名 · ${widget.controller.hotwords.length} 个热词',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RosterPage(controller: widget.controller),
                ),
              ),
            ),
            _SettingsShortcut(
              icon: Icons.archive_outlined,
              title: '归档警情',
              subtitle: '查看复盘时间线',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ArchivedIncidentsPage(controller: widget.controller),
                ),
              ),
            ),
            _SettingsShortcut(
              icon: Icons.bar_chart_outlined,
              title: '数据统计',
              subtitle: entries.isEmpty
                  ? '暂无记录'
                  : '本场 $activeEntries 次 · $uniqueNames 人',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatsPage(controller: widget.controller),
                ),
              ),
            ),
            _SettingsShortcut(
              icon: Icons.receipt_long_outlined,
              title: '操作日志',
              subtitle: '本机日志 · 可同步',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => OpLogPage(controller: widget.controller),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          const SectionTitle(text: '运行策略'),
          _SettingsAccordion(
            icon: Icons.calculate_outlined,
            title: '计算参数',
            summary: _calculationSummary,
            child: _buildCalculationBody(),
          ),
          const SizedBox(height: 9),
          _SettingsAccordion(
            icon: Icons.mic_none_outlined,
            title: '语音识别',
            summary: _asrCloud ? '云端优先 · 失败自动切换本地' : '强制本地识别 · 使用离线模型',
            child: _buildVoiceBody(),
          ),
          const SizedBox(height: 9),
          _SettingsAccordion(
            icon: Icons.notifications_none_outlined,
            title: '提醒方式',
            summary: _alertSummary,
            child: _buildAlertBody(),
          ),
          const SizedBox(height: 22),
          const SectionTitle(text: '连接与维护'),
          _SettingsAccordion(
            icon: Icons.dns_outlined,
            title: '服务连接',
            summary: 'CloudBase 生产网关 · 设置可同步',
            child: _buildServerBody(),
          ),
          const SizedBox(height: 9),
          _buildUpdateCard(),
          const SizedBox(height: 9),
          _SettingsLinkCard(
            icon: Icons.info_outline,
            title: '关于项目',
            subtitle: '项目介绍、使用说明与开源信息',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutPage()),
            ),
          ),
          const SizedBox(height: 28),
          Column(
            children: [
              Text(
                '火场智控 v$_displayVersion',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
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

  String get _calculationSummary {
    if (_volume.text.isEmpty || _full.text.isEmpty) return '正在读取参数…';
    return '${_volume.text} L · ${_full.text} MPa · 提醒 ${_warn.text} min / 报警 ${_alarm.text} min';
  }

  String get _alertSummary {
    final active = [
      _tts,
      _sound,
      _keepScreenOn,
      _keepAlive,
    ].where((v) => v).length;
    return '$active 项提醒策略开启';
  }

  Future<void> _leaveUnit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出当前单位？'),
        content: Text('退出后将清除本机的“$_unitName”认证，需要重新输入单位验证码和姓名。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.alarm),
            child: const Text('退出单位'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.leaveUnit();
    if (!mounted) return;
    setState(() {
      _unitAuthenticated = false;
      _unitName = '';
      _realName.clear();
      _editingName = false;
    });
  }

  Widget _buildIdentityCard() {
    final name = _realName.text.trim().isEmpty ? '未认证' : _realName.text.trim();
    final unitName = _unitName.trim().isEmpty ? '未选择单位' : _unitName.trim();
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: AppColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.person_outline,
                  size: 24,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.caution.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: const Text(
                            '单位',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            unitName,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _editingName ? '完成编辑' : '编辑姓名',
                style: IconButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  backgroundColor: AppColors.surfaceSubtle,
                  minimumSize: const Size(48, 48),
                  fixedSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  if (_editingName) {
                    FocusScope.of(context).unfocus();
                    setState(() => _editingName = false);
                    _autoSave();
                    return;
                  }
                  setState(() => _editingName = true);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _realNameFocus.requestFocus();
                    _realName.selection = TextSelection.collapsed(
                      offset: _realName.text.length,
                    );
                  });
                },
                icon: Icon(
                  _editingName ? Icons.check_rounded : Icons.edit_outlined,
                  size: 21,
                ),
              ),
            ],
          ),
          if (_editingName) ...[
            const SizedBox(height: 11),
            TextField(
              controller: _realName,
              focusNode: _realNameFocus,
              autofocus: true,
              maxLength: 20,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '真实姓名',
                hintText: '留空为匿名',
                counterText: '',
              ),
            ),
          ],
          const SizedBox(height: 13),
          const Divider(height: 1),
          if (_unitAuthenticated) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('leave-unit'),
              onPressed: _saving ? null : _leaveUnit,
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('退出当前单位'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.alarm,
                side: const BorderSide(color: AppColors.alarm),
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              '用于日志署名，留空为“匿名”。',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldGrid(
    Widget first,
    Widget second,
    Widget third,
    Widget fourth,
  ) {
    final compact =
        MediaQuery.sizeOf(context).width < 400 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    final cards = [first, second, third, fourth];
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            cards[i],
            if (i < cards.length - 1) const SizedBox(height: 9),
          ],
        ],
      );
    }
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 9,
      mainAxisSpacing: 9,
      childAspectRatio: 2.05,
      children: [first, second, third, fourth],
    );
  }

  Widget _buildCalculationBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _GroupLabel('气瓶参数'),
        Row(
          children: [
            Expanded(
              child: _field(
                _volume,
                '气瓶容量',
                '6.8 L',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                focusNode: _volumeFocus,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _field(
                _full,
                '满压',
                '30 MPa',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                focusNode: _fullFocus,
              ),
            ),
          ],
        ),
        _field(
          _consumption,
          '消耗率',
          '80 L/min',
          keyboard: const TextInputType.numberWithOptions(decimal: true),
          focusNode: _consumptionFocus,
        ),
        const _GroupLabel('提醒阈值'),
        Row(
          children: [
            Expanded(
              child: _field(
                _warn,
                '提醒剩余',
                '10 min',
                keyboard: TextInputType.number,
                focusNode: _warnFocus,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _field(
                _alarm,
                '报警剩余',
                '5 min',
                keyboard: TextInputType.number,
                focusNode: _alarmFocus,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVoiceBody() {
    return Column(
      children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: const Icon(
            Icons.cloud_outlined,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            '联网语音识别',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          subtitle: const Text('云端识别失败后自动切换本地', style: TextStyle(fontSize: 11)),
          activeThumbColor: AppColors.voice,
          value: _asrCloud,
          onChanged: (v) async {
            if (!v) {
              // 模型检查/下载完成前不提交“强制本地”配置，避免异步检查期间
              // 先保存了不可用的离线模式。
              final ready = await _checkModelBeforeOffline();
              if (!mounted || !ready) return;
            }
            if (!mounted) return;
            setState(() => _asrCloud = v);
            _autoSave();
          },
        ),
        const Divider(height: 1, indent: 14, endIndent: 14),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: const Icon(
            Icons.shield_outlined,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            '联网语义解析',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            '云端解析失败后自动切换本地规则',
            style: TextStyle(fontSize: 11),
          ),
          activeThumbColor: AppColors.voice,
          value: _parseCloud,
          onChanged: (v) {
            setState(() => _parseCloud = v);
            _autoSave();
          },
        ),
        if (widget.controller.localAsr != null) ...[
          const Divider(height: 1, indent: 14, endIndent: 14),
          _buildModelTile(),
        ],
      ],
    );
  }

  Widget _buildAlertBody() {
    return Column(
      children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: const Icon(
            Icons.volume_up_outlined,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            '语音播报',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            '确认、提醒、报警时播报中文语音',
            style: TextStyle(fontSize: 11),
          ),
          activeThumbColor: AppColors.actionPrimary,
          value: _tts,
          onChanged: (v) {
            setState(() => _tts = v);
            _autoSave();
          },
        ),
        const Divider(height: 1, indent: 14, endIndent: 14),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: const Icon(
            Icons.notifications_none_outlined,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            '报警音',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            '前台警报音 + 后台本地通知',
            style: TextStyle(fontSize: 11),
          ),
          activeThumbColor: AppColors.actionPrimary,
          value: _sound,
          onChanged: (v) {
            setState(() => _sound = v);
            _autoSave();
          },
        ),
        const Divider(height: 1, indent: 14, endIndent: 14),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: const Icon(
            Icons.light_mode_outlined,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            '屏幕常亮',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            '看板页保持屏幕常亮，适合火场值守',
            style: TextStyle(fontSize: 11),
          ),
          activeThumbColor: AppColors.actionPrimary,
          value: _keepScreenOn,
          onChanged: (v) {
            setState(() => _keepScreenOn = v);
            _autoSave();
          },
        ),
        const Divider(height: 1, indent: 14, endIndent: 14),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: const Icon(
            Icons.shield_moon_outlined,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            '后台值守模式',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            '切后台或锁屏后，轮询与报警不停',
            style: TextStyle(fontSize: 11),
          ),
          activeThumbColor: AppColors.safe,
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
        if (!widget.controller.alarm.exactAlarmAvailable)
          _permissionTile(
            icon: Icons.notifications_off_outlined,
            title: '精确闹钟权限未开启',
            subtitle: '后台提醒可能延迟，点击去系统设置检查',
            onTap: ForegroundKeepAlive.openAlarmsAndRemindersSettings,
          ),
        if (!_policyAccess)
          _permissionTile(
            icon: Icons.do_not_disturb_on_outlined,
            title: '勿扰访问未开启',
            subtitle: '勿扰模式下报警提醒可能被静音',
            onTap: AlarmNative.openNotificationPolicySettings,
          ),
        if (!_fullScreenOk)
          _permissionTile(
            icon: Icons.fullscreen_exit_outlined,
            title: '全屏通知未开启',
            subtitle: '后台报警不会弹出全屏提醒',
            onTap: AlarmNative.openNotificationSettings,
          ),
      ],
    );
  }

  Widget _permissionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        const Divider(height: 1, indent: 14, endIndent: 14),
        ListTile(
          dense: true,
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: Icon(icon, color: AppColors.caution, size: 20),
          title: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }

  Widget _buildServerBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _field(
          _server,
          '服务器地址',
          '默认使用 CloudBase 生产网关',
          keyboard: TextInputType.url,
          focusNode: _serverFocus,
        ),
        _field(
          _token,
          '访问令牌',
          '与服务器 API_TOKEN 一致',
          obscure: !_tokenVisible,
          focusNode: _tokenFocus,
          suffix: IconButton(
            tooltip: _tokenVisible ? '隐藏令牌' : '显示令牌',
            icon: Icon(
              _tokenVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
          ),
        ),
        const _SyncNotice(),
      ],
    );
  }

  Widget _buildUpdateCard() {
    final pending = widget.controller.pendingUpdate;
    final String subtitle;
    final Color subtitleColor;
    if (pending != null) {
      subtitle = '发现新版本 ${pending.tagName}，点击更新';
      subtitleColor = AppColors.caution;
    } else if (widget.controller.updateCheckError != null) {
      subtitle = '检查更新失败，点击重试';
      subtitleColor = AppColors.alarm;
    } else if (widget.controller.updateCheckDone) {
      subtitle = '已是最新版本';
      subtitleColor = AppColors.textTertiary;
    } else {
      subtitle = '从国内更新服务获取最新版本';
      subtitleColor = AppColors.textTertiary;
    }
    return AppCard(
      onTap: _checkingUpdate ? null : _checkUpdate,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          _SettingsIconBox(
            icon: _checkingUpdate
                ? Icons.downloading_outlined
                : Icons.system_update_alt_rounded,
            badge: pending != null && !_checkingUpdate,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '版本更新',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: subtitleColor),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textTertiary),
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
      final pct = _downloadProgress == null
          ? null
          : (_downloadProgress! * 100).round();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pct == null ? '正在下载本地语音模型…' : '正在下载本地语音模型… $pct%',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
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
        leading: Icon(
          Icons.cloud_download_outlined,
          color: AppColors.textTertiary,
          size: 20,
        ),
        title: Text(
          '检查本地语音模型…',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      );
    }
    if (installed) {
      return ListTile(
        dense: true,
        leading: const Icon(
          Icons.check_circle_outline,
          color: AppColors.safe,
          size: 20,
        ),
        title: const Text(
          '本地语音模型已就绪（离线可用）',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
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
              const Icon(
                Icons.offline_bolt_outlined,
                color: AppColors.caution,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '本地 ASR 主模型未下载（约 75MB；另有可选的 9.8MB 降噪模型）\n下载后断网也能语音录入',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          if (_downloadError != null) ...[
            const SizedBox(height: 8),
            Text(
              _downloadError!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.alarm,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
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
          Text(
            '保存中',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      _SaveState.saved => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 14, color: AppColors.safe),
          SizedBox(width: 5),
          Text(
            '已保存',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.safe,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      _SaveState.failed => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 14, color: AppColors.alarm),
          SizedBox(width: 5),
          Text(
            '保存失败',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.alarm,
              fontWeight: FontWeight.w600,
            ),
          ),
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

class _SettingsEyebrow extends StatelessWidget {
  final String text;

  const _SettingsEyebrow(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

class _SettingsHero extends StatelessWidget {
  final Incident? incident;
  final bool connected;
  final String? syncError;

  const _SettingsHero({
    required this.incident,
    required this.connected,
    required this.syncError,
  });

  @override
  Widget build(BuildContext context) {
    final active = incident?.isActive == true;
    final title = active ? incident!.displayName : '暂无处置警情';
    final status = active ? '处置中' : '待命';
    final subtitle = !connected
        ? '本地数据 · ${syncError ?? '等待网络恢复'}'
        : active
        ? '已加入警情 · 现场协同正常'
        : '请选择或新建警情后开始处置';

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: const BoxDecoration(color: AppColors.actionPrimary),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              right: -74,
              bottom: -96,
              child: IgnorePointer(
                child: Container(
                  width: 245,
                  height: 245,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.heroOnDarkBorder),
                    boxShadow: const [
                      BoxShadow(
                        color: AppColors.heroOnDarkRing,
                        blurRadius: 0,
                        spreadRadius: 21,
                      ),
                      BoxShadow(
                        color: AppColors.heroOnDarkRingFaint,
                        blurRadius: 0,
                        spreadRadius: 43,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const FireControlLogo(
                      size: 38,
                      background: AppColors.heroOnDark,
                      foreground: AppColors.actionPrimary,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '火场智控',
                            style: TextStyle(
                              color: AppColors.heroMuted,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.3,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '现场处置',
                            style: TextStyle(
                              color: AppColors.heroOnDark,
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.safe.withValues(alpha: 0.22)
                            : AppColors.heroOnDark.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            active
                                ? Icons.check_rounded
                                : Icons.pause_circle_outline,
                            size: 14,
                            color: active
                                ? AppColors.heroActive
                                : AppColors.heroInactive,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            status,
                            style: TextStyle(
                              color: active
                                  ? AppColors.heroActive
                                  : AppColors.heroInactive,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                const Text(
                  '当前警情',
                  style: TextStyle(color: AppColors.heroLabel, fontSize: 11),
                ),
                const SizedBox(height: 7),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.heroOnDark,
                    fontSize: 16,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.heroMuted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsIconBox extends StatelessWidget {
  final IconData icon;
  final bool badge;

  const _SettingsIconBox({required this.icon, this.badge = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 35,
      height: 35,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 35,
            height: 35,
            decoration: BoxDecoration(
              color: AppColors.surfaceSubtle,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppColors.textPrimary),
          ),
          if (badge)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: AppColors.alarm,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SettingsShortcut extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsShortcut({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < 400 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(11),
      child: Row(
        crossAxisAlignment: compact
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          _SettingsIconBox(icon: icon),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: compact ? 2 : 1,
                  overflow: compact
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: compact ? 3 : 1,
                  overflow: compact
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 5),
          const Icon(
            Icons.arrow_forward_outlined,
            size: 15,
            color: AppColors.textTertiary,
          ),
        ],
      ),
    );
  }
}

class _SettingsLinkCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsLinkCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          _SettingsIconBox(icon: icon),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.arrow_forward_outlined,
            size: 16,
            color: AppColors.textTertiary,
          ),
        ],
      ),
    );
  }
}

class _SyncNotice extends StatelessWidget {
  const _SyncNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 1),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.safe.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sync_outlined, size: 17, color: AppColors.online),
          SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '个人设置同步已开启\n',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(text: '本机修改优先保存，联网后自动同步。'),
                ],
              ),
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 可折叠分区：卡片标题与内容保持同一层级，避免运行策略内部间距失衡。
class _SettingsAccordion extends StatefulWidget {
  final IconData icon;
  final String title;
  final String summary;
  final Widget child;

  const _SettingsAccordion({
    required this.icon,
    required this.title,
    required this.summary,
    required this.child,
  });

  @override
  State<_SettingsAccordion> createState() => _SettingsAccordionState();
}

class _SettingsAccordionState extends State<_SettingsAccordion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: AppShadow.card,
      ),
      child: Material(
        color: AppColors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: const BorderSide(color: AppColors.border),
        ),
        child: Column(
          children: [
            Semantics(
              container: true,
              button: true,
              excludeSemantics: true,
              expanded: _expanded,
              label: '${widget.title}，${_expanded ? '已展开' : '已收起'}',
              hint: _expanded ? '点击收起设置' : '点击展开设置',
              onTap: () => setState(() => _expanded = !_expanded),
              child: InkWell(
                excludeFromSemantics: true,
                onTap: () => setState(() => _expanded = !_expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        _SettingsIconBox(icon: widget.icon),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                widget.summary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: AppColors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            AnimatedCrossFade(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              firstCurve: Curves.easeOut,
              secondCurve: Curves.easeIn,
              sizeCurve: Curves.easeOut,
              crossFadeState: _expanded
                  ? CrossFadeState.showFirst
                  : CrossFadeState.showSecond,
              firstChild: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: widget.child,
              ),
              secondChild: const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
