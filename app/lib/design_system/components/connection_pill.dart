import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_icons.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_spacing.dart';

/// 现场网络与离线同步状态。
enum DsConnectionState {
  /// 已连接实时同步
  online,

  /// 正在重连
  reconnecting,

  /// 离线（可展示待补传操作数）
  offline,
}

/// Design System v3.0 顶部连接状态胶囊。
///
/// 强制同时显示状态图标与文字标签，支持自适应高度与可选点击动作。
class ConnectionPill extends StatelessWidget {
  const ConnectionPill({
    super.key,
    required this.state,
    this.pendingCount = 0,
    this.onTap,
  });

  final DsConnectionState state;
  final int pendingCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    final (DsStatus status, IconData icon, String label) = switch (state) {
      DsConnectionState.online => (
          DsStatus.safe,
          DsIcons.connOnline,
          '在线',
        ),
      DsConnectionState.reconnecting => (
          DsStatus.caution,
          DsIcons.connReconnecting,
          '重连中',
        ),
      DsConnectionState.offline => (
          DsStatus.alarm,
          DsIcons.connOffline,
          pendingCount > 0 ? '离线 · 待补传 $pendingCount' : '离线',
        ),
    };

    final pair = colors.statusColors(status);

    Widget pill = Container(
      constraints: const BoxConstraints(minHeight: 26),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm,
        vertical: DsSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: pair.pillBg,
        borderRadius: DsRadius.borderPill,
        border: Border.all(
          color: pair.fill.withValues(alpha: 0.28),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 14, color: pair.text),
          const SizedBox(width: DsSpacing.xs),
          Flexible(
            child: Text(
              label,
              style: typo.micro.copyWith(
                color: pair.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap != null) {
      pill = Semantics(
        button: true,
        label: label,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: DsRadius.borderPill,
            onTap: onTap,
            child: pill,
          ),
        ),
      );
    } else {
      pill = Semantics(
        label: label,
        child: pill,
      );
    }

    return pill;
  }
}
