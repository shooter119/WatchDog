import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';

/// Design System v3.0 页面脚手架容器。
///
/// 统一承载页面背景色（`canvas`）、可选标准 `appBar` 或自适应高度 `topBar`、
/// 离线高对比告警横幅（`cautionFill` + 深色文字 `onCaution`）、主体内容与底栏插槽。
class CommandScaffold extends StatelessWidget {
  const CommandScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.topBar,
    this.bottomNavigationBar,
    this.isOffline = false,
    this.offlineMessage = '当前处于离线状态，操作将暂存本地并在联网后自动同步',
    this.onOfflineTap,
    this.useSafeArea = true,
    this.resizeToAvoidBottomInset = true,
    this.backgroundColor,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? topBar;
  final Widget? bottomNavigationBar;
  final bool isOffline;
  final String offlineMessage;
  final VoidCallback? onOfflineTap;
  final bool useSafeArea;
  final bool resizeToAvoidBottomInset;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final showOfflineBanner = isOffline && offlineMessage.isNotEmpty;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (topBar != null) topBar!,
        if (showOfflineBanner)
          _OfflineBanner(
            message: offlineMessage,
            onTap: onOfflineTap,
          ),
        Expanded(child: body),
      ],
    );

    if (useSafeArea) {
      content = SafeArea(
        top: appBar == null,
        bottom: bottomNavigationBar == null,
        child: content,
      );
    }

    return Scaffold(
      backgroundColor: backgroundColor ?? ds.colors.canvas,
      appBar: appBar,
      body: content,
      bottomNavigationBar: bottomNavigationBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({
    required this.message,
    this.onTap,
  });

  final String message;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final fg = colors.onCaution;

    final inner = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.pageMargin,
        vertical: DsSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.warning_amber_rounded,
            size: DsSizes.iconMd,
            color: fg,
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: ds.typography.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onTap != null) ...<Widget>[
            const SizedBox(width: DsSpacing.xs),
            Icon(
              Icons.chevron_right_rounded,
              size: DsSizes.iconMd,
              color: fg,
            ),
          ],
        ],
      ),
    );

    return Semantics(
      liveRegion: true,
      button: onTap != null,
      label: message,
      child: Material(
        color: colors.cautionFill,
        child: onTap != null
            ? InkWell(onTap: onTap, child: inner)
            : inner,
      ),
    );
  }
}
