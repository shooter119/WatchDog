import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/route_traffic_store.dart';
import 'route_destination_picker_sheet.dart';
import 'route_traffic_cards.dart';

export '../state/route_traffic_store.dart';
export 'route_destination_picker_sheet.dart';
export 'route_traffic_cards.dart';

/// 赴事发地沿途路况与气象查询页（Design System v3.0）。
class RouteTrafficPage extends StatefulWidget {
  final RouteTrafficStore? store;
  final RouteTrafficGateway? gateway;
  final RouteTrafficIncidentContext? Function()? readCurrentIncident;
  final VoidCallback? onRequestIncidentSelection;
  final Future<void> Function()? onEditIncidentDetails;
  final Future<void> Function()? onImportIncidentDetails;

  const RouteTrafficPage({
    super.key,
    this.store,
    this.gateway,
    this.readCurrentIncident,
    this.onRequestIncidentSelection,
    this.onEditIncidentDetails,
    this.onImportIncidentDetails,
  }) : assert(
         store != null || gateway != null,
         'RouteTrafficPage requires either store or gateway',
       );

  @override
  State<RouteTrafficPage> createState() => _RouteTrafficPageState();
}

class _RouteTrafficPageState extends State<RouteTrafficPage> {
  late final RouteTrafficStore _store;
  late final bool _ownsStore;

