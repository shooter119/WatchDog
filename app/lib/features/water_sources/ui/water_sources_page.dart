import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/water_sources_store.dart';
import 'water_source_card.dart';
import 'water_source_detail_sheet.dart';
import 'water_source_editor_sheet.dart';
import 'water_sources_map_surface.dart';
import 'water_sources_overlays.dart';

export '../state/water_sources_store.dart';
export 'water_source_card.dart';

/// 大队级自建水源库「周边水源」独立查询与维护页面（Design System v3.0）。
class WaterSourcesPage extends StatefulWidget {
  final WaterSourcesStore? store;
  final WaterSourcesGateway? gateway;
  final WaterSourcesMapBuilder? mapBuilder;

  const WaterSourcesPage({
    super.key,
    this.store,
    this.gateway,
    this.mapBuilder,
  }) : assert(
         store != null || gateway != null,
         'WaterSourcesPage requires either store or gateway',
       );

  @override
  State<WaterSourcesPage> createState() => _WaterSourcesPageState();
}

class _WaterSourcesPageState extends State<WaterSourcesPage> {
  late final WaterSourcesStore _store;
  late final bool _ownsStore;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ownsStore = widget.store == null;
    _store =
        widget.store ??
        WaterSourcesStore(
          gateway: widget.gateway!,
          hasCustomMapBuilder: widget.mapBuilder != null,
        );
    _store.addListener(_onStoreChanged);
    unawaited(_store.initialize());
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _searchController.dispose();
    if (_ownsStore) _store.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _handleSelectMarker(String id) {
    final found = _store.findById(id);
    if (found == null) return;
    _store.selectItem(found.id);
    unawaited(
      _openDetailSheet(found).whenComplete(() {
        if (!mounted || _store.selectedId != found.id) return;
        _store.selectItem(null);
      }),
    );
  }

  void _handleSelectCard(WaterSource item) {
    _store.selectItem(item.id, focusMap: true);
    unawaited(_openDetailSheet(item));
  }

  void _startAddFlow() {
    if (_store.canRenderMap) {
      _store.startAddPicking();
      return;
    }
    unawaited(
      showWaterSourceEditorSheet(
        context,
        store: _store,
        onToast: _showToast,
        initialLat: _store.myGcj?.lat,
        initialLng: _store.myGcj?.lng,
        allowManualCoords: true,
      ),
    );
  }

  Future<void> _confirmPickPosition() async {
    final pos = _store.pickCenter;
    if (pos == null) return;
    final target = _store.editingCoordTarget;
    _store.cancelPicking();

    if (target != null) {
      try {
        final updated = await _store.updateWaterSource(
          target.id,
          lat: pos.lat,
          lng: pos.lng,
        );
        if (!mounted) return;
        _showToast('已更新「${updated.name}」坐标');
      } catch (e) {
        if (!mounted) return;
        _showToast(_store.friendlyError(e));
      }
      return;
    }

    await showWaterSourceEditorSheet(
      context,
      store: _store,
      onToast: _showToast,
      initialLat: pos.lat,
      initialLng: pos.lng,
    );
  }

  Future<void> _quickToggleStatus(WaterSource item) async {
    final nextStatus = item.isAvailable
        ? WaterSourceStatus.unavailable
        : WaterSourceStatus.available;
    try {
      final updated = await _store.updateWaterSource(
        item.id,
        status: nextStatus,
      );
      if (!mounted) return;
      _showToast('已标记为「${updated.status.label}」');
    } catch (e) {
      if (!mounted) return;
      _showToast(_store.friendlyError(e));
    }
  }

  Future<void> _confirmAndDelete(WaterSource item) async {
    final confirmed = await showWaterSourceDeleteConfirmSheet(
      context,
      item: item,
    );
    if (!confirmed || !mounted) return;

    try {
      await _store.deleteWaterSource(item.id);
      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 60),
          content: Text('已删除「${item.name}」'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => unawaited(_undoDelete(item)),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showToast(_store.friendlyError(e));
    }
  }

  Future<void> _undoDelete(WaterSource item) async {
    try {
      final restored = await _store.restoreWaterSource(item.id);
      if (!mounted) return;
      _showToast('已恢复「${restored.name}」');
    } catch (e) {
      if (!mounted) return;
      _showToast(_store.friendlyError(e));
    }
  }

