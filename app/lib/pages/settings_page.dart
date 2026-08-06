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
  bool _tokenVisible = false;
  bool _tts = true;
  bool _sound = true;
  bool _keepScreenOn = true;

  @override
  void initState() {
    super.initState();
    _load();
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
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
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
    await ScreenOn.setKeepScreenOn(_keepScreenOn);
    await widget.controller.refreshConfig();
    widget.controller.startSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存')));
    }
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
                  _field(_server, '服务器地址', '默认 https://bytevirt.meiyou.xyz:8443', icon: Icons.dns_outlined, keyboard: TextInputType.url),
                  _field(_scene, '场景码', '多设备同步用同一场景码', icon: Icons.tag),
                  _field(
                    _token,
                    '访问令牌',
                    '与服务器 API_TOKEN 一致',
                    icon: Icons.key_outlined,
                    obscure: !_tokenVisible,
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
                      Expanded(child: _field(_volume, '气瓶容量 (L)', '6.8', icon: Icons.local_fire_department_outlined)),
                      const SizedBox(width: 10),
                      Expanded(child: _field(_full, '满压 (MPa)', '30', icon: Icons.speed)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _field(_consumption, '消耗率 (L/min)', '40', icon: Icons.water_drop_outlined)),
                      const SizedBox(width: 10),
                      Expanded(child: _field(_warn, '提醒剩余 (min)', '10', icon: Icons.notifications_active_outlined)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _field(_alarm, '报警剩余 (min)', '5', icon: Icons.warning_amber_rounded)),
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
                    onChanged: (v) => setState(() => _tts = v),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: const Text('报警音', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('前台警报音 + 后台本地通知'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _sound,
                    onChanged: (v) => setState(() => _sound = v),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: const Text('屏幕常亮', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    subtitle: const Text('看板页保持屏幕常亮，适合火场值守'),
                    activeThumbColor: AppColors.actionPrimary,
                    value: _keepScreenOn,
                    onChanged: (v) => setState(() => _keepScreenOn = v),
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
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存设置', style: TextStyle(fontSize: 16)),
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
    IconData? icon,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
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
