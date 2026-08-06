import 'dart:async';

import 'package:flutter/material.dart';

import '../services/screen_on.dart';
import '../services/settings.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'op_log_page.dart';
import 'roster_page.dart';

class SettingsPage extends StatefulWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _server = TextEditingController();
  final TextEditingController _scene = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _volume = TextEditingController();
  final TextEditingController _full = TextEditingController();
  final TextEditingController _consumption = TextEditingController();
  final TextEditingController _warn = TextEditingController();
  final TextEditingController _alarm = TextEditingController();
  final FocusNode _serverFocus = FocusNode();
  final FocusNode _sceneFocus = FocusNode();
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
  bool _asrCloud = true;
  bool _parseCloud = true;
  bool? _modelInstalled;
  bool _downloading = false;
  double? _downloadProgress;
  String? _downloadError;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    // 任一输入框失焦且全部输入框均无焦点（点空白处/收起键盘）→ 自动保存
    for (final n in [
      _serverFocus, _sceneFocus, _tokenFocus, _volumeFocus,
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
      _serverFocus, _sceneFocus, _tokenFocus, _volumeFocus,
      _fullFocus, _consumptionFocus, _warnFocus, _alarmFocus,
    ].every((n) => !n.hasFocus);
  }

  Future<void> _load() async {
    _server.text = await Settings.serverUrl;
    _scene.text = await Settings.sceneCode;
    _token.text = await Settings.apiToken;
    _volume.text = (await Settings.cylinderVolL).toString();
    _full.text = (await Settings.fullPressureMpa).toString();
    _consumption.text = (await Settings.consumptionLpm).toString();
    _warn.text = (await Settings.warnMin).toString();
    _alarm.text = (await Settings.alarmMin).toString();
    _tts = await Settings.ttsEnabled;
    _sound = await Settings.alarmSoundEnabled;
    _keepScreenOn = await Settings.keepScreenOn;
    _asrCloud = await Settings.asrCloudEnabled;
    _parseCloud = await Settings.parseCloudEnabled;
    _loaded = true;
    _refreshModelStatus();
    if (mounted) setState(() {});
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

  /// 自动保存：文本框失焦（点空白/收起键盘/焦点转移）或开关切换时立即保存本地并触发云端同步（静默）
  Future<void> _autoSave() async {
    await Settings.setServerUrl(_server.text.trim());
    await Settings.setSceneCode(_scene.text.trim());
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
  }

  @override
  void dispose() {
    _server.dispose();
    _scene.dispose();
    _token.dispose();
    _volume.dispose();
    _full.dispose();
    _consumption.dispose();
    _warn.dispose();
    _alarm.dispose();
    _serverFocus.dispose();
    _sceneFocus.dispose();
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
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
          Row(
            children: [
              const Text('设置', style: AppTextStyles.h1),
              const Spacer(),
              ConnectionStatus(
                syncing: widget.controller.syncing,
                offline: widget.controller.syncError != null,
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
                  _field(_scene, '场景码', '多设备同步用同一场景码', icon: Icons.tag, focusNode: _sceneFocus),
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
                children: [
                  Row(
                    children: [
                      Expanded(child: _field(_volume, '气瓶容量', '6.8 L', icon: Icons.local_fire_department_outlined, focusNode: _volumeFocus)),
                      const SizedBox(width: 10),
                      Expanded(child: _field(_full, '满压', '30 MPa', icon: Icons.speed, focusNode: _fullFocus)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _field(_consumption, '消耗率', '40 L/min', icon: Icons.water_drop_outlined, focusNode: _consumptionFocus)),
                      const SizedBox(width: 10),
                      Expanded(child: _field(_warn, '提醒剩余', '10 min', icon: Icons.notifications_active_outlined, focusNode: _warnFocus)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _field(_alarm, '报警剩余', '5 min', icon: Icons.warning_amber_rounded, focusNode: _alarmFocus)),
                      const SizedBox(width: 10),
                      const Expanded(child: SizedBox()),
                    ],
                  ),
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
                      Text('操作日志', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      SizedBox(height: 2),
                      Text('语音录入全流程记录，可同步到服务器调试', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ],
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
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          Column(
            children: [
              const Icon(Icons.shield_outlined, size: 28, color: AppColors.textTertiary),
              const SizedBox(height: 8),
              Text(
                '安全员助手 WatchDog v0.1\n语音录入 → 气瓶余量 → 自动倒计时\n豆包语音识别 + DeepSeek 语义解析',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12, height: 1.7),
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
                  '本地语音模型未下载（约 78MB）\n下载后断网也能语音录入',
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
