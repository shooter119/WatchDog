import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/settings.dart';
import '../../../services/watermark_settings.dart';
import 'settings_widgets.dart';
import 'watermark_preview_card.dart';

/// 水印相机设置页（Design System v3.0）。
///
/// 单位抬头、拍摄单位、拍摄人均可独立配置，与登录身份解耦；
/// 输入变更 500ms 防抖落盘，开关与方向切换即时落盘，退出或销毁前冲刷 `_pendingSave`。
class WatermarkSettingsPage extends StatefulWidget {
  const WatermarkSettingsPage({super.key});

  @override
  State<WatermarkSettingsPage> createState() => _WatermarkSettingsPageState();
}

class _WatermarkSettingsPageState extends State<WatermarkSettingsPage> {
  final TextEditingController _unitTitle = TextEditingController();
  final TextEditingController _department = TextEditingController();
  final TextEditingController _actor = TextEditingController();

  WatermarkSettings _settings = WatermarkSettings.defaults;
  bool _loading = true;
  bool _dirty = false;
  bool _leaving = false;
  int _revision = 0;
  Timer? _saveTimer;
  Future<void> _pendingSave = Future<void>.value();
  String _unitName = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty) {
      unawaited(_save(showFailureSnack: false));
    }
    _unitTitle.dispose();
    _department.dispose();
    _actor.dispose();
    super.dispose();
  }

  void _changed({bool immediate = false}) {
    setState(() {
      _dirty = true;
      _revision++;
    });
    _saveTimer?.cancel();
    if (immediate) {
      unawaited(_save());
    } else {
      _saveTimer = Timer(const Duration(milliseconds: 500), () {
        unawaited(_save());
      });
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _saveTimer?.cancel();
    if (_dirty) await _save();
    await _pendingSave;
    if (!mounted) return;
    _leaving = false;
    if (_dirty) return;
    Navigator.of(context).pop();
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

  Future<void> _save({bool showFailureSnack = true}) {
    _saveTimer?.cancel();
    final next = _settings.copyWith(
      unitTitle: _unitTitle.text.trim(),
      department: _department.text.trim(),
      actorName: _actor.text.trim(),
    );
    _dirty = false;
    final revision = _revision;
    final previous = _pendingSave;
    _pendingSave = () async {
      await previous;
      try {
        await WatermarkSettings.save(next);
      } catch (_) {
        if (revision == _revision) _dirty = true;
        if (showFailureSnack && mounted && revision == _revision) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('水印设置保存失败，请返回重试')),
          );
        }
      }
    }();
    return _pendingSave;
  }

  @override
  Widget build(BuildContext context) {
    final previewSettings = _settings.copyWith(
      unitTitle: _unitTitle.text.trim(),
      department: _department.text.trim(),
      actorName: _actor.text.trim(),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: CommandScaffold(
        appBar: AppBar(
          title: const Text('水印设置'),
          leading: BackButton(onPressed: () => unawaited(_leave())),
        ),
        body: _loading
            ? const StatePlaceholder.loading(message: '正在加载水印配置…')
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  DsSpacing.pageMargin,
                  DsSpacing.md,
                  DsSpacing.pageMargin,
                  DsSpacing.xxl,
                ),
                children: <Widget>[
                  WatermarkPreviewCard(
                    settings: previewSettings,
                    fallbackUnitName: _unitName,
                  ),
                  const SizedBox(height: DsSpacing.xl),
                  const SettingsSectionTitle(text: '水印内容'),
                  _textField(
                    controller: _unitTitle,
                    label: '单位抬头',
                    hint: '例如：示例省总队示例市消防救援支队',
                    helper: '水印顶部蓝条的单位名称；留空使用当前登录单位名称',
                  ),
                  _textField(
                    controller: _department,
                    label: '拍摄单位',
                    hint: '例如：示例市消防救援支队通信保障分队',
                    helper: '水印底部蓝条的拍摄班组或部门；留空不显示',
                  ),
                  _textField(
                    controller: _actor,
                    label: '拍摄人',
                    hint: '留空则不显示',
                    helper: '水印正文中的人员署名；留空不显示，不改变登录姓名',
                  ),
                  const SizedBox(height: DsSpacing.xl),
                  const SettingsSectionTitle(text: '显示字段'),
                  _buildFieldSwitches(),
                  const SizedBox(height: DsSpacing.xl),
                  const SettingsSectionTitle(text: '拍摄界面方向'),
                  _buildOrientationPicker(),
                ],
              ),
      ),
    );
  }

  Widget _buildFieldSwitches() {
    final colors = context.ds.colors;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          _switchTile(
            title: '拍摄时间',
            value: _settings.showTime,
            onChanged: (v) {
              _settings = _settings.copyWith(showTime: v);
              _changed(immediate: true);
            },
          ),
          Divider(
            height: 1,
            indent: DsSpacing.lg,
            endIndent: DsSpacing.lg,
            color: colors.border,
          ),
          _switchTile(
            title: '天气',
            value: _settings.showWeather,
            onChanged: (v) {
              _settings = _settings.copyWith(showWeather: v);
              _changed(immediate: true);
            },
          ),
          Divider(
            height: 1,
            indent: DsSpacing.lg,
            endIndent: DsSpacing.lg,
            color: colors.border,
          ),
          _switchTile(
            title: '地点',
            value: _settings.showLocation,
            onChanged: (v) {
              _settings = _settings.copyWith(showLocation: v);
              _changed(immediate: true);
            },
          ),
          Divider(
            height: 1,
            indent: DsSpacing.lg,
            endIndent: DsSpacing.lg,
            color: colors.border,
          ),
          _switchTile(
            title: '经纬度',
            value: _settings.showCoordinates,
            onChanged: (v) {
              _settings = _settings.copyWith(showCoordinates: v);
              _changed(immediate: true);
            },
          ),
          Divider(
            height: 1,
            indent: DsSpacing.lg,
            endIndent: DsSpacing.lg,
            color: colors.border,
          ),
          _switchTile(
            title: '左侧标识',
            subtitle: '关闭后只保留文字，适合不对外发布的内部记录',
            value: _settings.showLogo,
            onChanged: (v) {
              _settings = _settings.copyWith(showLogo: v);
              _changed(immediate: true);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOrientationPicker() {
    return RadioGroup<CameraCaptureOrientation>(
      groupValue: _settings.captureOrientation,
      onChanged: (value) {
        if (value == null || value == _settings.captureOrientation) return;
        _settings = _settings.copyWith(captureOrientation: value);
        _changed(immediate: true);
      },
      child: Column(
        children: <Widget>[
          _orientationTile(
            key: const Key('capture-orientation-landscape'),
            value: CameraCaptureOrientation.landscape,
            title: '横屏拍摄（16:9）',
            subtitle: '自动横屏，保留完整横版视野',
          ),
          const SizedBox(height: DsSpacing.sm),
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
    final ds = context.ds;
    final colors = ds.colors;
    final selected = _settings.captureOrientation == value;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      borderRadius: DsRadius.borderMd,
      borderColor: selected ? colors.brand : colors.border,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: RadioListTile<CameraCaptureOrientation>(
          key: key,
          value: value,
          selected: selected,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.lg,
            vertical: DsSpacing.sm,
          ),
          activeColor: colors.brand,
          title: Text(
            title,
            style: ds.typography.body.copyWith(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          subtitle: subtitle == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: DsSpacing.xs),
                  child: Text(
                    subtitle,
                    style: ds.typography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
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
    final ds = context.ds;
    final colors = ds.colors;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: TextField(
        controller: controller,
        onChanged: (_) => _changed(),
        minLines: 1,
        maxLines: null,
        style: ds.typography.body.copyWith(color: colors.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 6,
          hintMaxLines: 4,
          helperStyle: ds.typography.caption.copyWith(
            color: colors.textSecondary,
          ),
          filled: true,
          fillColor: colors.surface,
          border: border,
          enabledBorder: border,
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
    final ds = context.ds;
    final colors = ds.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: DsSizes.primaryAction),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.lg,
          vertical: 2,
        ),
        title: Text(
          title,
          style: ds.typography.body.copyWith(
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: DsSpacing.xs),
                child: Text(
                  subtitle,
                  style: ds.typography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
        value: value,
        activeThumbColor: colors.onBrand,
        activeTrackColor: colors.brand,
        inactiveThumbColor: colors.textSecondary,
        inactiveTrackColor: colors.surface,
        trackOutlineColor: WidgetStatePropertyAll<Color>(colors.textSecondary),
        onChanged: onChanged,
      ),
    );
  }
}
