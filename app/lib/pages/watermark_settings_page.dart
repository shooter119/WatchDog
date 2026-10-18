import 'package:flutter/material.dart';

import '../services/watermark_settings.dart';
import '../theme/app_widgets.dart';

/// 水印相机设置。
///
/// 单位抬头、拍摄部门、拍摄人都可以单独填写，与登录身份解耦：
/// 借机给别的班组用、临时支援外单位时，改这里就行，不需要重新认证。
class WatermarkSettingsPage extends StatefulWidget {
  const WatermarkSettingsPage({super.key});

  @override
  State<WatermarkSettingsPage> createState() => _WatermarkSettingsPageState();
}

class _WatermarkSettingsPageState extends State<WatermarkSettingsPage> {
  final _unitTitle = TextEditingController();
  final _department = TextEditingController();
  final _actor = TextEditingController();
  WatermarkSettings _settings = WatermarkSettings.defaults;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _unitTitle.dispose();
    _department.dispose();
    _actor.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await WatermarkSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _unitTitle.text = settings.unitTitle;
      _department.text = settings.department;
      _actor.text = settings.actorName;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final next = _settings.copyWith(
      unitTitle: _unitTitle.text.trim(),
      department: _department.text.trim(),
      actorName: _actor.text.trim(),
    );
    await WatermarkSettings.save(next);
    if (!mounted) return;
    setState(() => _settings = next);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('水印设置已保存，下次拍摄生效')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('水印相机'),
        actions: [
          TextButton(onPressed: _loading ? null : _save, child: const Text('保存')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
              children: [
                _previewCard(),
                const SizedBox(height: 18),
                const _GroupTitle('水印内容'),
                _textField(
                  controller: _unitTitle,
                  label: '单位抬头',
                  hint: '例如：浙江总队衢州市消防救援支队',
                  helper: '留空则使用当前登录单位名称',
                ),
                _textField(
                  controller: _department,
                  label: '拍摄单位',
                  hint: '例如：衢州市消防救援支队通信保障分队',
                  helper: '留空则水印底部不显示这一行',
                ),
                _textField(
                  controller: _actor,
                  label: '拍摄人',
                  hint: '留空则不显示',
                  helper: '不需要署名时留空即可，不影响其他字段',
                ),
                const SizedBox(height: 18),
                const _GroupTitle('显示字段'),
                _switchTile(
                  title: '拍摄时间',
                  subtitle: '精确到分钟并带星期',
                  value: _settings.showTime,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(showTime: v)),
                ),
                _switchTile(
                  title: '天气',
                  subtitle: '天气现象、气温、风向风力与湿度',
                  value: _settings.showWeather,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(showWeather: v)),
                ),
                _switchTile(
                  title: '地点',
                  subtitle: '由定位反查的中文地址',
                  value: _settings.showLocation,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(showLocation: v)),
                ),
                _switchTile(
                  title: '经纬度',
                  subtitle: '按度分显示，如 东经 118°22′',
                  value: _settings.showCoordinates,
                  onChanged: (v) =>
                      setState(() => _settings = _settings.copyWith(showCoordinates: v)),
                ),
                _switchTile(
                  title: '左侧标识',
                  subtitle: '关闭后只保留文字，适合不对外发布的内部记录',
                  value: _settings.showLogo,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(showLogo: v)),
                ),
                const SizedBox(height: 18),
                Text(
                  '水印在按下快门或开始录像那一刻固定，成片中的时间、地址不会随时间跳动。'
                  '照片与视频只保存在本机，是否分享由你逐次决定。',
                  style: const TextStyle(fontSize: 12, color: AppColors.textTertiary, height: 1.6),
                ),
              ],
            ),
    );
  }

  Widget _previewCard() {
    final preview = _settings.copyWith(
      unitTitle: _unitTitle.text.trim().isEmpty ? '单位抬头（未填写）' : _unitTitle.text.trim(),
      department: _department.text.trim(),
      actorName: _actor.text.trim(),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('效果预览', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF8FA6B8), Color(0xFF43535F)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: _previewCardBody(preview),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewCardBody(WatermarkSettings s) {
    const blue = Color(0xFF2A72D4);
    final rows = <(String, String)>[
      if (s.showTime) ('拍摄\r\n时间', '2026.10.18 星期日 08:39'),
      if (s.showWeather) ('天气', '晴 21℃ 东南风2级 湿度87%'),
      if (s.showLocation) ('地点', '衢州市 · 某某有限公司'),
      if (s.showCoordinates) ('经度', '东经 118°22′'),
      if (s.showCoordinates) ('纬度', '北纬 29°0′'),
      if (s.actorName.isNotEmpty) ('拍摄人', s.actorName),
    ];
    return Container(
      width: 190,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(5),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: blue,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Row(
              children: [
                if (s.showLogo)
                  Container(
                    width: 16,
                    height: 16,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC8102E),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Icon(Icons.shield_outlined, size: 11, color: Colors.white),
                  ),
                Expanded(
                  child: Text(
                    s.unitTitle.isEmpty ? '单位抬头' : s.unitTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      row.$1,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 7,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 12,
                    color: const Color(0x22000000),
                    margin: const EdgeInsets.only(right: 5),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 7.5, color: Color(0xFF1A1A1A)),
                    ),
                  ),
                ],
              ),
            ),
          if (s.department.isNotEmpty)
            Container(
              color: blue,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                '拍摄单位：${s.department}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 7.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required String hint,
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.border),
          ),
        ),
      ),
    );
  }

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _GroupTitle extends StatelessWidget {
  final String text;
  const _GroupTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.textSecondary,
      ),
    ),
  );
}
