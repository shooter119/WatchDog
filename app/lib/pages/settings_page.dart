import 'package:flutter/material.dart';

import '../services/settings.dart';
import '../state/app_controller.dart';

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
  bool _tts = true;
  bool _sound = true;

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
    setState(() {});
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
        padding: const EdgeInsets.all(16),
        children: [
          const Text('设置', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _sectionTitle('服务端'),
          _field(_server, '服务器地址', 'http://你的VPS:3000', keyboard: TextInputType.url),
          _field(_scene, '场景码', '多设备同步用同一场景码'),
          _field(_token, '访问令牌', '与服务器 API_TOKEN 一致', obscure: true),
          const SizedBox(height: 8),
          _sectionTitle('计算参数'),
          Row(
            children: [
              Expanded(child: _field(_volume, '气瓶容量 (L)', '6.8')),
              const SizedBox(width: 8),
              Expanded(child: _field(_full, '满压 (MPa)', '30')),
            ],
          ),
          Row(
            children: [
              Expanded(child: _field(_consumption, '消耗率 (L/min)', '40')),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _warn,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '提醒剩余 (min)'),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _alarm,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '报警剩余 (min)'),
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),
          _sectionTitle('提醒方式'),
          SwitchListTile(
            title: const Text('语音播报'),
            subtitle: const Text('确认/提醒/报警时播报中文语音'),
            value: _tts,
            onChanged: (v) => setState(() => _tts = v),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: const Text('报警音'),
            subtitle: const Text('前台警报音 + 后台本地通知'),
            value: _sound,
            onChanged: (v) => setState(() => _sound = v),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('保存设置', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '安全员助手 WatchDog v0.1\n语音录入 → 气瓶余量 → 自动倒计时\n豆包语音识别 + DeepSeek 语义解析',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(t, style: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w600)),
      );

  Widget _field(TextEditingController c, String label, String hint, {TextInputType? keyboard, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: keyboard,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      ),
    );
  }
}
