import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'admin_scanner_page.dart';

import '../services/alarm_service.dart';
import '../services/foreground_keep_alive.dart';
import '../services/local_asr_service.dart';
import '../services/op_log_service.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../services/storage_service.dart';
import '../services/theme_controller.dart';
import '../services/update_service.dart';
import '../state/app_controller.dart';
import '../theme/app_palette.dart';
import '../theme/app_widgets.dart';
import 'about_page.dart';
import 'archived_incidents_page.dart';
import 'op_log_page.dart';
import 'roster_page.dart';
import 'member_review_page.dart';
import 'stats_page.dart';
import 'unit_stations_page.dart';
import 'video_resource_admin_page.dart';
import 'watermark_settings_page.dart';

/// 当前版本号（fallback：运行时由 package_info_plus 读取 pubspec version 覆盖，测试环境用此常量）
const appVersion = '1.9.0+91';

class SettingsPage extends StatefulWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _server = TextEditingController();
  final TextEditingController _volume = TextEditingController();
  final TextEditingController _full = TextEditingController();
  final TextEditingController _consumption = TextEditingController();
  final TextEditingController _warn = TextEditingController();
  final TextEditingController _alarm = TextEditingController();
  final TextEditingController _realName = TextEditingController();
  final FocusNode _serverFocus = FocusNode();
  final FocusNode _volumeFocus = FocusNode();
  final FocusNode _fullFocus = FocusNode();
  final FocusNode _consumptionFocus = FocusNode();
  final FocusNode _warnFocus = FocusNode();
  final FocusNode _alarmFocus = FocusNode();
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
  String _unitName = '';
  bool _unitAuthenticated = false;
  String _unitRole = 'member';
  bool _canManageVideoResources = false;

  @override
  void initState() {
    super.initState();
    // 任一输入框失焦且全部输入框均无焦点（点空白处/收起键盘）→ 自动保存
    for (final n in [
      _serverFocus,
      _volumeFocus,
      _fullFocus,
      _consumptionFocus,
      _warnFocus,
      _alarmFocus,
    ]) {
      n.addListener(() {
        if (_loaded && !n.hasFocus && _allInputsUnfocused()) _autoSave();
      });
    }
    // 启动自动检查完成后刷新「检查更新」卡片提示（有新版/已最新）
    widget.controller.addListener(_onControllerChanged);
    unawaited(widget.controller.refreshPendingMembersCount());
    _load();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.controller.protectedDataRevoked ||
        widget.controller.needsAuthentication) {
      _unitAuthenticated = false;
      _realName.clear();
      _unitName = '';
      _canManageVideoResources = false;
    } else {
      unawaited(_loadIdentity());
    }
  }

  Future<void> _loadIdentity() async {
    final epoch = widget.controller.protectedDataEpoch;
    final name = await Settings.realName;
    final unit = await Settings.unitName;
    final role = await Settings.userRole;
    final authenticated =
        (await Settings.unitId).isNotEmpty &&
        (await Settings.unitName).isNotEmpty &&
        (await Settings.unitCode).isNotEmpty;
    if (!mounted ||
        widget.controller.protectedDataRevoked ||
        epoch != widget.controller.protectedDataEpoch) {
      return;
    }
    setState(() {
      _unitRole = role;
      _canManageVideoResources = role == 'manager' || role == 'admin';
      _realName.text = name;
      _unitName = unit;
      _unitAuthenticated = authenticated;
    });
  }

  bool _allInputsUnfocused() {
    return [
      _serverFocus,
      _volumeFocus,
      _fullFocus,
      _consumptionFocus,
      _warnFocus,
      _alarmFocus,
    ].every((n) => !n.hasFocus);
  }

  Future<void> _load() async {
    _server.text = await Settings.serverUrl;
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
    _unitRole = await Settings.userRole;
    _canManageVideoResources = _unitRole == 'manager' || _unitRole == 'admin';
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

  /// 检查更新：ALI OTA 最新版 → 提示/下载/安装
  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    String? error;
    UpdateInfo? info;
    final opId = 'release-check-${DateTime.now().millisecondsSinceEpoch}';
    void trace(String stage, String message, String level) {
      OpLogService.instance.record(
        opId,
        stage,
        message,
        level: level,
        data: {'source': 'ALI OTA'},
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
                  style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
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
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
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
    _volume.dispose();
    _full.dispose();
    _consumption.dispose();
    _warn.dispose();
    _alarm.dispose();
    _realName.dispose();
    _serverFocus.dispose();
    _volumeFocus.dispose();
    _fullFocus.dispose();
    _consumptionFocus.dispose();
    _warnFocus.dispose();
    _alarmFocus.dispose();
    super.dispose();
  }

  Widget _buildAppearanceCard() {
    // 选中态直接从 ThemeController 读：不建本地副本，避免两处状态不一致。
    // 只切换配色，不进入自动保存链路，也不写 settings_modified_at。
    final currentId = ThemeController.instance.currentId;
    return AppCard(
      padding: EdgeInsets.all(12),
      child: Row(
        children: [
          for (final palette in AppPalette.values) ...[
            Expanded(
              child: _ThemeOption(
                palette: palette,
                selected: palette.id == currentId,
                onTap: () {
                  ThemeController.instance.select(palette);
                  setState(() {});
                },
              ),
            ),
            if (palette.id != AppPalette.values.last.id)
              const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = !widget.controller.connectionLost;
    final entries = widget.controller.entries;
    final activeEntries = entries.where((entry) => entry.isActive).length;
    final uniqueNames = entries
        .map((entry) => entry.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .length;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('设置', style: AppTextStyles.h1),
              const SizedBox(width: 10),
              _SaveStatusBadge(state: _saveState),
              const Spacer(),
              ConnectionStatus(
                connected: !widget.controller.connectionLost,
                localOnly: widget.controller.isGuest,
                syncing: widget.controller.syncing,
                syncError: widget.controller.syncError,
                onRetry: widget.controller.refreshNow,
              ),
            ],
          ),
          const SizedBox(height: 6),
          const _SettingsEyebrow('现场处置 / 本机状态'),
          const SizedBox(height: 8),
          _buildIdentityCard(),
          const SizedBox(height: 22),
          const SectionTitle(text: '现场设置'),
          const SizedBox(height: 9),
          _SettingsLinkCard(
            icon: Icons.branding_watermark_outlined,
            title: '水印设置',
            subtitle: '配置拍摄水印，拍摄请用首页水印相机',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WatermarkSettingsPage()),
            ),
          ),
          const SizedBox(height: 9),

          if (widget.controller.canReviewMembers ||
              widget.controller.memberReviewError != null) ...[
            _SettingsLinkCard(
              icon: Icons.how_to_reg_outlined,
              title: '入队审批',
              subtitle: widget.controller.memberReviewError != null
                  ? '审批信息加载失败，点击重试'
                  : widget.controller.pendingMemberCount > 0
                  ? '${widget.controller.pendingMemberCount} 条待处理 · 本单位管理员共同审批'
                  : '可审批本单位申请 · 暂无待处理',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      MemberReviewPage(controller: widget.controller),
                ),
              ),
            ),
            const SizedBox(height: 9),
          ],
          _buildFieldGrid([
            _SettingsShortcut(
              icon: Icons.group_outlined,
              title: '人员与热词',
              subtitle: widget.controller.pendingMemberCount > 0
                  ? '${widget.controller.pendingMemberCount} 名队员待审批'
                  : '人员名单与语音热词',
              badge: widget.controller.pendingMemberCount > 0,
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
          ]),
          const SizedBox(height: 9),
          _SettingsLinkCard(
            icon: Icons.local_fire_department_outlined,
            title: '单位常用队伍',
            subtitle: '登记名称、别名及启用状态',
            enabled: widget.controller.api != null,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => UnitStationsPage(api: widget.controller.api!),
              ),
            ),
          ),
          if (_canManageVideoResources) ...[
            const SizedBox(height: 9),
            _SettingsLinkCard(
              key: const Key('video-resource-settings'),
              icon: Icons.videocam_outlined,
              title: '视频资源管理',
              subtitle: '添加、编辑或停用本单位视频资源',
              enabled: widget.controller.api != null,
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      VideoResourceAdminPage(api: widget.controller.api!),
                ),
              ),
            ),
          ],
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
          const SectionTitle(text: '界面外观'),
          _buildAppearanceCard(),
          const SizedBox(height: 22),
          const SectionTitle(text: '连接与维护'),
          _SettingsAccordion(
            icon: Icons.dns_outlined,
            title: '服务连接',
            summary: widget.controller.isGuest
                ? '单机演练 · 仅本机保存'
                : connected
                ? '现场协同服务器 · 连接正常'
                : '现场协同服务器 · 等待连接',
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
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '一线消防员开发 · 开源项目',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String get _calculationSummary {
    if (_volume.text.isEmpty || _full.text.isEmpty) return '正在读取参数…';
    return '${_volume.text} L · ${_full.text} MPa\n提醒 ${_warn.text} 分钟 · 报警 ${_alarm.text} 分钟';
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
    });
  }

  Widget _buildIdentityCard() {
    final guest = widget.controller.isGuest;
    final authenticated =
        !guest && _unitAuthenticated && !widget.controller.protectedDataRevoked;
    final name = guest
        ? '游客模式'
        : authenticated && _realName.text.trim().isNotEmpty
        ? _realName.text.trim()
        : '未认证';
    final unit = authenticated && _unitName.trim().isNotEmpty
        ? _unitName.trim()
        : '未选择单位';
    final backend = authenticated && widget.controller.canReadKeySites
        ? widget.controller.adminCapability
        : null;
    final level = guest
        ? '游客'
        : !authenticated
        ? '未认证'
        : _unitRole == 'admin' || _unitRole == 'manager' || backend != null
        ? '管理员'
        : '认证用户';
    return _IdentityHeroCard(
      guest: guest,
      authenticated: authenticated,
      name: name,
      unit: unit,
      level: level,
      canScan: backend != null,
      onLeave: _leaveUnit,
      onJoin: widget.controller.leaveUnit,
      onScan: () async {
        await widget.controller.refreshAdminCapability();
        if (!mounted ||
            !widget.controller.canReadKeySites ||
            widget.controller.adminCapability == null) {
          return;
        }
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => AdminScannerPage(controller: widget.controller),
          ),
        );
      },
    );
  }

  Widget _buildFieldGrid(List<Widget> entries) {
    final compact =
        MediaQuery.sizeOf(context).width < 400 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    final cards = entries;
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
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 9,
        mainAxisSpacing: 9,
        // 与身份栏、水印设置等保持同一行高；大字号时允许按比例增高。
        mainAxisExtent: (66 * scale.clamp(1.0, 1.25)).toDouble(),
      ),
      children: cards,
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
          secondary: Icon(Icons.cloud_outlined, color: AppColors.textSecondary),
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
          secondary: Icon(
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
          secondary: Icon(
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
          secondary: Icon(
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
          secondary: Icon(
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
          secondary: Icon(
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
          Padding(
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
            style: TextStyle(
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
          '现场协同服务器地址（Android 模拟器：10.0.2.2:3000）',
          keyboard: TextInputType.url,
          focusNode: _serverFocus,
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
      subtitleColor = AppColors.textSecondary;
    } else if (widget.controller.updateCheckError != null) {
      subtitle = '检查更新失败，点击重试';
      subtitleColor = AppColors.alarm;
    } else if (widget.controller.updateCheckDone) {
      subtitle = '已是最新版本';
      subtitleColor = AppColors.textSecondary;
    } else {
      subtitle = '从协同更新服务器获取最新版本';
      subtitleColor = AppColors.textSecondary;
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: subtitleColor),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 20, color: AppColors.textTertiary),
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
              style: TextStyle(
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
      return ListTile(
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
        leading: Icon(
          Icons.check_circle_outline,
          color: AppColors.safe,
          size: 20,
        ),
        title: Text(
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
              Icon(
                Icons.offline_bolt_outlined,
                color: AppColors.caution,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
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
              style: TextStyle(
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
      _SaveState.saving => Row(
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
      _SaveState.saved => Row(
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
      _SaveState.failed => Row(
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
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _IdentityHeroCard extends StatelessWidget {
  final bool guest;
  final bool authenticated;
  final bool canScan;
  final String name;
  final String unit;
  final String level;
  final Future<void> Function() onLeave;
  final Future<void> Function() onJoin;
  final Future<void> Function() onScan;

  const _IdentityHeroCard({
    required this.guest,
    required this.authenticated,
    required this.canScan,
    required this.name,
    required this.unit,
    required this.level,
    required this.onLeave,
    required this.onJoin,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = AppColors.heroOnDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.26),
            blurRadius: 28,
            spreadRadius: -4,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          key: const Key('identity-hero'),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.heroOnDarkBorder),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.heroBackground,
                Color.lerp(AppColors.heroBackground, Colors.black, 0.48)!,
                Color.lerp(AppColors.heroBackground, Colors.white, 0.035)!,
              ],
              stops: const [0, 0.58, 1],
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _IdentityCardTexturePainter(foreground),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0.84, -1.05),
                          radius: 1.18,
                          colors: [
                            foreground.withValues(alpha: 0.11),
                            foreground.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 5,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      name,
                                      softWrap: true,
                                      style: TextStyle(
                                        color: foreground,
                                        fontSize: 20,
                                        height: 1.15,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    _HeroRoleBadge(level: level),
                                  ],
                                ),
                                const SizedBox(height: 7),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(top: 1),
                                      child: Icon(
                                        Icons.apartment_rounded,
                                        size: 15,
                                        color: AppColors.heroMuted,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        unit,
                                        softWrap: true,
                                        style: TextStyle(
                                          color: AppColors.heroMuted,
                                          fontSize: 14,
                                          height: 1.35,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (authenticated)
                            PopupMenuButton<String>(
                              key: const Key('user-actions'),
                              tooltip: '用户操作',
                              iconColor: foreground,
                              onSelected: (value) {
                                if (value == 'leave') unawaited(onLeave());
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'leave',
                                  child: Text('退出当前单位'),
                                ),
                              ],
                            ),
                          if (canScan) _HeroScanAction(onTap: onScan),
                        ],
                      ),
                      if (guest) ...[
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => unawaited(onJoin()),
                            icon: const Icon(
                              Icons.add_circle_outline,
                              size: 18,
                            ),
                            label: const Text('加入单位'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: foreground,
                              backgroundColor: foreground.withValues(
                                alpha: 0.06,
                              ),
                              minimumSize: const Size(48, 48),
                              side: BorderSide(
                                color: AppColors.heroOnDarkBorder,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroRoleBadge extends StatelessWidget {
  final String level;

  const _HeroRoleBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.heroOnDark.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.heroOnDarkBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.verified_user_outlined,
            size: 13,
            color: AppColors.heroOnDark,
          ),
          const SizedBox(width: 5),
          Text(
            level,
            style: TextStyle(
              color: AppColors.heroOnDark,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroScanAction extends StatelessWidget {
  final Future<void> Function() onTap;

  const _HeroScanAction({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('admin-scan'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => unawaited(onTap()),
      child: Container(
        constraints: const BoxConstraints(minWidth: 58, minHeight: 62),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.heroOnDark.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.heroOnDarkBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.qr_code_scanner_rounded,
              size: 24,
              color: AppColors.heroOnDark,
            ),
            const SizedBox(height: 4),
            Text(
              '扫一扫',
              style: TextStyle(
                color: AppColors.heroOnDark,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityCardTexturePainter extends CustomPainter {
  final Color color;

  const _IdentityCardTexturePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color.withValues(alpha: 0.022)
      ..strokeWidth = 0.65;
    for (double x = -size.height; x < size.width; x += 17) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = color.withValues(alpha: 0.04);
    canvas.drawCircle(
      Offset(size.width * 0.96, -size.height * 0.09),
      size.width * 0.48,
      ring,
    );
    canvas.drawCircle(
      Offset(size.width * 0.96, -size.height * 0.09),
      size.width * 0.33,
      ring,
    );

    final sheenRect = Rect.fromLTWH(
      size.width * 0.42,
      0,
      size.width * 0.46,
      size.height,
    );
    final sheen = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.025),
          color.withValues(alpha: 0),
        ],
      ).createShader(sheenRect);
    final path = Path()
      ..moveTo(size.width * 0.65, 0)
      ..lineTo(size.width * 0.88, 0)
      ..lineTo(size.width * 0.55, size.height)
      ..lineTo(size.width * 0.4, size.height)
      ..close();
    canvas.drawPath(path, sheen);
  }

  @override
  bool shouldRepaint(covariant _IdentityCardTexturePainter oldDelegate) =>
      oldDelegate.color != color;
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
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
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
  final bool badge;

  const _SettingsShortcut({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge = false,
  });

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < 400 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(11),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SettingsIconBox(icon: icon, badge: badge),
            const SizedBox(width: 11),
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
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: compact ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Icon(Icons.chevron_right, size: 20, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _SettingsLinkCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  const _SettingsLinkCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: AppCard(
        onTap: enabled ? onTap : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _SettingsIconBox(icon: icon),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sync_outlined, size: 17, color: AppColors.online),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '现场协同同步已开启\n',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(text: '本机修改优先保存，联网后自动与现场协同服务器同步。'),
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
          side: BorderSide(color: AppColors.border),
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      children: [
                        _SettingsIconBox(icon: widget.icon),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
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
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
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
                          size: 20,
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

/// 配色选项：四色预览 + 名称 + 选中态。
/// 预览色来自该 palette 自身（而不是当前主题），方便直接比较两套方案。
class _ThemeOption extends StatelessWidget {
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    return Semantics(
      button: true,
      selected: selected,
      label: '${palette.label}配色${selected ? '，已选中' : ''}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: AnimatedContainer(
          duration: disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: selected ? palette.actionPrimary : palette.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (final color in [
                    palette.background,
                    palette.surfaceSubtle,
                    palette.actionPrimary,
                    palette.voice,
                  ])
                    Container(
                      width: 16,
                      height: 16,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: palette.border),
                      ),
                    ),
                  const Spacer(),
                  if (selected)
                    Icon(
                      Icons.check_circle,
                      size: 16,
                      color: palette.actionPrimary,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                palette.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                palette.id == 'daylight' ? '高可视亮色' : '暖纸陶土',
                style: TextStyle(fontSize: 10, color: palette.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
