import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/design_system.dart';
import 'shell_keys.dart';

/// Design System v3.0 游客模式常驻顶栏横幅。
///
/// 遵循现场可用性硬指标：
/// - 严格通过 `context.ds` 读取昼白/暗曜双通道语义配色，零旧主题依赖；
/// - 图标 + 文字双通道警示表达，单层 1px 细描边无厚重阴影；
/// - 「转为正式队员」操作区热区 ≥ 48dp（[DsSizes.touchTarget]）；
/// - 320~430dp 窄屏与 130% 系统字号下自适应折行，零溢出、零截断；
/// - 严格保留 [ShellKeys.guestBanner] 与既有 [ShellKeys.guestConvertBtn]。
class GuestBannerBar extends StatelessWidget {
  const GuestBannerBar({
    super.key = ShellKeys.guestBanner,
    required this.onConvert,
    this.message = '游客模式（数据仅保存在本机）',
    this.actionLabel = '转为正式队员',
    this.safeAreaTop = true,
  });

  final VoidCallback onConvert;
  final String message;
  final String actionLabel;
  final bool safeAreaTop;

  void _handleConvertTap() {
    HapticFeedback.lightImpact();
    onConvert();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final caution = colors.statusColors(DsStatus.caution);
    final bannerBg = Color.alphaBlend(caution.pillBg, colors.surface);
    final borderColor = caution.fill.withValues(alpha: 0.42);

    final Widget actionButton = Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: DsRadius.borderSm,
        side: BorderSide(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ShellKeys.guestConvertBtn,
        onTap: _handleConvertTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: DsSizes.touchTarget,
            minWidth: DsSizes.touchTarget,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.md,
              vertical: DsSpacing.sm,
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                actionLabel,
                textAlign: TextAlign.center,
                style: ds.typography.caption.copyWith(
                  color: caution.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final Widget banner = Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.md,
        DsSpacing.sm,
        DsSpacing.md,
        DsSpacing.xs,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bannerBg,
          borderRadius: DsRadius.borderMd,
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.md,
            vertical: DsSpacing.xs,
          ),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Widget leading = Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.shield_outlined,
                    size: DsSizes.iconMd,
                    color: caution.text,
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  Flexible(
                    child: Text(
                      message,
                      style: ds.typography.caption.copyWith(
                        color: caution.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              );

              if (constraints.maxWidth < 260) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    leading,
                    const SizedBox(height: DsSpacing.xs),
                    Align(
                      alignment: Alignment.centerRight,
                      child: actionButton,
                    ),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(child: leading),
                  const SizedBox(width: DsSpacing.sm),
                  actionButton,
                ],
              );
            },
          ),
        ),
      ),
    );

    if (!safeAreaTop) return banner;
    return SafeArea(bottom: false, child: banner);
  }
}
