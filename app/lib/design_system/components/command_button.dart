import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';
import 'command_sheet.dart';

/// 按钮语义变体。
enum CommandButtonVariant {
  /// 品牌实心主操作（`brand` + `onBrand`）
  primary,

  /// 次级表面操作（`surfaceMuted` + `textPrimary` + 1px `border`）
  secondary,

  /// 透明幽灵操作（文本/图标采用高对比 `brandText`）
  ghost,

  /// 危险不可逆操作（`alarmFill` + `onAlarm`，默认触发二次确认弹窗）
  danger,
}

/// 按钮触控尺寸档位。
enum CommandButtonSize {
  /// 常规操作（最小高度 48dp）
  standard,

  /// 主操作/紧急操作（最小高度 56dp）
  large,
}

/// Design System v3.0 指挥操作按钮。
///
/// 适配消防手套触控规范（48dp / 56dp），支持保持高度不变的加载态、禁用态、
/// 暗曜高对比幽灵色（`brandText`），以及 `danger` 变体默认弹出 [CommandSheet] 二次确认。
class CommandButton extends StatelessWidget {
  const CommandButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = CommandButtonVariant.primary,
    this.size = CommandButtonSize.standard,
    this.icon,
    this.enabled = true,
    this.isLoading = false,
    this.expanded = false,
    this.requireConfirmation = true,
    this.confirmTitle,
    this.confirmMessage,
    this.confirmActionLabel,
    this.cancelActionLabel = '取消',
  });

  final String label;
  final VoidCallback? onPressed;
  final CommandButtonVariant variant;
  final CommandButtonSize size;
  final IconData? icon;
  final bool enabled;
  final bool isLoading;
  final bool expanded;
  final bool requireConfirmation;
  final String? confirmTitle;
  final String? confirmMessage;
  final String? confirmActionLabel;
  final String cancelActionLabel;

  Future<void> _handleTap(BuildContext context) async {
    if (!enabled || onPressed == null || isLoading) return;

    if (variant == CommandButtonVariant.danger && requireConfirmation) {
      HapticFeedback.mediumImpact();
      final confirmed = await showCommandSheet<bool>(
        context: context,
        title: confirmTitle ?? '确认$label',
        builder: (BuildContext sheetContext) {
          final sheetDs = sheetContext.ds;
          return Text(
            confirmMessage ?? '即将执行“$label”，该操作将立即生效，请确认后继续。',
            style: sheetDs.typography.body.copyWith(
              color: sheetDs.colors.textSecondary,
            ),
          );
        },
        actionsBuilder: (BuildContext sheetContext) => <Widget>[
          CommandButton(
            label: cancelActionLabel,
            variant: CommandButtonVariant.secondary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(sheetContext).pop(false),
          ),
          CommandButton(
            label: confirmActionLabel ?? '确认$label',
            variant: CommandButtonVariant.danger,
            size: CommandButtonSize.large,
            requireConfirmation: false,
            onPressed: () => Navigator.of(sheetContext).pop(true),
          ),
        ],
      );
      if (confirmed == true) {
        onPressed?.call();
      }
      return;
    }

    HapticFeedback.selectionClick();
    onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final double minHeight = size == CommandButtonSize.large
        ? DsSizes.primaryAction
        : DsSizes.touchTarget;

    final bool isDisabled = !enabled || onPressed == null;
    final bool isInteractive = !isDisabled && !isLoading;
    final bool disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    final Color bg;
    final Color fg;
    final BorderSide side;

    if (isDisabled) {
      bg = variant == CommandButtonVariant.ghost
          ? Colors.transparent
          : colors.surfaceMuted;
      fg = colors.textTertiary;
      side = variant == CommandButtonVariant.secondary
          ? BorderSide(color: colors.border, width: 1)
          : BorderSide.none;
    } else {
      switch (variant) {
        case CommandButtonVariant.primary:
          bg = colors.brand;
          fg = colors.onBrand;
          side = BorderSide.none;
        case CommandButtonVariant.secondary:
          bg = colors.surfaceMuted;
          fg = colors.textPrimary;
          side = BorderSide(color: colors.border, width: 1);
        case CommandButtonVariant.ghost:
          bg = Colors.transparent;
          fg = colors.brandText;
          side = BorderSide.none;
        case CommandButtonVariant.danger:
          bg = colors.alarmFill;
          fg = colors.onAlarm;
          side = BorderSide.none;
      }
    }

    Widget? leading;
    if (isLoading) {
      leading = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          value: disableAnimations ? 0.72 : null,
          strokeWidth: 2.2,
          color: fg,
        ),
      );
    } else if (icon != null) {
      leading = Icon(icon, size: DsSizes.iconMd, color: fg);
    }

    Widget buttonChild = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: minHeight,
        minWidth: DsSizes.touchTarget,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.md,
          vertical: DsSpacing.sm,
        ),
        child: Center(
          widthFactor: expanded ? null : 1.0,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading,
                const SizedBox(width: DsSpacing.sm),
              ],
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: ds.typography.title.copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final Widget materialButton = Semantics(
      button: true,
      enabled: isInteractive,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: bg,
        type: bg == Colors.transparent
            ? MaterialType.transparency
            : MaterialType.canvas,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderMd,
          side: side,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: DsRadius.borderMd,
          onTap: isInteractive ? () => _handleTap(context) : null,
          child: buttonChild,
        ),
      ),
    );

    if (expanded) {
      return SizedBox(width: double.infinity, child: materialButton);
    }

    return materialButton;
  }
}
