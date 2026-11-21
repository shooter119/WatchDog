import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/settings_store.dart';

/// 设置页分区标题。
class SettingsSectionTitle extends StatelessWidget {
  const SettingsSectionTitle({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(left: DsSpacing.xs, bottom: DsSpacing.sm),
      child: Text(
        text,
        style: ds.typography.caption.copyWith(
          color: ds.colors.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 卡片内子分组小标题（如「气瓶参数」「提醒阈值」）。
class SettingsGroupLabel extends StatelessWidget {
  const SettingsGroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(top: DsSpacing.xs, bottom: DsSpacing.sm),
      child: Text(
        text,
        style: ds.typography.caption.copyWith(
          color: ds.colors.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 分组圆角卡片容器：同组条目共用一张 1px 细描边 `SurfaceCard`。
class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < children.length; i++) ...<Widget>[
            children[i],
            if (i < children.length - 1)
              Divider(height: 1, thickness: 1, indent: 64, endIndent: DsSpacing.lg, color: colors.border),
          ],
        ],
      ),
    );
  }
}

/// 统一图标容器（带可选角标点）。
class SettingsIconBox extends StatelessWidget {
  const SettingsIconBox({super.key, required this.icon, this.badge = false});
  final IconData icon;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: colors.surfaceMuted, borderRadius: DsRadius.borderSm),
            child: Icon(icon, size: 18, color: colors.textPrimary),
          ),
          if (badge)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colors.brand,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 跳转二级页面的设置条目（统一右侧 `chevron_right_rounded` 与 ≥48dp 触控热区）。
class SettingsNavRow extends StatelessWidget {
  const SettingsNavRow({
    super.key,
    this.rowKey,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.trailingHighlight = false,
    required this.onTap,
    this.enabled = true,
    this.badge = false,
  });

  final Key? rowKey;
  final IconData icon;
  final String title;
  final String? subtitle, trailingText;
  final bool trailingHighlight, enabled, badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final compactScale = MediaQuery.textScalerOf(context).scale(1.0) > 1.35;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        key: rowKey ?? Key('settings-row-$title'),
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: DsSpacing.lg, vertical: 10),
            child: Row(
              children: <Widget>[
                SettingsIconBox(icon: icon, badge: badge),
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: ds.typography.body.copyWith(fontWeight: FontWeight.w700, color: colors.textPrimary),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ds.typography.caption.copyWith(color: colors.textTertiary),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailingText != null && trailingText!.isNotEmpty) ...<Widget>[
                  const SizedBox(width: DsSpacing.sm),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compactScale ? 110 : 148),
                    child: Text(
                      trailingText!,
                      maxLines: compactScale ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: ds.typography.captionTabular.copyWith(
                        fontWeight: trailingHighlight ? FontWeight.w700 : FontWeight.w600,
                        color: trailingHighlight ? colors.brandText : colors.textSecondary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: DsSpacing.xs),
                Icon(Icons.chevron_right_rounded, size: DsSizes.iconMd, color: colors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 组内可折叠设置条目：右侧显示摘要与圆形展开指示器。
class SettingsExpandRow extends StatelessWidget {
  const SettingsExpandRow({
    super.key,
    required this.icon,
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final IconData icon;
  final String title, summary;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final compactScale = MediaQuery.textScalerOf(context).scale(1.0) > 1.35;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          container: true,
          button: true,
          excludeSemantics: true,
          expanded: expanded,
          label: '$title，$summary，${expanded ? '已展开' : '已收起'}',
          hint: expanded ? '点击收起设置' : '点击展开设置',
          onTap: onToggle,
          child: InkWell(
            key: Key('settings-row-$title'),
            excludeFromSemantics: true,
            onTap: onToggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DsSpacing.lg, vertical: 10),
                child: Row(
                  children: <Widget>[
                    SettingsIconBox(icon: icon),
                    const SizedBox(width: DsSpacing.md),
                    Expanded(
                      child: Text(
                        title,
                        style: ds.typography.body.copyWith(fontWeight: FontWeight.w700, color: colors.textPrimary),
                      ),
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: compactScale ? 110 : 148),
                      child: Text(
                        summary,
                        maxLines: compactScale ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: ds.typography.captionTabular.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: expanded ? colors.brand.withValues(alpha: 0.12) : colors.surfaceMuted,
                      ),
                      child: Icon(
                        expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: expanded ? colors.brandText : colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (disableAnimations)
          if (expanded)
            _expandedBody(colors)
          else
            const SizedBox.shrink()
        else
          AnimatedCrossFade(
            duration: DsMotion.resolve(context, DsMotion.fast),
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeIn,
            sizeCurve: Curves.easeOut,
            crossFadeState: expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: _expandedBody(colors),
            secondChild: const SizedBox(width: double.infinity),
          ),
      ],
    );
  }

  Widget _expandedBody(DsColors colors) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Divider(
        height: 1,
        indent: DsSpacing.lg,
        endIndent: DsSpacing.lg,
        color: colors.border.withValues(alpha: 0.6),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(DsSpacing.lg, DsSpacing.md, DsSpacing.lg, DsSpacing.lg),
        child: child,
      ),
    ],
  );
}

/// 统一开关条目（≥56dp 触控高度，即时持久化）。
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: DsSizes.primaryAction),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: DsSpacing.lg, vertical: 2),
        secondary: Icon(icon, size: DsSizes.iconMd, color: colors.textSecondary),
        title: Text(
          title,
          style: ds.typography.body.copyWith(fontWeight: FontWeight.w700, color: colors.textPrimary),
        ),
        subtitle: subtitle == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: DsSpacing.xs),
                child: Text(subtitle!, style: ds.typography.caption.copyWith(color: colors.textSecondary)),
              ),
        activeThumbColor: colors.brand,
        activeTrackColor: colors.brand.withValues(alpha: 0.28),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// 失焦自动保存状态轻量提示徽标。
