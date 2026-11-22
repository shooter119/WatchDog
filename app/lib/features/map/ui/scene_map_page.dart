import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/scene_map_store.dart';
import 'scene_map_controls.dart';
import 'scene_map_surface.dart';

export '../state/scene_map_store.dart';

/// 现场卫星地图页面（Design System v3.0）。
class SceneMapPage extends StatefulWidget {
  final SceneMapStore? store;
  final SceneMapGateway? gateway;

  const SceneMapPage({super.key, this.store, this.gateway})
    : assert(
        store != null || gateway != null,
        'SceneMapPage requires either store or gateway',
      );

  @override
  State<SceneMapPage> createState() => _SceneMapPageState();
}

class _SceneMapPageState extends State<SceneMapPage>
    with WidgetsBindingObserver {
  late final SceneMapStore _store;
  late final bool _ownsStore;
  bool _builderReadyScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsStore = widget.store == null;
    _store = widget.store ?? SceneMapStore(gateway: widget.gateway!);
    _store.addListener(_onStoreChanged);
    unawaited(_store.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _store.pauseWatching();
    } else if (state == AppLifecycleState.resumed) {
      _store.resumeWatching();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.removeListener(_onStoreChanged);
    if (_ownsStore) {
      _store.dispose();
    }
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handleNavigate() async {
    final errorMsg = await _store.startNavigation();
    if (errorMsg != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(errorMsg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommandScaffold(
      useSafeArea: false,
      appBar: AppBar(
        title: const Text('现场地图'),
        actions: [
          IconButton(
            key: const Key('scene-map-refresh'),
            tooltip: '刷新地图与定位',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: () {
              _builderReadyScheduled = false;
              unawaited(_store.initialize());
            },
            icon: const Icon(DsIcons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(child: _buildMapArea(context)),
            Positioned(
              left: DsSpacing.md,
              right: DsSpacing.md,
              top: DsSpacing.sm,
              child: SceneMapTopOverlay(
                store: _store,
                onRetryBootstrap: () {
                  _builderReadyScheduled = false;
                  unawaited(_store.initialize());
                },
              ),
            ),
            Positioned(
              right: DsSpacing.md,
              bottom: DsSpacing.md,
              left: DsSpacing.md,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_store.canRenderMapSurface) ...[
                    SceneMapQuickFocusButtons(store: _store),
                    const SizedBox(height: DsSpacing.sm),
                  ],
                  SceneMapTelemetryCard(
                    store: _store,
                    onNavigate: () => unawaited(_handleNavigate()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapArea(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;

    if (_store.loadingBootstrap) {
      return Center(
        child: SurfaceCard(
          level: DsSurfaceLevel.raised,
          padding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.xl,
            vertical: DsSpacing.lg,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: colors.brand,
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Text(
                '正在初始化卫星地图…',
                style: ds.typography.body.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
      );
    }

    if (!_store.canRenderMapSurface) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            DsSpacing.lg,
            DsSpacing.lg,
            DsSpacing.lg,
            160,
          ),
          child: SurfaceCard(
            key: const Key('scene-map-unavailable-card'),
            padding: const EdgeInsets.all(DsSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  DsIcons.satellite,
                  size: 40,
                  color: colors.textSecondary,
                ),
                const SizedBox(height: DsSpacing.md),
                Text(
                  '暂无法加载高德卫星底图',
                  textAlign: TextAlign.center,
                  style: ds.typography.title.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: DsSpacing.sm),
                Text(
                  _store.bootstrapError ?? '服务端尚未配置高德 Web 端 (JS API) Key',
                  textAlign: TextAlign.center,
                  style: ds.typography.body.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
                CommandButton(
                  key: const Key('scene-map-retry-bootstrap'),
                  label: '重试连接',
                  icon: DsIcons.refresh,
                  onPressed: () {
                    _builderReadyScheduled = false;
                    unawaited(_store.initialize());
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    final customBuilder = _store.gateway.mapSurfaceBuilder;
    if (customBuilder != null) {
      if (!_builderReadyScheduled) {
        _builderReadyScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _store.markSurfaceReady();
        });
      }
      return customBuilder(
        context,
        _store.surfaceController,
        _store.handleBridgeEvent,
      );
    }

    return SceneMapSurface(
      surfaceController: _store.surfaceController,
      backgroundColor: colors.canvas.toARGB32(),
      onReady: _store.markSurfaceReady,
      onBridgeEvent: _store.handleBridgeEvent,
    );
  }
}
