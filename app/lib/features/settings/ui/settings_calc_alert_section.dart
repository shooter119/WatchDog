import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/settings.dart';
import 'settings_widgets.dart';

/// 「计算参数」展开区：气瓶容积、满压、消耗率与提醒/报警阈值。
class SettingsCalcBody extends StatelessWidget {
  const SettingsCalcBody({
    super.key,
    required this.cylinderVolL,
    required this.onCylinderVolChanged,
    required this.fullPressureController,
    required this.consumptionController,
    required this.warnController,
    required this.alarmController,
    required this.fullPressureFocus,
    required this.consumptionFocus,
    required this.warnFocus,
    required this.alarmFocus,
    required this.onThresholdTextChanged,
  });

  final double cylinderVolL;
  final ValueChanged<double> onCylinderVolChanged;
  final TextEditingController fullPressureController, consumptionController;
  final TextEditingController warnController, alarmController;
  final FocusNode fullPressureFocus, consumptionFocus, warnFocus, alarmFocus;
  final VoidCallback onThresholdTextChanged;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SettingsGroupLabel('气瓶参数'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.md),
                child: DropdownButtonFormField<double>(
                  key: ValueKey<double>(cylinderVolL),
                  initialValue: cylinderVolL,
                  decoration: InputDecoration(
                    labelText: '气瓶容积',
                    hintText: '6.8 L',
                    filled: true,
                    fillColor: colors.surface,
                    border: border,
                    enabledBorder: border,
                  ),
                  items: <DropdownMenuItem<double>>[
                    for (final volume in Settings.allowedCylinderVolumes)
                      DropdownMenuItem<double>(
                        value: volume,
                        child: Text(
                          '${volume == 9.0 ? '9' : '6.8'} L',
                          style: ds.typography.bodyTabular.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) onCylinderVolChanged(v);
                  },
                ),
              ),
            ),
            const SizedBox(width: DsSpacing.sm),
            Expanded(
              child: _field(
                context,
                controller: fullPressureController,
                focusNode: fullPressureFocus,
                label: '满压',
                hint: '30 MPa',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
            ),
          ],
        ),
        _field(
          context,
          controller: consumptionController,
          focusNode: consumptionFocus,
          label: '消耗率',
          hint: '80 L/min',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SettingsGroupLabel('提醒阈值'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _field(
                context,
                controller: warnController,
                focusNode: warnFocus,
                label: '提醒剩余',
                hint: '10 min',
                keyboardType: TextInputType.number,
                onChanged: (_) => onThresholdTextChanged(),
              ),
            ),
            const SizedBox(width: DsSpacing.sm),
            Expanded(
              child: _field(
                context,
                controller: alarmController,
                focusNode: alarmFocus,
                label: '报警剩余',
                hint: '5 min',
                keyboardType: TextInputType.number,
                onChanged: (_) => onThresholdTextChanged(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _field(
    BuildContext context, {
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required String hint,
    required TextInputType keyboardType,
    ValueChanged<String>? onChanged,
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
        focusNode: focusNode,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: ds.typography.bodyTabular.copyWith(color: colors.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: colors.surface,
          border: border,
          enabledBorder: border,
        ),
      ),
    );
  }
}

/// 「语音识别」展开区：云端识别/解析开关与端侧离线模型管理。
class SettingsVoiceBody extends StatelessWidget {
  const SettingsVoiceBody({
    super.key,
    required this.asrCloudEnabled,
    required this.parseCloudEnabled,
    required this.hasLocalAsr,
    required this.modelInstalled,
    required this.downloadingModel,
    required this.downloadProgress,
    required this.downloadError,
    required this.onToggleAsrCloud,
    required this.onToggleParseCloud,
    required this.onDownloadModel,
    required this.onRemoveModel,
  });

  final bool asrCloudEnabled, parseCloudEnabled, hasLocalAsr, downloadingModel;
  final bool? modelInstalled;
  final double? downloadProgress;
  final String? downloadError;
  final ValueChanged<bool> onToggleAsrCloud, onToggleParseCloud;
  final VoidCallback onDownloadModel, onRemoveModel;

  @override
  Widget build(BuildContext context) {
    final divider = Divider(
      height: 1,
      indent: DsSpacing.lg,
      endIndent: DsSpacing.lg,
      color: context.ds.colors.border,
    );
    return Column(
      children: <Widget>[
        SettingsSwitchRow(
          icon: DsIcons.connOnline,
          title: '联网语音识别',
          value: asrCloudEnabled,
          onChanged: onToggleAsrCloud,
        ),
        divider,
        SettingsSwitchRow(
          icon: DsIcons.shield,
          title: '联网语义解析',
          value: parseCloudEnabled,
          onChanged: onToggleParseCloud,
        ),
        if (hasLocalAsr) ...<Widget>[divider, _buildModelTile(context)],
      ],
    );
  }

  Widget _buildModelTile(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    if (downloadingModel) {
      final pct =
          downloadProgress == null ? null : (downloadProgress! * 100).round();
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.lg,
          vertical: DsSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              pct == null ? '正在下载本地语音模型…' : '正在下载本地语音模型… $pct%',
              style: ds.typography.bodyTabular.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: DsSpacing.sm),
            LinearProgressIndicator(
              value: downloadProgress,
              minHeight: 6,
              borderRadius: DsRadius.borderSm,
            ),
          ],
        ),
      );
    }
    if (modelInstalled == null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: DsSpacing.lg),
          leading: Icon(
            DsIcons.update,
            color: colors.textTertiary,
            size: DsSizes.iconMd,
          ),
          title: Text(
            '检查本地语音模型…',
            style: ds.typography.body.copyWith(color: colors.textSecondary),
          ),
        ),
      );
    }
    if (modelInstalled!) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: DsSpacing.lg),
          leading: Icon(
            DsIcons.checkCircle,
            color: colors.safeText,
            size: DsSizes.iconMd,
          ),
          title: Text(
            '本地语音模型已就绪（离线可用）',
            style: ds.typography.body.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          trailing: TextButton(onPressed: onRemoveModel, child: const Text('删除')),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.sm,
        DsSpacing.lg,
        DsSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                DsIcons.warning,
                color: colors.cautionText,
                size: DsSizes.iconMd,
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  '本地 ASR 主模型未下载（约 75MB；另有可选的 9.8MB 降噪模型）\n下载后断网也能语音录入',
                  style: ds.typography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          if (downloadError != null) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            SettingsNoticeBanner(
              status: DsStatus.alarm,
              icon: DsIcons.warning,
              text: downloadError!,
            ),
          ],
          const SizedBox(height: DsSpacing.md),
          CommandButton(
            label: '下载本地模型',
            icon: DsIcons.download,
            variant: CommandButtonVariant.secondary,
            expanded: true,
            onPressed: onDownloadModel,
          ),
        ],
      ),
    );
  }
}

