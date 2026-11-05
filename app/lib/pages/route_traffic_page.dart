import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/camera_bridge.dart';
import '../services/screen_on.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'incident_details_page.dart';
import 'incident_import_page.dart';

/// 路由网关，便于单元测试与自动化注入
class RouteTrafficGateway {
  final Future<bool> Function() requestPermission;
  final Future<bool> Function() locationServiceEnabled;
  final Future<LocationFix?> Function() currentLocation;
  final Future<RouteTrafficInfo> Function({
    required String address,
    String? city,
    double? originLat,
    double? originLon,
  }) fetchRouteTraffic;
  final Future<Map<String, dynamic>> Function(String incidentId)?
  fetchIncidentDetails;
  final Future<void> Function() openAppSettings;
  final Future<void> Function() openLocationSettings;
  final Future<void> Function(String text) copyText;
  final Future<bool> Function(Uri uri) launchNavigation;

  const RouteTrafficGateway({
    required this.requestPermission,
    required this.locationServiceEnabled,
    required this.currentLocation,
    required this.fetchRouteTraffic,
    this.fetchIncidentDetails,
    required this.openAppSettings,
    required this.openLocationSettings,
    required this.copyText,
    required this.launchNavigation,
  });
}

class RouteTrafficPage extends StatefulWidget {
  final AppController controller;
  final RouteTrafficGateway? gateway;

  const RouteTrafficPage({super.key, required this.controller, this.gateway});

  @override
  State<RouteTrafficPage> createState() => _RouteTrafficPageState();
}

enum _LocationStatus { ok, permissionDenied, serviceDisabled, fixFailed }

class _RouteTrafficPageState extends State<RouteTrafficPage> {
  late final RouteTrafficGateway _gateway;
  bool _loading = false;
  String? _error;
  RouteTrafficInfo? _info;
  int _selectedRouteIndex = 0;
  bool _stepsExpanded = false;

  // 定位状态（失败时不阻断终点与天气展示）
  _LocationStatus _locStatus = _LocationStatus.ok;

  // 警情具体地址状态
  String _targetLocation = '';
  String _targetCity = '';
  bool _missingLocation = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _gateway =
        widget.gateway ??
        RouteTrafficGateway(
          requestPermission: CameraBridge.requestLocationPermission,
          locationServiceEnabled: CameraBridge.isLocationServiceEnabled,
          currentLocation: CameraBridge.currentLocation,
          fetchRouteTraffic: ({
            required String address,
            String? city,
            double? originLat,
            double? originLon,
          }) async {
            final api = widget.controller.api;
            if (api == null) throw Exception('未连接服务端');
            return api.fetchRouteTraffic(
              address: address,
              city: city,
              originLat: originLat,
              originLon: originLon,
            );
          },
          fetchIncidentDetails: (id) async {
            final api = widget.controller.api;
            if (api == null) return {};
            return api.forIncident(id).fetchIncidentDetails();
          },
          openAppSettings: ScreenOn.openAppSettings,
          openLocationSettings: CameraBridge.openLocationSettings,
          copyText: (text) => Clipboard.setData(ClipboardData(text: text)),
          launchNavigation: (uri) =>
              launchUrl(uri, mode: LaunchMode.externalApplication),
        );

