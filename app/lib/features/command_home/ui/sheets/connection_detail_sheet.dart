import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/sync/sync_store.dart';
import '../../../../design_system/design_system.dart';

/// 连接与同步状态快照，供 [ConnectionDetailSheet] 渲染。
@immutable
class ConnectionDetailSnapshot {
  const ConnectionDetailSnapshot({
    required this.isGuest,
    required this.syncing,
    required this.connectionLost,
    required this.syncConnectionState,
    required this.serverUrl,
    this.pendingSyncCount = 0,
  });

  final bool isGuest;
  final bool syncing;
  final bool connectionLost;
  final SyncConnectionState syncConnectionState;
  final String serverUrl;
  final int pendingSyncCount;
}

/// 弹出基于 [CommandSheet] 的连接与同步状态详情抽屉。
Future<void> showConnectionDetailSheet(
  BuildContext context, {
  required ConnectionDetailSnapshot Function() snapshotProvider,
  Listenable? listenable,
  Future<void> Function()? onRetrySync,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext _) => ConnectionDetailSheet(
      snapshotProvider: snapshotProvider,
      listenable: listenable,
      onRetrySync: onRetrySync,
    ),
  );
}

/// 连接与同步详情抽屉（Design System v3.0）。
class ConnectionDetailSheet extends StatelessWidget {
  const ConnectionDetailSheet({
    super.key,
    required this.snapshotProvider,
    this.listenable,
    this.onRetrySync,
  });

  final ConnectionDetailSnapshot Function() snapshotProvider;
  final Listenable? listenable;
  final Future<void> Function()? onRetrySync;

  Widget _buildSheet(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final snap = snapshotProvider();

    final isConnected = !snap.connectionLost;
    final reconnectingInBackground =
        !snap.isGuest &&
        !snap.syncing &&
        isConnected &&
        snap.syncConnectionState != SyncConnectionState.connected &&
        snap.syncConnectionState != SyncConnectionState.stopped;

    final String statusText = snap.isGuest
        ? '模式：游客模式（单机演练）'
        : snap.syncing
        ? '状态：同步中'
        : (isConnected ? '状态：已联网绑定' : '状态：连接已中断');

    final String? detailHint = snap.isGuest
        ? null
        : snap.syncing
        ? '正在同步警情与实时通道数据'
        : reconnectingInBackground
        ? '实时通道正在后台重连，已保留最近同步数据'
        : (!isConnected ? '连续超过 30 秒未能同步，请检查网络或立即重试' : null);

    final DsStatus pillStatus = snap.isGuest
        ? DsStatus.neutral
        : snap.syncing || reconnectingInBackground
        ? DsStatus.caution
        : (isConnected ? DsStatus.safe : DsStatus.alarm);

    final IconData statusIcon = snap.isGuest
        ? Icons.phone_android_outlined
        : snap.syncing
        ? Icons.cloud_sync_outlined
        : (isConnected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined);

    return CommandSheet(
      title: '连接与同步状态',
      subtitle: '实时通道与本地离线队列状态概览',
      actions: <Widget>[
        CommandButton(
          key: const Key('connection-retry-sync-btn'),
          label: '立即重试同步',
          icon: Icons.sync_rounded,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          enabled: !snap.isGuest && onRetrySync != null,
          onPressed: snap.isGuest || onRetrySync == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  unawaited(onRetrySync!());
                },
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SurfaceCard(
            level: DsSurfaceLevel.flat,
            borderColor: colors.border,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                StatusPill(
                  status: pillStatus,
                  icon: statusIcon,
                  label: statusText,
                ),
                if (detailHint != null) ...<Widget>[
                  const SizedBox(height: DsSpacing.sm),
                  Text(
                    detailHint,
                    style: typo.caption.copyWith(
                      color: isConnected
                          ? colors.textSecondary
                          : colors.cautionText,
                    ),
                  ),
                ],
                if (snap.pendingSyncCount > 0) ...<Widget>[
                  const SizedBox(height: DsSpacing.sm),
                  Text(
                    '待补传离线操作：${snap.pendingSyncCount} 条',
                    style: typo.captionTabular.copyWith(
                      color: colors.cautionText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: DsSpacing.sm),
                Text(
                  '服务地址：${snap.serverUrl.isEmpty ? '未配置服务端' : snap.serverUrl}',
                  style: typo.caption.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (listenable == null) return _buildSheet(context);
    return ListenableBuilder(
      listenable: listenable!,
      builder: (BuildContext context, Widget? _) => _buildSheet(context),
    );
  }
}
