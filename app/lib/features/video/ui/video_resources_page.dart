import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/video_playback_session.dart';
import '../data/models/video_resource.dart';
import '../state/video_resources_store.dart';
import 'video_playback_surface.dart';
import 'video_resource_card.dart';

/// 视频监控资源主页面（Design System v3.0）。
///
/// 通过 [VideoResourcesStore] 获取已授权视频资源与可达性探测结果，
/// 共享冻结的 [VideoPlaybackSession] 实现行内 / 全屏 / 悬浮三态平滑切换，
/// 并通过注入的 [onOpenAdmin] 与管理页彻底解耦。
class VideoResourcesPage extends StatefulWidget {
  const VideoResourcesPage({
    super.key,
    required this.store,
    this.playback,
    this.expandedPlayerBuilder,
    this.onOpenAdmin,
    this.onAuthenticate,
    this.onVideoFloating,
    this.isOffline = false,
  });

  final VideoResourcesStore store;
  final VideoPlaybackSession? playback;
  final Widget Function(VideoResource resource)? expandedPlayerBuilder;
  final Future<void> Function(BuildContext context)? onOpenAdmin;
  final Future<void> Function()? onAuthenticate;
  final VoidCallback? onVideoFloating;
  final bool isOffline;

  @override
  State<VideoResourcesPage> createState() => _VideoResourcesPageState();
}

class _VideoResourcesPageState extends State<VideoResourcesPage> {
  late VideoPlaybackSession _playback;
  late bool _ownsPlayback;

  @override
  void initState() {
    super.initState();
    _ownsPlayback = widget.playback == null;
    _playback = widget.playback ?? VideoPlaybackSession();
    _playback.addListener(_onPlaybackChanged);
    widget.store.addListener(_onStoreChanged);
    unawaited(widget.store.initialize());
  }