class SettingsSaveStatusBadge extends StatelessWidget {
  const SettingsSaveStatusBadge({super.key, required this.state});
  final SettingsSaveState state;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return switch (state) {
      SettingsSaveState.idle => const SizedBox.shrink(),
      SettingsSaveState.saving => _badge(
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: disableAnimations ? 0.65 : null,
            color: colors.brandText,
          ),
        ),
        '保存中',
        colors.textTertiary,
        ds,
      ),
      SettingsSaveState.saved => _badge(
        Icon(Icons.check_circle_outline, size: 14, color: colors.safeText),
        '已保存',
        colors.safeText,
        ds,
      ),
      SettingsSaveState.failed => _badge(
        Icon(Icons.error_outline, size: 14, color: colors.alarmText),
        '保存失败',
        colors.alarmText,
        ds,
      ),
    };
  }

  Widget _badge(Widget leading, String label, Color color, DsTheme ds) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      leading,
      const SizedBox(width: DsSpacing.xs),
      Text(label, style: ds.typography.caption.copyWith(color: color, fontWeight: FontWeight.w600)),
    ],
  );
}

/// 语义提示条（用于同步提示、下载异常等内联反馈）。
class SettingsNoticeBanner extends StatelessWidget {
  const SettingsNoticeBanner({
    super.key,
    required this.status,
    required this.icon,
    required this.text,
    this.title,
  });

  final DsStatus status;
  final IconData icon;
  final String? title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pair = ds.colors.statusColors(status);
    return Container(
      padding: const EdgeInsets.all(DsSpacing.md),
      decoration: BoxDecoration(
        color: pair.pillBg,
        borderRadius: DsRadius.borderSm,
        border: Border.all(color: pair.fill.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: pair.text),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null && title!.isNotEmpty) ...<Widget>[
                  Text(title!, style: ds.typography.caption.copyWith(color: pair.text, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                ],
                Text(text, style: ds.typography.caption.copyWith(color: ds.colors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
