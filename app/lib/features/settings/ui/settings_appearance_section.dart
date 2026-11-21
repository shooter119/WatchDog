import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 界面配色方案描述（与 `Settings.appThemeId` 持久化 ID 一一对应，零旧主题依赖）。
@immutable
class DsAppearancePreset {
  const DsAppearancePreset({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.swatches,
    required this.swatchBorder,
  });

  final String id;
  final String label;
  final String subtitle;
  final List<Color> swatches;
  final Color swatchBorder;

  static const List<DsAppearancePreset> values = <DsAppearancePreset>[
    DsAppearancePreset(
      id: 'daylight',
      label: '昼白',
      subtitle: '高可视亮色',
      swatches: <Color>[
        Color(0xFFF4F6F9),
        Color(0xFFEEF2F6),
        Color(0xFF1D4ED8),
        Color(0xFFFFB000),
      ],
      swatchBorder: Color(0xFFDCE3EC),
    ),
    DsAppearancePreset(
      id: 'night-tactical',
      label: '暗曜',
      subtitle: '夜间低眩光',
      swatches: <Color>[
        Color(0xFF0B0F14),
        Color(0xFF1C2633),
        Color(0xFF3366FF),
        Color(0xFFFFB000),
      ],
      swatchBorder: Color(0xFF263344),
    ),
    DsAppearancePreset(
      id: 'system',
      label: '跟随系统',
      subtitle: '随系统切换',
      swatches: <Color>[
        Color(0xFFF4F6F9),
        Color(0xFF0B0F14),
        Color(0xFF1D4ED8),
        Color(0xFFFFB000),
      ],
      swatchBorder: Color(0xFF94A3B8),
    ),
  ];
}

/// 界面外观配色切换卡片（仅切换本机偏好，不触发设置云端同步与 `modifiedAt`）。
class SettingsAppearanceSection extends StatelessWidget {
  const SettingsAppearanceSection({
    super.key,
    required this.currentThemeId,
    required this.onSelectThemeId,
  });

  final String currentThemeId;
  final ValueChanged<String> onSelectThemeId;

  @override
  Widget build(BuildContext context) {
    final compactStack =
        MediaQuery.sizeOf(context).width < 360 &&
        MediaQuery.textScalerOf(context).scale(1.0) > 1.3;

    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: compactStack
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < DsAppearancePreset.values.length; i++) ...[
                  _AppearanceOptionTile(
                    preset: DsAppearancePreset.values[i],
                    selected: DsAppearancePreset.values[i].id == currentThemeId,
                    onTap: () =>
                        onSelectThemeId(DsAppearancePreset.values[i].id),
                  ),
                  if (i < DsAppearancePreset.values.length - 1)
                    const SizedBox(height: DsSpacing.sm),
                ],
              ],
            )
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var i = 0; i < DsAppearancePreset.values.length; i++) ...[
                    Expanded(
                      child: _AppearanceOptionTile(
                        preset: DsAppearancePreset.values[i],
                        selected:
                            DsAppearancePreset.values[i].id == currentThemeId,
                        onTap: () =>
                            onSelectThemeId(DsAppearancePreset.values[i].id),
                      ),
                    ),
                    if (i < DsAppearancePreset.values.length - 1)
                      const SizedBox(width: DsSpacing.sm),
                  ],
                ],
              ),
            ),
    );
  }
}

class _AppearanceOptionTile extends StatelessWidget {
  const _AppearanceOptionTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final DsAppearancePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      button: true,
      selected: selected,
      label: '${preset.label}配色${selected ? '，已选中' : ''}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: Key('theme-option-${preset.id}'),
        onTap: onTap,
        borderRadius: DsRadius.borderMd,
        child: AnimatedContainer(
          duration: disableAnimations
              ? Duration.zero
              : DsMotion.resolve(context, DsMotion.fast),
          constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
          padding: const EdgeInsets.all(DsSpacing.md),
          decoration: BoxDecoration(
            color: selected ? colors.surfaceMuted : colors.surface,
            borderRadius: DsRadius.borderMd,
            border: Border.all(
              color: selected ? colors.brand : colors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Wrap(
                      spacing: DsSpacing.xs,
                      runSpacing: DsSpacing.xs,
                      children: <Widget>[
                        for (final swatch in preset.swatches)
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: swatch,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: preset.swatchBorder),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (selected) ...<Widget>[
                    const SizedBox(width: DsSpacing.xs),
                    Icon(
                      Icons.check_circle_rounded,
                      size: DsSizes.iconSm,
                      color: colors.brandText,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: DsSpacing.sm),
              Text(
                preset.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ds.typography.body.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                preset.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ds.typography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