/// 「提醒方式」展开区：播报、警报音、屏幕常亮、后台值守与权限检查引导。
class SettingsAlertBody extends StatelessWidget {
  const SettingsAlertBody({
    super.key,
    required this.ttsEnabled,
    required this.alarmSoundEnabled,
    required this.keepScreenOn,
    required this.keepAliveEnabled,
    required this.exactAlarmAvailable,
    required this.policyAccessGranted,
    required this.fullScreenIntentEnabled,
    required this.onToggleTts,
    required this.onToggleAlarmSound,
    required this.onToggleKeepScreenOn,
    required this.onToggleKeepAlive,
    required this.onOpenAlarmsSettings,
    required this.onOpenPolicySettings,
    required this.onOpenNotificationSettings,
  });

  final bool ttsEnabled, alarmSoundEnabled, keepScreenOn, keepAliveEnabled;
  final bool exactAlarmAvailable, policyAccessGranted, fullScreenIntentEnabled;
  final ValueChanged<bool> onToggleTts, onToggleAlarmSound;
  final ValueChanged<bool> onToggleKeepScreenOn, onToggleKeepAlive;
  final VoidCallback onOpenAlarmsSettings, onOpenPolicySettings;
  final VoidCallback onOpenNotificationSettings;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final divider = Divider(
      height: 1,
      indent: DsSpacing.lg,
      endIndent: DsSpacing.lg,
      color: colors.border,
    );
    return Column(
      children: <Widget>[
        SettingsSwitchRow(
          icon: DsIcons.volumeUp,
          title: '语音播报',
          value: ttsEnabled,
          onChanged: onToggleTts,
        ),
        divider,
        SettingsSwitchRow(
          icon: DsIcons.alerts,
          title: '报警音',
          value: alarmSoundEnabled,
          onChanged: onToggleAlarmSound,
        ),
        divider,
        SettingsSwitchRow(
          icon: DsIcons.sun,
          title: '屏幕常亮',
          value: keepScreenOn,
          onChanged: onToggleKeepScreenOn,
        ),
        divider,
        SettingsSwitchRow(
          icon: DsIcons.moon,
          title: '后台值守模式',
          value: keepAliveEnabled,
          onChanged: onToggleKeepAlive,
        ),
        if (!keepAliveEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.lg,
              0,
              DsSpacing.lg,
              DsSpacing.md,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '开启时请允许通知与电池白名单；值守约每小时 1%–2% 电量，建议仅在处置期间开启。',
                style: ds.typography.caption.copyWith(color: colors.textTertiary),
              ),
            ),
          ),
        if (!exactAlarmAvailable)
          _permTile(
            context,
            divider,
            icon: DsIcons.alertsOff,
            title: '精确闹钟权限未开启',
            subtitle: '后台提醒可能延迟，点击去系统设置检查',
            onTap: onOpenAlarmsSettings,
          ),
        if (!policyAccessGranted)
          _permTile(
            context,
            divider,
            icon: DsIcons.forbid,
            title: '勿扰访问未开启',
            subtitle: '勿扰模式下报警提醒可能被静音',
            onTap: onOpenPolicySettings,
          ),
        if (!fullScreenIntentEnabled)
          _permTile(
            context,
            divider,
            icon: DsIcons.alerts,
            title: '全屏通知未开启',
            subtitle: '后台报警不会弹出全屏提醒',
            onTap: onOpenNotificationSettings,
          ),
      ],
    );
  }

  Widget _permTile(
    BuildContext context,
    Widget divider, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      children: <Widget>[
        divider,
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
          child: ListTile(
            dense: true,
            onTap: onTap,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.lg,
              vertical: DsSpacing.xs,
            ),
            leading: Icon(icon, color: colors.cautionText, size: DsSizes.iconMd),
            title: Text(
              title,
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: ds.typography.caption.copyWith(color: colors.cautionText),
            ),
          ),
        ),
      ],
    );
  }
}
