import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 认证模块通用 DS v3.0 输入框装饰（配合 [AuthLabeledField] 框外顶部标签使用）。
InputDecoration authInputDecoration(
  BuildContext context, {
  required String hint,
  required IconData icon,
  Widget? suffixIcon,
}) {
  final ds = context.ds;
  final colors = ds.colors;
  final border = OutlineInputBorder(
    borderRadius: DsRadius.borderMd,
    borderSide: BorderSide(color: colors.border),
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: ds.typography.body.copyWith(color: colors.textTertiary),
    prefixIcon: Icon(icon, size: DsSizes.iconMd, color: colors.textTertiary),
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: colors.surfaceMuted,
    counterText: '',
    contentPadding: const EdgeInsets.symmetric(
      horizontal: DsSpacing.md,
      vertical: DsSpacing.md + 2,
    ),
    border: border,
    enabledBorder: border,
    focusedBorder: OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.brand, width: 1.5),
    ),
  );
}

/// 认证表单字段容器：框外顶部固定标签 + 灰底描边输入框，
/// 避免 Material 浮动标签骑在灰白交界线上造成的视觉截断。
class AuthLabeledField extends StatelessWidget {
  const AuthLabeledField({
    super.key,
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: DsSpacing.xs + 2),
          child: Text(
            label,
            style: ds.typography.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 认证与扫码模块统一的高对比语义提示横幅（图标 + 文字双通道）。
class AuthNoticeBanner extends StatelessWidget {
  const AuthNoticeBanner({
    super.key,
    required this.message,
    this.status = DsStatus.alarm,
    this.icon,
  });

  final String message;
  final DsStatus status;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final pair = colors.statusColors(status);
    final isNeutral = status == DsStatus.neutral;
    final fg = isNeutral ? colors.textSecondary : pair.text;
    final iconColor = isNeutral ? colors.brandText : pair.text;
    final resolvedIcon =
        icon ??
        switch (status) {
          DsStatus.alarm || DsStatus.timeout => DsIcons.warning,
          DsStatus.caution => DsIcons.idCard,
          DsStatus.safe => DsIcons.checkCircle,
          DsStatus.neutral => DsIcons.lightbulb,
        };

    return SurfaceCard(
      level: isNeutral ? DsSurfaceLevel.flat : DsSurfaceLevel.outlined,
      accentStatus: isNeutral ? null : status,
      backgroundColor: isNeutral ? colors.surfaceMuted : pair.pillBg,
      borderColor: isNeutral ? colors.border : pair.fill.withValues(alpha: 0.4),
      padding: const EdgeInsets.all(DsSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(resolvedIcon, size: DsSizes.iconMd, color: iconColor),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: ds.typography.body.copyWith(
                color: status == DsStatus.caution ? colors.textPrimary : fg,
                fontWeight: status == DsStatus.alarm
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 认证、待审、扫码确认页统一顶部图标徽章与双通道状态胶囊行。
class AuthHeaderBadgeRow extends StatelessWidget {
  const AuthHeaderBadgeRow({
    super.key,
    required this.icon,
    required this.pillLabel,
    this.pillIcon,
    this.pillStatus = DsStatus.neutral,
    this.useCautionIconTone = false,
  });

  final IconData icon;
  final String pillLabel;
  final IconData? pillIcon;
  final DsStatus pillStatus;
  final bool useCautionIconTone;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final caution = colors.statusColors(DsStatus.caution);
    final bg = useCautionIconTone
        ? caution.pillBg
        : Color.alphaBlend(colors.brand.withValues(alpha: 0.12), colors.surface);
    final border = useCautionIconTone
        ? caution.fill.withValues(alpha: 0.36)
        : colors.brand.withValues(alpha: 0.28);
    final fg = useCautionIconTone ? caution.text : colors.brandText;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: DsRadius.borderMd,
            border: Border.all(color: border),
          ),
          child: Icon(icon, size: DsSizes.iconLg, color: fg),
        ),
        const SizedBox(width: DsSpacing.md),
        Flexible(
          child: StatusPill(
            status: pillStatus,
            icon: pillIcon,
            label: pillLabel,
          ),
        ),
      ],
    );
  }
}

/// 认证页模糊姓名候选项内联提示胶囊条。
class AuthSuggestionChips extends StatelessWidget {
  const AuthSuggestionChips({
    super.key,
    required this.suggestions,
    required this.enabled,
    required this.onSelected,
  });

  final List<String> suggestions;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Padding(
      padding: const EdgeInsets.only(top: DsSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '相近队员姓名（点击填入）：',
            style: ds.typography.caption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: DsSpacing.xs),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.sm,
            children: <Widget>[
              for (final candidate in suggestions)
                ActionChip(
                  key: ValueKey<String>('auth-suggestion-$candidate'),
                  avatar: Icon(
                    DsIcons.user,
                    size: DsSizes.iconSm,
                    color: colors.brandText,
                  ),
                  label: Text(
                    candidate,
                    style: ds.typography.caption.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  backgroundColor: colors.surfaceMuted,
                  side: BorderSide(color: colors.border),
                  shape: const RoundedRectangleBorder(
                    borderRadius: DsRadius.borderPill,
                  ),
                  onPressed: enabled ? () => onSelected(candidate) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
