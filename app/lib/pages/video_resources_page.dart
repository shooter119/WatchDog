import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/video_resources.dart';
import '../services/video_resource_probe.dart';
import '../services/video_playback_session.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'video_resource_admin_page.dart';
import 'video_playback_surface.dart';

class VideoResourcesPage extends StatefulWidget {
  final AppController controller;
  final VideoResourceAvailabilityChecker availabilityChecker;
  final Widget Function(VideoResource resource)? expandedPlayerBuilder;
  final VideoPlaybackSession? playback;
  final VoidCallback? onVideoFloating;

  const VideoResourcesPage({
    super.key,
    required this.controller,
    this.availabilityChecker = VideoResourceProbe.check,
    this.expandedPlayerBuilder,
    this.playback,
    this.onVideoFloating,
  });

  @override
  State<VideoResourcesPage> createState() => _VideoResourcesPageState();
}

class _VideoResourcesPageState extends State<VideoResourcesPage> {
  List<VideoResource> _resources = const [];
  bool _canManage = false;
  bool _loading = true;
  String? _error;
  final Map<String, bool> _availability = {};
  String? _expandedResourceId;
  late final VideoPlaybackSession _playback;
  late final bool _ownsPlayback;

  ApiClient? get _api => widget.controller.api;

  @override
  void initState() {
    super.initState();
    _ownsPlayback = widget.playback == null;
    _playback = widget.playback ?? VideoPlaybackSession();
    _playback.addListener(_onPlaybackChanged);
    _load();
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
    if (_ownsPlayback) {
      _playback.dispose();
    } else if (_playback.presentation == VideoPlaybackPresentation.inline) {
      _playback.stop();
    }
    super.dispose();
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    if (!_playback.hasResource && _expandedResourceId != null) {
      setState(() => _expandedResourceId = null);
      return;
    }
    setState(() {});
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null || widget.controller.isGuest) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var canManage = false;
      try {
        final access = await api.videoResourceAccess();
        canManage = access['can_manage'] == true;
      } catch (_) {
        // Older deployments may not expose /access yet; listing still works.
        canManage = false;
      }
      final resources = await api.fetchVideoResources();
      if (!mounted) return;
      setState(() {
        _resources = resources;
        _canManage = canManage;
        _availability.clear();
        if (!resources.any((item) => item.id == _expandedResourceId)) {
          _expandedResourceId = null;
        }
      });
      unawaited(_checkAvailability(resources));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _checkAvailability(List<VideoResource> resources) async {
    await Future.wait(
      resources.map((resource) async {
        final available = await widget.availabilityChecker(resource);
        if (!mounted) return;
        setState(() => _availability[resource.id] = available);
      }),
    );
  }

  Future<void> _manage() async {
    final api = _api;
    if (api == null || !_canManage) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => VideoResourceAdminPage(api: api)),
    );
    if (mounted) await _load();
  }

  void _expand(VideoResource resource) {
    final uri = Uri.tryParse(resource.streamUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('视频地址无效，请联系管理员更新')));
      return;
    }
    setState(() => _expandedResourceId = resource.id);
    if (widget.expandedPlayerBuilder == null) {
      _playback.startInline(resource);
    }
  }

  void _collapse(String resourceId) {
    if (_expandedResourceId != resourceId) return;
    _playback.stop();
    setState(() => _expandedResourceId = null);
  }

  Future<void> _showFullscreen(VideoResource resource) async {
    if (_expandedResourceId != resource.id) return;
    _playback.enterFullscreen();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoFullscreenPage(session: _playback),
      ),
    );
    if (!mounted) return;
    if (_playback.resource?.id == resource.id) {
      _playback.returnInline();
    } else {
      setState(() => _expandedResourceId = null);
    }
  }

  void _showFloating(VideoResource resource) {
    if (_expandedResourceId != resource.id) return;
    _playback.enterFloating();
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
    final authenticated =
        !widget.controller.isGuest &&
        !widget.controller.needsAuthentication &&
        _api != null;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('视频资源'),
        actions: [
          if (authenticated && _canManage)
            IconButton(
              key: const Key('video-resource-manage'),
              tooltip: '管理视频资源',
              onPressed: _manage,
              icon: const Icon(Icons.tune_rounded),
            ),
        ],
      ),
      body: !authenticated
          ? _AuthRequired(onAuthenticate: widget.controller.leaveUnit)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  const _VideoIntro(),
                  const SizedBox(height: AppSpacing.s3),
                  if (_loading) const LinearProgressIndicator(),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.s3),
                    _LoadFailure(error: _error!, onRetry: _load),
                  ],
                  if (!_loading && _error == null && _resources.isEmpty)
                    const _EmptyResources(),
                  for (final resource in _resources) ...[
                    VideoResourceCard(
                      key: ValueKey('video-resource-${resource.id}'),
                      resource: resource,
                      available: _availability[resource.id],
                      expandedPlayer:
                          _expandedResourceId == resource.id &&
                              _playback.presentation ==
                                  VideoPlaybackPresentation.inline
                          ? _expandedPlayer(resource)
                          : null,
                      onTap: () => _expand(resource),
                      onClose: () => _collapse(resource.id),
                      onFullscreen: () => _showFullscreen(resource),
                      onFloating: () => _showFloating(resource),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                  ],
                ],
              ),
            ),
    );
  }
}