    unawaited(_load());
  }

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    final incident = widget.controller.currentIncident;
    if (incident == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
          _info = null;
          _missingLocation = false;
        });
      }
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _missingLocation = false;
    });

    String location = (incident.info['location']?.toString() ?? '').trim();
    String city =
        (incident.info['administrative_area']?.toString() ?? '').trim();

    // 若警情 info 中缺少位置，尝试从警情详情接口补拉一次
    if (location.isEmpty && _gateway.fetchIncidentDetails != null) {
      try {
        final details = await _gateway.fetchIncidentDetails!(incident.id);
        if (details['data'] is Map) {
          final data = Map<String, dynamic>.from(details['data'] as Map);
          location = (data['location']?.toString() ?? '').trim();
          if (city.isEmpty) {
            city = (data['administrative_area']?.toString() ?? '').trim();
          }
        }
      } catch (_) {
        // 网络失败时沿用当前已知状态
      }
    }

    if (!mounted || gen != _loadGeneration) return;

    if (location.isEmpty) {
      setState(() {
        _loading = false;
        _missingLocation = true;
        _targetLocation = '';
        _targetCity = '';
      });
      return;
    }

    _targetLocation = location;
    _targetCity = city;

    // 尝试获取本机定位（即使定位失败也继续调用路况查询，降级展示终点天气与导航）
    _LocationStatus locStatus = _LocationStatus.ok;
    LocationFix? fix;
    try {
      final permitted = await _gateway.requestPermission();
      if (!permitted) {
        locStatus = _LocationStatus.permissionDenied;
      } else {
        final enabled = await _gateway.locationServiceEnabled();
        if (!enabled) {
          locStatus = _LocationStatus.serviceDisabled;
        } else {
          fix = await _gateway.currentLocation();
          if (fix == null) {
            locStatus = _LocationStatus.fixFailed;
          }
        }
      }
    } catch (_) {
      locStatus = _LocationStatus.fixFailed;
    }

    if (!mounted || gen != _loadGeneration) return;

    _locStatus = locStatus;

    try {
      final info = await _gateway.fetchRouteTraffic(
        address: _targetLocation,
        city: _targetCity.isNotEmpty ? _targetCity : null,
        originLat: fix?.lat,
        originLon: fix?.lon,
      );

      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _loading = false;
        _info = info;
        _selectedRouteIndex = 0;
        _error = null;
      });
    } catch (e) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      });
    }
  }

  Future<void> _openEditDetails() async {
    final incident = widget.controller.currentIncident;
    final api = widget.controller.api;
    if (incident == null || api == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => IncidentDetailsPage(
          controller: widget.controller,
          api: api,
          incident: incident,
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }

  Future<void> _openImportDetails() async {
    final incident = widget.controller.currentIncident;
    final api = widget.controller.api;
    if (incident == null || api == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => IncidentImportPage(api: api, incident: incident),
      ),
    );
    if (mounted) unawaited(_load());
  }

  Future<void> _copySummary() async {
    final info = _info;
    if (info == null) return;
    final incidentName = widget.controller.currentIncident?.displayName ?? '';
    final text = info.toSummaryText(
      incidentName: incidentName,
      routeIndex: _selectedRouteIndex,
    );
    await _gateway.copyText(text);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('路况简报已复制')));
    }
  }

  Future<void> _startNavigation() async {
    final uri = _info?.navigationUri;
    if (uri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('未获取到事发地点坐标，无法导航')));
      }
      return;
    }
    final ok = await _gateway.launchNavigation(uri);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('无法打开外部地图导航应用')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final incident = widget.controller.currentIncident;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('路况查询'),
        actions: [
          IconButton(
            key: const Key('route-traffic-refresh'),
            tooltip: '刷新路况与天气',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: incident == null
            ? _buildNoIncidentState()
            : _missingLocation
            ? _buildMissingLocationState()
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _buildErrorState()
            : _buildContent(),
      ),
    );
  }

  Widget _buildNoIncidentState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppEmptyState(
              icon: Icons.alt_route_rounded,
              title: '尚未选择正在处置的警情',
              hint: '请先选择或创建一起警情，系统将根据警情中的事发地点查询沿途路况、耗时与天气。',
            ),
            const SizedBox(height: AppSpacing.s4),
            FilledButton(
              key: const Key('route-traffic-select-incident'),
              onPressed: () {
                widget.controller.requestIncidentSelection();
                Navigator.pop(context);
              },
              child: const Text('选择警情'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMissingLocationState() {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.s4),
      children: [
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.s5),
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
                      color: AppColors.voice.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.wrong_location_outlined,
                      color: AppColors.voice,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '警情缺少事发地点',
                          style: AppTextStyles.h2.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s1),
                        Text(
                          '当前警情尚未填写具体位置信息，请先完善警情信息后再查询路况。',
                          style: AppTextStyles.bodyMd.copyWith(
                            color: AppColors.textSecondary,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s5),
              FilledButton.icon(
                key: const Key('route-traffic-edit-details'),
                icon: const Icon(Icons.edit_note_rounded, size: 20),
                label: const Text('完善警情资料'),
                onPressed: _openEditDetails,
              ),
              const SizedBox(height: AppSpacing.s2),
              OutlinedButton.icon(
                key: const Key('route-traffic-import-details'),
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: const Text('导入警情信息（图片/文字）'),
                onPressed: _openImportDetails,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.s4),
      children: [
        AppNotice(
          kind: AppNoticeKind.error,
          text: _error ?? '路况查询失败',
          action: TextButton(onPressed: _load, child: const Text('重试')),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final info = _info;
    if (info == null) return const SizedBox.shrink();

    final routes = info.routes;
    final selectedRoute =
        routes.isNotEmpty && _selectedRouteIndex < routes.length
            ? routes[_selectedRouteIndex]
            : null;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s3,
              AppSpacing.s4,
              AppSpacing.s5,
            ),
            children: [
              _buildLocationBanner(),
              _buildEndpointsCard(info),
              const SizedBox(height: AppSpacing.s3),
              if (selectedRoute != null) ...[
                _buildRouteOverviewCard(routes, selectedRoute),
                const SizedBox(height: AppSpacing.s3),
                _buildCongestionCard(selectedRoute),
                const SizedBox(height: AppSpacing.s3),
                _buildRoadsCard(selectedRoute),
                const SizedBox(height: AppSpacing.s3),
              ],
              _buildWeatherCard(info),
            ],
          ),
        ),
        _buildBottomBar(info),
      ],
    );
  }

  Widget _buildLocationBanner() {
    if (_locStatus == _LocationStatus.ok) return const SizedBox.shrink();

    String notice;
    String actionText;
    VoidCallback onAction;

    switch (_locStatus) {
      case _LocationStatus.permissionDenied:
        notice = '未授予定位权限，暂无法计算本机至事发地耗时与路线';
        actionText = '去授权';
        onAction = _gateway.openAppSettings;
        break;
      case _LocationStatus.serviceDisabled:
        notice = '系统位置服务未开启，暂无法获取起点位置';
        actionText = '去开启';
        onAction = _gateway.openLocationSettings;
        break;
      case _LocationStatus.fixFailed:
        notice = '当前位置获取超时，已降级展示事发地天气与导航';
        actionText = '重试定位';
        onAction = _load;
        break;
      case _LocationStatus.ok:
        return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: AppNotice(
        kind: AppNoticeKind.warning,
        text: notice,
        action: TextButton(onPressed: onAction, child: Text(actionText)),
      ),
    );
  }

  Widget _buildEndpointsCard(RouteTrafficInfo info) {
    final originAddr = info.origin?.address.trim();
    final destAddr = info.destination?.displayAddress ?? _targetLocation;

    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.my_location_rounded,
                  size: 16,
                  color: AppColors.voice,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  originAddr != null && originAddr.isNotEmpty
                      ? originAddr
                      : '当前位置（未获取具体地址）',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.label.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox(width: 7),
                SizedBox(
                  height: 14,
                  child: VerticalDivider(width: 2, color: AppColors.border),
                ),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.location_on_rounded,
                  size: 16,
                  color: AppColors.alarm,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  destAddr,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMd.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              InkWell(
                onTap: _openEditDetails,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    '修改',
                    style: AppTextStyles.label.copyWith(
                      color: AppColors.voice,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRouteOverviewCard(
    List<DrivingRoutePlan> routes,
    DrivingRoutePlan selectedRoute,
  ) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (routes.length > 1) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < routes.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.s2),
                    ChoiceChip(
                      label: Text('方案${i + 1} · ${routes[i].strategy}'),
                      selected: _selectedRouteIndex == i,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedRouteIndex = i;
                            _stepsExpanded = false;
                          });
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                RouteTrafficInfo.formatDuration(selectedRoute.durationSeconds),
                style: AppTextStyles.h1.copyWith(
                  color: AppColors.voice,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Text(
                RouteTrafficInfo.formatDistance(selectedRoute.distanceMeters),
                style: AppTextStyles.bodyLg.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Text(
                '红绿灯 ${selectedRoute.trafficLights} 个',
                style: AppTextStyles.label.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          _buildTrafficStatusBar(selectedRoute),
        ],
      ),
    );
  }

  Widget _buildTrafficStatusBar(DrivingRoutePlan route) {
    final summary = route.trafficSummary;
    final total = summary.totalMeters > 0 ? summary.totalMeters : route.distanceMeters;

    Color statusColor;
    switch (route.overallStatus) {
      case '严重拥堵':
        statusColor = const Color(0xFFB91C1C);
        break;
      case '拥堵':
      case '局部拥堵':
        statusColor = AppColors.alarm;
        break;
      case '局部缓行':
      case '缓行':
        statusColor = const Color(0xFFF59E0B);
        break;
      default:
        statusColor = const Color(0xFF10B981);
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: statusColor.withValues(alpha: 0.3)),
              ),
              child: Text(
                '路况：${route.overallStatus}',
                style: AppTextStyles.caption.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Spacer(),
            if (summary.totalMeters > 0)
              Text(
                '畅通 ${RouteTrafficInfo.formatDistance(summary.smoothMeters, compactUnit: true)}',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
        if (summary.totalMeters > 0 && total > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Row(
                children: [
                  if (summary.smoothMeters > 0)
                    Expanded(
                      flex: summary.smoothMeters,
                      child: Container(color: const Color(0xFF10B981)),
                    ),
                  if (summary.slowMeters > 0)
                    Expanded(
                      flex: summary.slowMeters,
                      child: Container(color: const Color(0xFFF59E0B)),
                    ),
                  if (summary.jamMeters > 0)
                    Expanded(
                      flex: summary.jamMeters,
                      child: Container(color: AppColors.alarm),
                    ),
                  if (summary.severeJamMeters > 0)
                    Expanded(
                      flex: summary.severeJamMeters,
                      child: Container(color: const Color(0xFFB91C1C)),
                    ),
                  if (summary.unknownMeters > 0)
                    Expanded(
                      flex: summary.unknownMeters,
                      child: Container(color: AppColors.border),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCongestionCard(DrivingRoutePlan route) {
    final segments = route.congestedSegments;
    final hasJam = segments.isNotEmpty;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasJam
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline_rounded,
                size: 18,
                color: hasJam ? const Color(0xFFF59E0B) : const Color(0xFF10B981),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(
                hasJam ? '沿途拥堵/缓行路段' : '路况态势',
                style: AppTextStyles.bodyMd.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          if (hasJam) ...[
            for (final seg in segments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: seg.status == '严重拥堵'
                            ? const Color(0xFFB91C1C)
                            : seg.status == '拥堵'
                            ? AppColors.alarm
                            : const Color(0xFFF59E0B),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: Text(
                        seg.road,
                        style: AppTextStyles.bodyMd.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${seg.status} ${RouteTrafficInfo.formatDistance(seg.distanceMeters, compactUnit: true)}',
                      style: AppTextStyles.label.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ] else
            const Text(
              '当前路线全线畅通，无明显拥堵路段。',
              style: TextStyle(
                color: Color(0xFF10B981),
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRoadsCard(DrivingRoutePlan route) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.alt_route_rounded,
                size: 18,
                color: AppColors.voice,
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(
                '主要途经道路',
                style: AppTextStyles.bodyMd.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          if (route.roads.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < route.roads.length; i++) ...[
                  if (i > 0)
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 14,
                      color: AppColors.textSecondary,
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSubtle,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      route.roads[i],
                      style: AppTextStyles.label.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            )
          else
            Text(
              '未获取到途经道路名称',
              style: AppTextStyles.label.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          if (route.steps.isNotEmpty) ...[
            const Divider(height: 24),
            InkWell(
              onTap: () => setState(() => _stepsExpanded = !_stepsExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text(
                      _stepsExpanded
                          ? '收起详细分段'
                          : '查看详细分段路线（${route.steps.length} 段）',
                      style: AppTextStyles.label.copyWith(
                        color: AppColors.voice,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _stepsExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: AppColors.voice,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
            if (_stepsExpanded) ...[
              const SizedBox(height: AppSpacing.s2),
              for (var i = 0; i < route.steps.length; i++) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Expanded(
                        child: Text(
                          route.steps[i].instruction,
                          style: AppTextStyles.label.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Text(
                        RouteTrafficInfo.formatDistance(
                          route.steps[i].distanceMeters,
                          compactUnit: true,
                        ),
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildWeatherCard(RouteTrafficInfo info) {
    final live = info.weather;
    final forecast = info.forecast;

    if (live == null && forecast == null && info.weatherLine == null) {
      return const SizedBox.shrink();
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.wb_sunny_outlined,
                size: 18,
                color: AppColors.voice,
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(
                '事发地气象与火场风向',
                style: AppTextStyles.bodyMd.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (live?.city != null && live!.city.isNotEmpty)
                Text(
                  live.city,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          if (live != null) ...[
            Row(
              children: [
                if (live.text.isNotEmpty) ...[
                  Text(
                    live.text,
                    style: AppTextStyles.h2.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                ],
                if (live.temperature.isNotEmpty) ...[
                  Text(
                    '${live.temperature}℃',
                    style: AppTextStyles.h2.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                ],
                if (live.humidity.isNotEmpty)
                  Text(
                    '湿度 ${live.humidity}%',
                    style: AppTextStyles.bodyMd.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3,
                vertical: AppSpacing.s2,
              ),
              decoration: BoxDecoration(
                color: AppColors.voice.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(
                  color: AppColors.voice.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.air_rounded,
                    size: 18,
                    color: AppColors.voice,
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      live.windLabel.isNotEmpty
                          ? '风向：${live.windLabel}'
                          : '风向风力以现场实测为准',
                      style: AppTextStyles.label.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              '出警提示：请结合事发地风向选择上风或侧上风方向停车与集结。',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ] else if (info.weatherLine != null)
            Text(
              info.weatherLine!,
              style: AppTextStyles.bodyMd.copyWith(color: AppColors.textPrimary),
            ),
          if (forecast != null &&
              (forecast.dayWeather.isNotEmpty ||
                  forecast.nightWeather.isNotEmpty)) ...[
            const Divider(height: 20),
            Row(
              children: [
                Text(
                  '今日预报：白天 ${forecast.dayWeather} ${forecast.dayTemp}℃ · 夜间 ${forecast.nightWeather} ${forecast.nightTemp}℃',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomBar(RouteTrafficInfo info) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('route-traffic-copy'),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('复制路况简报'),
              onPressed: _copySummary,
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: FilledButton.icon(
              key: const Key('route-traffic-navigate'),
              icon: const Icon(Icons.navigation_rounded, size: 18),
              label: const Text('高德导航'),
              onPressed: _startNavigation,
            ),
          ),
        ],
      ),
    );
  }
}