  @override
  void didUpdateWidget(covariant VideoResourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
      unawaited(widget.store.initialize());
    }
    if (oldWidget.playback != widget.playback) {
      _playback.removeListener(_onPlaybackChanged);
      if (_ownsPlayback) {
        _playback.dispose();
      }
      _ownsPlayback = widget.playback == null;
      _playback = widget.playback ?? VideoPlaybackSession();
      _playback.addListener(_onPlaybackChanged);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _playback.removeListener(_onPlaybackChanged);
    if (_ownsPlayback) {
      _playback.dispose();
    } else if (_playback.presentation == VideoPlaybackPresentation.inline) {
      _playback.stop();
    }
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _onPlaybackChanged() {
    unawaited(syncVideoSystemPip(_playback));
    if (!mounted) return;
    if (!_playback.hasResource && widget.store.expandedResourceId != null) {
      widget.store.clearExpanded();
      return;
    }
    setState(() {});
  }

  Future<void> _handleOpenAdmin() async {
    if (!widget.store.canManage) return;
    final openAdmin = widget.onOpenAdmin;
    if (openAdmin == null) return;
    await openAdmin(context);
    if (mounted) {
      await widget.store.load();
    }
  }

  void _expand(VideoResource resource) {
    if (!widget.store.selectExpanded(resource)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('视频地址无效，请联系管理员更新')),
      );
      return;
    }
    if (widget.expandedPlayerBuilder == null) {
      _playback.startInline(resource);
    }
  }

  void _collapse(String resourceId) {
    if (widget.store.expandedResourceId != resourceId) return;
    _playback.stop();
    widget.store.clearExpanded(resourceId);
  }

  Future<void> _showFullscreen(VideoResource resource) async {
    if (widget.store.expandedResourceId != resource.id) return;
    _playback.enterFullscreen();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoFullscreenScreen(session: _playback),
      ),
    );
    if (!mounted) return;
    if (_playback.resource?.id == resource.id) {
      _playback.returnInline();
    } else {
      widget.store.clearExpanded();
    }
  }

  void _showFloating(VideoResource resource) {
    if (widget.store.expandedResourceId != resource.id) return;
    _playback.enterFloating();
    if (widget.store.consumePipHintIfNeeded()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 4),
          content: Text(VideoResourcesStore.pipHintMessage),
        ),
      );
    }
    widget.onVideoFloating?.call();
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Widget _expandedPlayer(VideoResource resource) {
    return widget.expandedPlayerBuilder?.call(resource) ??
        VideoPlaybackSurface(session: _playback);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final authenticated = store.isAuthenticated;

    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(
        title: const Text('视频资源'),
        actions: <Widget>[
          if (authenticated && store.canManage)
            IconButton(
              key: const Key('video-resource-manage'),
              tooltip: '管理视频资源',
              style: IconButton.styleFrom(
                minimumSize: const Size(
                  DsSizes.touchTarget,
                  DsSizes.touchTarget,
                ),
              ),
              onPressed: _handleOpenAdmin,
              icon: const Icon(DsIcons.tune),
            ),
        ],
      ),
      body: !authenticated
          ? _AuthRequiredView(onAuthenticate: widget.onAuthenticate)
          : _buildResourceList(context, store),
    );
  }

  Widget _buildResourceList(BuildContext context, VideoResourcesStore store) {
    final colors = context.ds.colors;
    final resources = store.resources;
    final isInline = _playback.presentation == VideoPlaybackPresentation.inline;

    return RefreshIndicator(
      onRefresh: store.load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          DsSpacing.pageMargin,
          DsSpacing.md,
          DsSpacing.pageMargin,
          DsSpacing.xxl,
        ),
        children: <Widget>[
          if (store.loading && resources.isNotEmpty) ...<Widget>[
            LinearProgressIndicator(
              color: colors.brand,
              backgroundColor: colors.surfaceMuted,
            ),
            const SizedBox(height: DsSpacing.md),
          ],
          if (store.loading && resources.isEmpty)
            const StatePlaceholder.loading(message: '正在加载视频资源'),
          if (store.error != null) ...<Widget>[
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: StatePlaceholder.error(
                icon: DsIcons.connOffline,
                title: '视频资源加载失败',
                reason: store.error!,
                retryLabel: '重新加载',
                onRetry: () => unawaited(store.load()),
                padding: const EdgeInsets.all(DsSpacing.lg),
              ),
            ),
            const SizedBox(height: DsSpacing.cardGap),
          ],
          if (!store.loading && store.error == null && resources.isEmpty)
            const StatePlaceholder.empty(
              icon: DsIcons.videoLibrary,
              message: '暂无可用视频资源',
              detail: '管理员可在设置页添加并启用视频资源',
            ),
          for (final resource in resources) ...<Widget>[
            VideoResourceCard(
              key: ValueKey<String>('video-resource-${resource.id}'),
              resource: resource,
              available: store.availabilityOf(resource.id),
              expandedPlayer:
                  store.expandedResourceId == resource.id && isInline
                  ? _expandedPlayer(resource)
                  : null,
              onTap: () => _expand(resource),
              onClose: () => _collapse(resource.id),
              onFullscreen: () => _showFullscreen(resource),
              onFloating: () => _showFloating(resource),
            ),
            const SizedBox(height: DsSpacing.cardGap),
          ],
        ],
      ),
    );
  }
}

class _AuthRequiredView extends StatelessWidget {
  const _AuthRequiredView({this.onAuthenticate});

  final Future<void> Function()? onAuthenticate;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(DsSpacing.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.border, width: 1),
                ),
                child: Icon(
                  DsIcons.lock,
                  size: DsSizes.iconLg,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: DsSpacing.lg),
              Text(
                '需要完成单位认证',
                textAlign: TextAlign.center,
                style: typo.headline.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: DsSpacing.sm),
              Text(
                '视频资源仅向本单位已认证成员开放，请先退出游客模式并完成认证。',
                textAlign: TextAlign.center,
                style: typo.body.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: DsSpacing.lg),
              CommandButton(
                label: '去完成认证',
                icon: DsIcons.verified,
                variant: CommandButtonVariant.primary,
                size: CommandButtonSize.large,
                onPressed: onAuthenticate == null
                    ? null
                    : () => unawaited(onAuthenticate!()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