class VideoResourceCard extends StatelessWidget {
  final VideoResource resource;
  final bool? available;
  final Widget? expandedPlayer;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback? onFullscreen;
  final VoidCallback? onFloating;

  const VideoResourceCard({
    super.key,
    required this.resource,
    this.available,
    this.expandedPlayer,
    required this.onTap,
    required this.onClose,
    this.onFullscreen,
    this.onFloating,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: expandedPlayer == null ? onTap : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2,
      ),
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.heroBackground,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.videocam_rounded,
                    color: AppColors.heroOnDark,
                    size: 22,
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Tooltip(
                            message: available == null
                                ? '正在检测视频是否可用'
                                : available!
                                ? '视频可用'
                                : '视频不可用',
                            child: Semantics(
                              label: available == null
                                  ? '正在检测视频是否可用'
                                  : available!
                                  ? '视频可用'
                                  : '视频不可用',
                              child: Container(
                                key: ValueKey(
                                  'video-resource-status-${resource.id}',
                                ),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: available == null
                                      ? AppColors.textTertiary
                                      : available!
                                      ? AppColors.online
                                      : AppColors.alarm,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.s2),
                          Expanded(
                            child: Text(
                              resource.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.bodyMd.copyWith(
                                height: 1.3,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.s1),
                      Text(
                        resource.description.trim().isEmpty
                            ? '已授权视频画面'
                            : resource.description.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption.copyWith(
                          height: 1.3,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (expandedPlayer == null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSubtle,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: AppColors.actionPrimary,
                      size: 22,
                    ),
                  ),
                ],
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expandedPlayer == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s3),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: AspectRatio(
                        key: ValueKey('video-resource-expanded-${resource.id}'),
                        aspectRatio: 16 / 9,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            expandedPlayer!,
                            Positioned(
                              top: AppSpacing.s2,
                              right: AppSpacing.s2,
                              child: Row(
                                children: [
                                  PlayerOverlayButton(
                                    key: ValueKey(
                                      'video-resource-fullscreen-${resource.id}',
                                    ),
                                    tooltip: '全屏播放',
                                    icon: Icons.fullscreen_rounded,
                                    onPressed: onFullscreen ?? () {},
                                  ),
                                  const SizedBox(width: AppSpacing.s1),
                                  PlayerOverlayButton(
                                    key: ValueKey(
                                      'video-resource-floating-${resource.id}',
                                    ),
                                    tooltip: '浮窗播放',
                                    icon: Icons.picture_in_picture_alt_rounded,
                                    onPressed: onFloating ?? () {},
                                  ),
                                  const SizedBox(width: AppSpacing.s1),
                                  PlayerOverlayButton(
                                    key: ValueKey(
                                      'video-resource-close-${resource.id}',
                                    ),
                                    tooltip: '关闭视频',
                                    icon: Icons.close_rounded,
                                    onPressed: onClose,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _VideoIntro extends StatelessWidget {
  const _VideoIntro();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.live_tv_rounded,
            size: 18,
            color: AppColors.actionPrimary,
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              '仅展示本单位管理员启用的授权视频资源。点击资源后在卡片内展开并播放实时画面。',
              style: AppTextStyles.bodyMd.copyWith(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyResources extends StatelessWidget {
  const _EmptyResources();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.s10,
        horizontal: AppSpacing.s5,
      ),
      child: Column(
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 48,
            color: AppColors.textTertiary,
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            '暂无可用视频资源',
            style: AppTextStyles.bodyMd.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            '管理员可在设置页添加并启用视频资源',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMd.copyWith(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  final String error;
  final Future<void> Function() onRetry;

  const _LoadFailure({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        children: [
          Icon(Icons.cloud_off_outlined, color: AppColors.alarm, size: 32),
          const SizedBox(height: AppSpacing.s2),
          Text(
            '视频资源加载失败',
            style: AppTextStyles.bodyMd.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            error,
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新加载'),
          ),
        ],
      ),
    );
  }
}

class _AuthRequired extends StatelessWidget {
  final Future<void> Function() onAuthenticate;

  const _AuthRequired({required this.onAuthenticate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 48,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              '需要完成单位认证',
              style: AppTextStyles.h2.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              '视频资源仅向本单位已认证成员开放，请先退出游客模式并完成认证。',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            FilledButton.icon(
              onPressed: onAuthenticate,
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('去完成认证'),
            ),
          ],
        ),
      ),
    );
  }
}
