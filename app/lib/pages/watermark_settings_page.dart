import 'package:flutter/material.dart';

import '../services/watermark_settings.dart';
import '../services/settings.dart';
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
  bool _dirty = false;
  bool _saving = false;
  String _unitName = '';

  void _changed() => setState(() => _dirty = true);

  Future<void> _leave() async {
    if (_saving) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('水印设置尚未保存'),
        content: const Text('保存后下次拍摄生效，是否保存本次修改？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('保存并离开'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'save') {
      await _save();
      if (_dirty || !mounted) return;
    }
    setState(() => _dirty = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

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
    final unitName = await Settings.unitName;
    if (!mounted) return;
    setState(() {
      _unitName = unitName;
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
    setState(() => _saving = true);
    try {
      await WatermarkSettings.save(next);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _settings = next;
      _dirty = false;
      _saving = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('水印设置已保存，下次拍摄生效')));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('水印设置'),
          leading: BackButton(
            onPressed: () {
              if (_saving) return;
              if (_dirty) {
                _leave();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: _loading || _saving ? null : _save,
              child: const Text('保存'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
                children: [
                  _previewCard(),
                  const SizedBox(height: 18),
                  const SectionTitle(text: '水印内容'),
                  _textField(
                    controller: _unitTitle,
                    label: '单位抬头',
                    hint: '例如：浙江总队衢州市消防救援支队',
                    helper: '水印顶部蓝条的单位名称；留空使用当前登录单位名称',
                  ),
                  _textField(
                    controller: _department,
                    label: '拍摄单位',
                    hint: '例如：衢州市消防救援支队通信保障分队',
                    helper: '水印底部蓝条的拍摄班组或部门；留空不显示',
                  ),
                  _textField(
                    controller: _actor,
                    label: '拍摄人',
                    hint: '留空则不显示',
                    helper: '水印正文中的人员署名；留空不显示，不改变登录姓名',
                  ),
                  const SizedBox(height: 18),
                  const SectionTitle(text: '显示字段'),
                  _switchTile(
                    title: '拍摄时间',
                    value: _settings.showTime,
                    onChanged: (v) => setState(() {
                      _dirty = true;
                      _settings = _settings.copyWith(showTime: v);
                    }),
                  ),
                  _switchTile(
                    title: '天气',
                    value: _settings.showWeather,
                    onChanged: (v) => setState(() {
                      _dirty = true;
                      _settings = _settings.copyWith(showWeather: v);
                    }),
                  ),
                  _switchTile(
                    title: '地点',
                    value: _settings.showLocation,
                    onChanged: (v) => setState(() {
                      _dirty = true;
                      _settings = _settings.copyWith(showLocation: v);
                    }),
                  ),
                  _switchTile(
                    title: '经纬度',
                    value: _settings.showCoordinates,
                    onChanged: (v) => setState(() {
                      _dirty = true;
                      _settings = _settings.copyWith(showCoordinates: v);
                    }),
                  ),
                  _switchTile(
                    title: '左侧标识',
                    subtitle: '关闭后只保留文字，适合不对外发布的内部记录',
                    value: _settings.showLogo,
                    onChanged: (v) => setState(() {
                      _dirty = true;
                      _settings = _settings.copyWith(showLogo: v);
                    }),
                  ),
                  const SizedBox(height: 18),
                  const SectionTitle(text: '拍摄界面方向'),
                  _orientationPicker(),
                ],
              ),
      ),
    );
  }

  Widget _previewCard() {
    final preview = _settings.copyWith(
      // 留空时回落到真实的单位名称；两者都没有时给明确占位，
      // 不能留一片空白让人以为预览坏了。
      unitTitle: _unitTitle.text.trim().isEmpty
          ? (_unitName.trim().isEmpty ? '未填写单位抬头' : _unitName.trim())
          : _unitTitle.text.trim(),
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
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: const LinearGradient(
                colors: [Color(0xFF8FA6B8), Color(0xFF43535F)],
              ),
            ),
            child: _previewCardBody(preview),
          ),
        ],
      ),
    );
  }

  Widget _previewCardBody(WatermarkSettings s) {
    // 设置预览使用深蓝实底，保证白色小字对比度；字段与拍摄配置保持一致。
    const watermarkBlue = Color(0xFF24569A);
    final rows = <(String, String)>[
      if (s.showTime) ('拍摄\r\n时间', '2026.10.18 星期日 08:39'),
      if (s.showWeather) ('天气', '晴 21℃ 东南风2级 湿度87%'),
      if (s.showLocation) ('地点', '衢州市 · 某某有限公司'),
      if (s.showCoordinates) ('经度', '东经 118°22′'),
      if (s.showCoordinates) ('纬度', '北纬 29°0′'),
      if (s.actorName.isNotEmpty) ('拍摄人', s.actorName),
    ];
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0x9EFFFFFF),
        borderRadius: BorderRadius.circular(5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: watermarkBlue,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: [
                if (s.showLogo)
                  Container(
                    width: 18,
                    height: 18,
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    // 与原生水印使用同一张队徽资源，预览不再用通用盾形图标冒充。
                    child: Image.asset(
                      'assets/branding/fire_rescue_badge.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      semanticLabel: '中国消防救援队徽',
                    ),
                  ),
                Expanded(
                  child: Text(
                    s.unitTitle,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
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
                    width: 48,
                    child: Text(
                      row.$1,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (s.department.isNotEmpty)
            Container(
              color: watermarkBlue,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              // 底条字号与正文一致；只把「拍摄单位：」加粗，与原生底条对应。
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text: '拍摄单位：',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: s.department,
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _orientationPicker() {
    return RadioGroup<CameraCaptureOrientation>(
      groupValue: _settings.captureOrientation,
      onChanged: (value) {
        if (_saving ||
            value == null ||
            value == _settings.captureOrientation) {
          return;
        }
        setState(() {
          _dirty = true;
          _settings = _settings.copyWith(captureOrientation: value);
        });
      },
      child: Column(
        children: [
          _orientationTile(
            key: const Key('capture-orientation-landscape'),
            value: CameraCaptureOrientation.landscape,
            title: '横屏拍摄（16:9）',
            subtitle: '自动横屏，保留完整横版视野',
          ),
          const SizedBox(height: 8),
          _orientationTile(
            key: const Key('capture-orientation-portrait'),
            value: CameraCaptureOrientation.portrait,
            title: '竖屏拍摄（16:9中心裁切）',
            subtitle: '锁定竖直，成片会裁掉上下视野',
          ),
        ],
      ),
    );
  }

  Widget _orientationTile({
    required Key key,
    required CameraCaptureOrientation value,
    required String title,
    String? subtitle,
  }) {
    final selected = _settings.captureOrientation == value;
    return RadioListTile<CameraCaptureOrientation>(
      key: key,
      value: value,
      enabled: !_saving,
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? AppColors.voice : AppColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      tileColor: selected ? AppColors.surface : Colors.transparent,
      activeColor: AppColors.voice,
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
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
        enabled: !_saving,
        onChanged: (_) => _changed(),
        minLines: 1,
        maxLines: null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 6,
          hintMaxLines: 4,
          helperStyle: TextStyle(color: AppColors.textSecondary),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.textSecondary),
          ),
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.border),
          ),
        ),
      ),
    );
  }

  Widget _switchTile({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          title,
          style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
        value: value,
        activeThumbColor: AppColors.textPrimary,
        activeTrackColor: AppColors.voice,
        inactiveThumbColor: AppColors.textSecondary,
        inactiveTrackColor: AppColors.surface,
        trackOutlineColor: WidgetStatePropertyAll(AppColors.textSecondary),
        onChanged: _saving ? null : onChanged,
      ),
    );
  }
}