  @override
  void initState() {
    super.initState();
    _ownsStore = widget.store == null;
    _store =
        widget.store ??
        RouteTrafficStore(
          gateway: widget.gateway!,
          readCurrentIncident: widget.readCurrentIncident ?? () => null,
        );
    _store.addListener(_onStoreChanged);
    unawaited(_store.load());
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    if (_ownsStore) {
      _store.dispose();
    }
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
    final pendingCandidates = _store.consumePendingCandidatePrompt();
    if (pendingCandidates != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_openCandidatePicker(pendingCandidates));
        }
      });
    }
  }

  Future<void> _openCandidatePicker(
    List<RouteDestinationCandidate> candidates,
  ) async {
    final picked = await showRouteDestinationPickerSheet(
      context,
      candidates: candidates,
      selectedCandidate: _store.selectedCandidate,
    );
    if (picked != null && mounted) {
      await _store.selectCandidate(picked);
    }
  }

  Future<void> _handleEditDetails() async {
    final cb = widget.onEditIncidentDetails;
    if (cb == null) return;
    await cb();
    if (mounted) unawaited(_store.load(forceRefreshDetails: true));
  }

  Future<void> _handleImportDetails() async {
    final cb = widget.onImportIncidentDetails;
    if (cb == null) return;
    await cb();
    if (mounted) unawaited(_store.load(forceRefreshDetails: true));
  }

  Future<void> _handleAmapKeywordSearch() async {
    final errorMsg = await _store.openAmapKeywordSearch();
    if (errorMsg != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(errorMsg)));
    }
  }

  Future<void> _handleCopySummary() async {
    final msg = await _store.copySummary();
    if (msg != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    }
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
      appBar: AppBar(
        title: const Text('路况查询'),
        actions: [
          IconButton(
            key: const Key('route-traffic-refresh'),
            tooltip: '刷新路况与天气',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            icon: const Icon(DsIcons.refresh),
            onPressed: _store.loading ? null : () => unawaited(_store.load()),
          ),
        ],
      ),
      body: !_store.hasIncident
          ? _buildNoIncidentState(context)
          : _store.missingLocation
          ? _buildMissingLocationState(context)
          : _store.loading
          ? const StatePlaceholder.loading(message: '正在查询沿途路况与气象…')
          : _store.error != null
          ? StatePlaceholder.error(
              title: '路况查询失败',
              reason: _store.error!,
              retryLabel: '重试',
              onRetry: () => unawaited(_store.load()),
            )
          : _buildContent(context),
    );
  }

  Widget _buildNoIncidentState(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(DsSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StatePlaceholder.empty(
              icon: DsIcons.altRoute,
              message: '尚未选择正在处置的警情',
              detail: '请先选择或创建一起警情，系统将根据警情中的事发地点查询沿途路况、耗时与天气。',
              padding: EdgeInsets.zero,
            ),
            const SizedBox(height: DsSpacing.lg),
            CommandButton(
              key: const Key('route-traffic-select-incident'),
              label: '选择警情',
              onPressed: () {
                widget.onRequestIncidentSelection?.call();
                Navigator.maybePop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMissingLocationState(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final cautionPair = colors.statusColors(DsStatus.caution);

    return ListView(
      padding: const EdgeInsets.all(DsSpacing.pageMargin),
      children: [
        SurfaceCard(
          padding: const EdgeInsets.all(DsSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: cautionPair.pillBg,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      DsIcons.locationOff,
                      color: cautionPair.text,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: DsSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '警情缺少事发地点',
                          style: ds.typography.headline.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: DsSpacing.xs),
                        Text(
                          '当前警情尚未填写具体位置信息，请先完善警情信息后再查询路况。',
                          style: ds.typography.body.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: DsSpacing.xl),
              CommandButton(
                key: const Key('route-traffic-edit-details'),
                label: '完善警情资料',
                icon: DsIcons.note,
                expanded: true,
                onPressed: () => unawaited(_handleEditDetails()),
              ),
              const SizedBox(height: DsSpacing.sm),
              CommandButton(
                key: const Key('route-traffic-import-details'),
                label: '导入警情信息（图片/文字）',
                icon: DsIcons.scanner,
                variant: CommandButtonVariant.secondary,
                expanded: true,
                onPressed: () => unawaited(_handleImportDetails()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final info = _store.info;
    if (info == null) return const SizedBox.shrink();

    final routes = info.routes;
    final selectedRoute = _store.selectedRoute;
    final hasWeather =
        info.weather != null ||
        info.forecast != null ||
        info.weatherLine != null;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.pageMargin,
              DsSpacing.md,
              DsSpacing.pageMargin,
              DsSpacing.xl,
            ),
            children: [
              _buildLocationBanner(context),
              if (hasWeather) ...[
                RouteWeatherCard(info: info),
                const SizedBox(height: DsSpacing.md),
              ],
              RouteEndpointsCard(
                info: info,
                fallbackLocation: _store.targetLocation,
                selectedCandidate: _store.selectedCandidate,
                onEditDetails: widget.onEditIncidentDetails != null
                    ? () => unawaited(_handleEditDetails())
                    : null,
                onOpenCandidates: () =>
                    unawaited(_openCandidatePicker(info.candidates)),
              ),
              if (info.destination?.isCoarse == true) ...[
                const SizedBox(height: DsSpacing.md),
                RouteCoarsePrecisionBanner(
                  destination: info.destination!,
                  hasCandidates: info.candidates.isNotEmpty,
                  onAmapSearch: () => unawaited(_handleAmapKeywordSearch()),
                  onOpenCandidates: () =>
                      unawaited(_openCandidatePicker(info.candidates)),
                ),
              ],
              if (selectedRoute != null) ...[
                const SizedBox(height: DsSpacing.md),
                RouteOverviewCard(
                  routes: routes,
                  selectedRouteIndex: _store.selectedRouteIndex,
                  selectedRoute: selectedRoute,
                  onSelectRoute: _store.selectRouteIndex,
                ),
                const SizedBox(height: DsSpacing.md),
                RouteCongestionCard(route: selectedRoute),
                const SizedBox(height: DsSpacing.md),
                RouteRoadsCard(
                  route: selectedRoute,
                  stepsExpanded: _store.stepsExpanded,
                  onToggleSteps: _store.toggleStepsExpanded,
                ),
              ],
            ],
          ),
        ),
        _buildBottomBar(context),
      ],
    );
  }

  Widget _buildLocationBanner(BuildContext context) {
    if (_store.locStatus == RouteTrafficLocationStatus.ok) {
      return const SizedBox.shrink();
    }
    final ds = context.ds;
    final colors = ds.colors;
    final cautionPair = colors.statusColors(DsStatus.caution);

    final String notice;
    final String actionText;
    final VoidCallback onAction;

    switch (_store.locStatus) {
      case RouteTrafficLocationStatus.permissionDenied:
        notice = '未授予定位权限，暂无法计算本机至事发地耗时与路线';
        actionText = '去授权';
        onAction = () => unawaited(_store.gateway.openAppSettings());
      case RouteTrafficLocationStatus.serviceDisabled:
        notice = '系统位置服务未开启，暂无法获取起点位置';
        actionText = '去开启';
        onAction = () => unawaited(_store.gateway.openLocationSettings());
      case RouteTrafficLocationStatus.fixFailed:
        notice = '当前位置获取超时，已降级展示事发地天气与导航';
        actionText = '重试定位';
        onAction = () => unawaited(_store.load());
      case RouteTrafficLocationStatus.ok:
        return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: SurfaceCard(
        accentStatus: DsStatus.caution,
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.md,
          vertical: DsSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              DsIcons.warning,
              size: DsSizes.iconMd,
              color: cautionPair.text,
            ),
            const SizedBox(width: DsSpacing.sm),
            Expanded(
              child: Text(
                notice,
                style: ds.typography.caption.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: DsSpacing.xs),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(
                  DsSizes.touchTarget,
                  DsSizes.touchTarget,
                ),
                foregroundColor: colors.brandText,
              ),
              onPressed: onAction,
              child: Text(actionText),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final colors = context.ds.colors;
    return Container(
      padding: const EdgeInsets.all(DsSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 340 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.25;
          final copyBtn = CommandButton(
            key: const Key('route-traffic-copy'),
            label: '复制路况简报',
            icon: DsIcons.copy,
            variant: CommandButtonVariant.secondary,
            expanded: true,
            onPressed: () => unawaited(_handleCopySummary()),
          );
          final navBtn = CommandButton(
            key: const Key('route-traffic-navigate'),
            label: '高德导航',
            icon: DsIcons.navigation,
            variant: CommandButtonVariant.primary,
            expanded: true,
            onPressed: () => unawaited(_handleNavigate()),
          );
          if (compact) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                copyBtn,
                const SizedBox(height: DsSpacing.sm),
                navBtn,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copyBtn),
              const SizedBox(width: DsSpacing.sm),
              Expanded(child: navBtn),
            ],
          );
        },
      ),
    );
  }
}
