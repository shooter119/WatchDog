import 'dart:async';

import 'package:flutter/material.dart';

import '../services/alarm_service.dart';
import '../services/foreground_keep_alive.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'about_page.dart';
import 'op_log_page.dart';
import 'roster_page.dart';
import 'stats_page.dart';

/// 当前版本号：与 app/pubspec.yaml 的 version 保持一致，只在设置页底部展示
const appVersion = '0.8.2+19';

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
  final FocusNode _serverFocus = FocusNode();
  final FocusNode _tokenFocus = FocusNode();
  final FocusNode _volumeFocus = FocusNode();
  final FocusNode _fullFocus = FocusNode();
  final FocusNode _consumptionFocus = FocusNode();
  final FocusNode _warnFocus = FocusNode();
  final FocusNode _alarmFocus = FocusNode();
  bool _tokenVisible = false;
  bool _tts = true;
  bool _sound = true;
  bool _keepScreenOn = true;
  bool _keepAlive = false;
  bool _asrCloud = true;
  bool _parseCloud = true;
  bool? _modelInstalled;
  bool _downloading = false;
  double? _downloadProgress;
  String? _downloadError;
  bool _policyAccess = true; // 勿扰策略访问是否授权（bypassDnd 生效前提）
  bool _fullScreenOk = true; // Android 14+ 全屏通知是否开启
  bool _loaded = false;
  bool _saving = false; // 防止失焦时 8 个输入框监听器并发触发多次保存
  _SaveState _saveState = _SaveState.idle; // 自动保存状态提示

  @override
  void initState() {
    super.initState();
    // 任一输入框失焦且全部输入框均无焦点（点空白处/收起键盘）→ 自动保存
    for (final n in [
      _serverFocus, _tokenFocus, _volumeFocus,
      _fullFocus, _consumptionFocus, _warnFocus, _alarmFocus,
    ]) {
      n.addListener(() {
        if (_loaded && !n.hasFocus && _allInputsUnfocused()) _autoSave();
      });
    }
    _load();
  }

  bool _allInputsUnfocused() {
    return [
      _serverFocus, _tokenFocus, _volumeFocus,
      _fullFocus, _consumptionFocus, _warnFocus, _alarmFocus,
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
    _loaded = true;
    _refreshModelStatus();
    _refreshAlarmCaps();
    if (mounted) setState(() {});
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
      await Settings.setConsumptionLpm(double.tryParse(_consumption.text) ?? 40);
      await Settings.setThresholds(
        int.tryParse(_warn.text) ?? 10,
        int.tryParse(_alarm.text) ?? 5,
      );
      await Settings.setTtsEnabled(_tts);
      await Settings.setAlarmSoundEnabled(_sound);
      await Settings.setKeepScreenOn(_keepScreenOn);
      await Settings.setAsrCloudEnabled(_asrCloud);
      await Settings.setParseCloudEnabled(_parseCloud);
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
    _server.dispose();
    _token.dispose();
    _volume.dispose();
    _full.dispose();
    _consumption.dispose();
    _warn.dispose();
    _alarm.dispose();
    _serverFocus.dispose();
    _tokenFocus.dispose();
    _volumeFocus.dispose();
    _fullFocus.dispose();
    _consumptionFocus.dispose();
    _warnFocus.dispose();
    _alarmFocus.dispose();
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
                  _field(_consumption, '消耗率', '40 L/min', icon: Icons.water_drop_outlined, focusNode: _consumptionFocus),
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
                      subtitle: const Text('请在系统设置-应用-安全员助手中允许闹钟与提醒', style: TextStyle(fontSize: 11)),
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
                '安全员助手 WatchDog v$appVersion',
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