  Future<void> _openDetailSheet(WaterSource item) {
    return showWaterSourceDetailSheet(
      context,
      store: _store,
      initialItem: item,
      onToast: _showToast,
      onEdit: (current) => () {
        unawaited(
          showWaterSourceEditorSheet(
            context,
            store: _store,
            onToast: _showToast,
            existing: current,
            allowManualCoords: !_store.canRenderMap,
          ),
        );
      },
      onReposition: (current) => () => _store.startRepositionPicking(current),
      onDelete: (current) => () => unawaited(_confirmAndDelete(current)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _store.filteredItems;
    final summary = _store.summary;

    return CommandScaffold(
      useSafeArea: false,
      appBar: AppBar(
        title: const Text('周边水源'),
        actions: [
          IconButton(
            key: const Key('water-sources-refresh'),
            tooltip: '刷新水源与定位',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: () => unawaited(_store.refreshData()),
            icon: const Icon(DsIcons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: DsSpacing.sm),
            child: FilledButton.icon(
              key: const Key('water-sources-add'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.md,
                  vertical: 0,
                ),
                minimumSize: const Size(0, 38),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _store.pickingMode ? null : _startAddFlow,
              icon: const Icon(DsIcons.locationAdd, size: 17),
              label: const Text('新增'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _store.canRenderMap
            ? _buildFullScreenMapBody(context, filtered, summary)
            : _buildDegradedBody(context, filtered, summary),
      ),
    );
  }

  Widget _buildFullScreenMapBody(
    BuildContext context,
    List<WaterSource> filtered,
    WaterSourceSummary summary,
  ) {
    final ds = context.ds;
    final mapState = WaterSourcesMapState(
      surfaceController: _store.surfaceController,
      items: filtered,
      selected: _store.selectedItem,
      myGcj: _store.myGcj,
      pickingMode: _store.pickingMode,
      pickCenter: _store.pickCenter,
      onBridgeEvent: (t, d) => _store.handleBridgeEvent(
        t,
        d,
        onMarkerClick: _handleSelectMarker,
      ),
      onSelectMarker: _handleSelectMarker,
      onPickCenterChanged: _store.updatePickCenter,
    );

    final mapWidget = widget.mapBuilder != null
        ? widget.mapBuilder!(context, mapState)
        : WaterSourcesMapSurface(
            surfaceController: _store.surfaceController,
            backgroundColor: ds.colors.canvas.toARGB32(),
            onReady: _store.markSurfaceReady,
            onBridgeEvent: (t, d) => _store.handleBridgeEvent(
              t,
              d,
              onMarkerClick: _handleSelectMarker,
            ),
          );

    return Stack(
      children: [
        Positioned.fill(child: mapWidget),
        Positioned(
          top: DsSpacing.sm,
          left: DsSpacing.md,
          right: DsSpacing.md,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_store.pickingMode)
                WaterMapFilterOverlay(store: _store, summary: summary),
              if (_store.locStatus != WaterLocStatus.ok &&
                  _store.locStatus != WaterLocStatus.loading) ...[
                const SizedBox(height: DsSpacing.sm),
                WaterLocationDegradedBanner(store: _store, inOverlay: true),
              ],
              if (_store.listError != null && _store.items.isEmpty) ...[
                const SizedBox(height: DsSpacing.sm),
                WaterStatusBanner(
                  status: DsStatus.alarm,
                  text: _store.listError!,
                  action: TextButton(
                    key: const Key('water-list-retry'),
                    onPressed: () => unawaited(_store.refreshData()),
                    child: const Text('重试'),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_store.loadingList && _store.items.isEmpty)
          const Positioned(
            top: 64,
            left: 0,
            right: 0,
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ),
        if (!_store.pickingMode)
          Positioned(
            right: DsSpacing.md,
            bottom: DsSpacing.lg,
            child: SurfaceCard(
              level: DsSurfaceLevel.raised,
              borderRadius: DsRadius.borderMd,
              padding: EdgeInsets.zero,
              onTap: _store.centerOnMyLocation,
              child: SizedBox(
                key: const Key('water-map-center-me'),
                width: DsSizes.touchTarget,
                height: DsSizes.touchTarget,
                child: Tooltip(
                  message: '回到当前位置',
                  child: Icon(
                    DsIcons.myLocation,
                    size: 22,
                    color: ds.colors.brandText,
                  ),
                ),
              ),
            ),
          ),
        if (_store.pickingMode) ...[
          const IgnorePointer(
            child: Center(
              child: WaterCrosshairReticle(key: Key('water-map-crosshair')),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: WaterPickingPanel(
              store: _store,
              onConfirm: () => unawaited(_confirmPickPosition()),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDegradedBody(
    BuildContext context,
    List<WaterSource> filtered,
    WaterSourceSummary summary,
  ) {
    final mapReason =
        _store.scriptError ??
        _store.bootstrapError ??
        '底图加载失败，已切换为纯列表查水模式';
    return Column(
      children: [
        if (!_store.loadingBootstrap)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.pageMargin,
              DsSpacing.sm,
              DsSpacing.pageMargin,
              0,
            ),
            child: WaterStatusBanner(
              status: DsStatus.caution,
              text: mapReason,
              action: TextButton(
                key: const Key('water-map-retry'),
                onPressed: () => unawaited(_store.retryMapBootstrap()),
                child: const Text('重试底图'),
              ),
            ),
          ),
        if (_store.locStatus != WaterLocStatus.ok &&
            _store.locStatus != WaterLocStatus.loading)
          WaterLocationDegradedBanner(store: _store),
        WaterDegradedFilterBar(
          store: _store,
          summary: summary,
          searchController: _searchController,
        ),
        Expanded(child: _buildListSection(filtered)),
      ],
    );
  }

  Widget _buildListSection(List<WaterSource> filtered) {
    if (_store.loadingList && _store.items.isEmpty) {
      return const StatePlaceholder.loading(message: '正在加载周边水源…');
    }
    if (_store.listError != null && _store.items.isEmpty) {
      return StatePlaceholder.error(
        title: '水源列表加载失败',
        reason: _store.listError!,
        retryLabel: '重试加载',
        onRetry: () => unawaited(_store.refreshData()),
      );
    }
    if (filtered.isEmpty) {
      return StatePlaceholder.empty(
        icon: DsIcons.toolWaterSources,
        message: _store.items.isEmpty
            ? '本单位暂未录入水源点位，点击右上角「新增」开始采集'
            : '当前筛选条件下暂无匹配水源',
      );
    }
    return ListView.separated(
      key: const Key('water-sources-list'),
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.xs,
        DsSpacing.pageMargin,
        DsSpacing.xxl,
      ),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: DsSpacing.sm),
      itemBuilder: (context, index) {
        final item = filtered[index];
        return WaterSourceCard(
          item: item,
          distanceMeters: _store.distanceFor(item),
          selected: item.id == _store.selectedId,
          onTap: () => _handleSelectCard(item),
          onQuickToggleStatus: () => unawaited(_quickToggleStatus(item)),
        );
      },
    );
  }
}
