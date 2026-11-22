import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_system/design_system.dart';

import '../../features/command_home/ui/sheets/tactical_brief_command_sheet.dart';
import '../../features/hazmat/ui/hazmat_page.dart';
import '../../features/incident/ui/widgets/incident_key_site_card.dart';
import '../../features/key_sites/data/models/key_sites.dart';
import '../../features/key_sites/ui/key_site_detail_page.dart';
import '../../features/key_sites/ui/key_sites_page.dart';
import '../../features/map/ui/location_share_sheet.dart';
import '../../features/map/ui/orthomap_page.dart';
import '../../features/map/ui/route_traffic_page.dart';
import '../../features/map/ui/scene_map_page.dart';
import '../../features/media/state/media_gateway.dart';
import '../../features/media/ui/camera_page.dart';
import '../../features/media/ui/media_gallery_page.dart';
import '../../features/media/ui/media_review_page.dart';
import '../../features/video/state/video_resources_store.dart';
import '../../features/video/ui/video_resources_page.dart';
import '../../features/water_sources/ui/water_sources_page.dart';
import '../../services/local_media_store.dart';
import '../../services/tactical_brief_engine.dart';
import '../../services/video_playback_session.dart';
import '../../state/app_controller.dart';
import 'field_tools_gateways.dart';

typedef IncidentImportOpener =
    Future<bool?> Function(BuildContext context, {bool chooseSourceOnOpen});

/// 新外壳现场工具与工具内二级页统一路由器（M3e/M3f/M3g 全量 DS v3.0 接线）。
///
/// 严禁引入任何旧 `pages/`、`theme/`、`widgets/`；跨 Feature 的水印设置、视频源管理
/// 与警情导入回调由外壳装配层统一注入。
class FieldToolsRouter {
  FieldToolsRouter({
    required this.controller,
    required this.videoPlayback,
    required this.onVideoFloating,
    required this.onOpenIncidentDetails,
    required this.onOpenWatermarkSettings,
    required this.onOpenVideoResourceAdmin,
    required this.onOpenIncidentImport,
  }) : gateways = FieldToolsGateways(controller);

  final AppController controller;
  final VideoPlaybackSession videoPlayback;
  final VoidCallback onVideoFloating;
  final Future<void> Function(BuildContext context) onOpenIncidentDetails;
  final Future<void> Function(BuildContext context) onOpenWatermarkSettings;
  final Future<void> Function(BuildContext context) onOpenVideoResourceAdmin;
  final IncidentImportOpener onOpenIncidentImport;
  final FieldToolsGateways gateways;

  Future<bool> _ensureFormalMember(
    BuildContext context, {
    required String toolName,
    required String reason,
  }) async {
    if (!controller.isGuest) return true;
    final goAuth = await showCommandSheet<bool>(
      context: context,
      title: '需要转为正式队员',
      subtitle: '「$toolName」仅向已认证单位成员开放',
      builder: (BuildContext sheetContext) {
        final ds = sheetContext.ds;
        return Text(
          reason,
          style: ds.typography.body.copyWith(color: ds.colors.textSecondary),
        );
      },
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          key: const Key('guest-tool-gate-cancel-btn'),
          label: '暂不认证',
          variant: CommandButtonVariant.secondary,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          key: const Key('guest-tool-gate-auth-btn'),
          label: '去完成认证',
          variant: CommandButtonVariant.primary,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    );
    if (goAuth == true) {
      unawaited(controller.leaveUnit());
    }
    return false;
  }

  Future<void> openKeySites(BuildContext context) async {
    if (!await _ensureFormalMember(
      context,
      toolName: '重点单位库',
      reason: '重点单位库包含辖区预案与内部建筑图纸资料，请先登录或加入救援单位后再查阅。',
    )) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => KeySitesPage(gateway: gateways.buildKeySiteGateway()),
      ),
    );
  }

  Future<KeySiteCandidate?> pickKeySiteForIncident(BuildContext context) async {
    final picked = await Navigator.of(context).push<KeySiteSummary>(
      MaterialPageRoute<KeySiteSummary>(
        builder: (_) => KeySitesPage(
          gateway: gateways.buildKeySiteGateway(),
          selectForIncident: true,
        ),
      ),
    );
    if (picked == null) return null;
    return KeySiteCandidate(
      siteId: picked.id,
      name: picked.name,
      version: picked.version,
    );
  }

  void openKeySiteDetail(
    BuildContext context, {
    required String siteId,
    int? version,
    String? incidentId,
  }) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => KeySiteDetailPage(
          gateway: gateways.buildKeySiteGateway(),
          siteId: siteId,
          version: version,
          incidentId: incidentId,
        ),
      ),
    );
  }

  Future<void> openHazmat(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HazmatPage(gateway: gateways.buildHazmatGateway()),
    ),
  );

  Future<void> openCamera(BuildContext context) {
    final gateway = gateways.buildMediaGateway();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CameraPage(
          gateway: gateway,
          onOpenWatermarkSettings: onOpenWatermarkSettings,
          onOpenGallery: openMediaGallery,
          onOpenReview: openMediaReview,
        ),
      ),
    );
  }

  Future<void> openMediaGallery(BuildContext context) {
    final gateway = gateways.buildMediaGateway();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaGalleryPage(
          gateway: gateway,
          onOpenReview: (BuildContext ctx, LocalMedia media) =>
              openMediaReview(ctx, media, deriving: false),
        ),
      ),
    );
  }

  Future<MediaReviewOutcome?> openMediaReview(
    BuildContext context,
    LocalMedia media, {
    required bool deriving,
  }) => Navigator.of(context).push<MediaReviewOutcome>(
    MaterialPageRoute<MediaReviewOutcome>(
      builder: (_) => MediaReviewPage(
        gateway: gateways.buildMediaGateway(),
        media: media,
        deriving: deriving,
      ),
    ),
  );

  Future<void> openLocationShare(BuildContext context) =>
      showLocationShareSheet(
        context,
        gateway: gateways.buildLocationShareGateway(),
        readIncidentName: () => controller.currentIncident?.displayName ?? '',
      );

  Future<void> openVideoResources(BuildContext context) async {
    if (!await _ensureFormalMember(
      context,
      toolName: '视频资源',
      reason: '实时视频与监控通道仅限已认证单位内部调度查看，请先登录或加入救援单位。',
    )) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _VideoResourcesRouteHost(
          controller: controller,
          gateways: gateways,
          videoPlayback: videoPlayback,
          onOpenAdmin: onOpenVideoResourceAdmin,
          onVideoFloating: onVideoFloating,
        ),
      ),
    );
  }

  Future<void> openRouteTraffic(BuildContext context) async {
    if (!await _ensureFormalMember(
      context,
      toolName: '路况查询',
      reason: '火场救援路径研判与警情联动信息仅对已认证单位成员开放，请先完成认证。',
    )) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext routeCtx) => RouteTrafficPage(
          gateway: gateways.buildRouteTrafficGateway(),
          readCurrentIncident: gateways.readRouteIncidentContext,
          onRequestIncidentSelection: () {
            Navigator.of(routeCtx).pop();
            controller.requestIncidentSelection();
          },
          onEditIncidentDetails: () => onOpenIncidentDetails(routeCtx),
          onImportIncidentDetails: () async {
            final applied = await onOpenIncidentImport(
              routeCtx,
              chooseSourceOnOpen: false,
            );
            final inc = controller.currentIncident;
            if (applied == true && inc != null) {
              await controller.refreshIncidentData(inc.id);
            }
          },
        ),
      ),
    );
  }

  Future<void> openTacticalBrief(BuildContext context) async {
    if (!await _ensureFormalMember(
      context,
      toolName: '警情上报',
      reason: '正式作战简报上报涉及单位指挥链条核验，请先转为正式队员后再生成上报。',
    )) {
      return;
    }
    if (!context.mounted) return;
    final brief = TacticalBriefEngine.formatObjectiveBrief(
      incident: controller.currentIncident,
      forces: controller.forces,
      entries: controller.entries,
      notes: controller.notes,
    );
    await showTacticalBriefCommandSheet(context, briefText: brief);
  }

  Future<void> openSceneMap(BuildContext context) async {
    if (!await _ensureFormalMember(
      context,
      toolName: '现场地图',
      reason: '现场作战态势标注涉及协同图层权限，请先完成单位认证后再使用。',
    )) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SceneMapPage(gateway: gateways.buildSceneMapGateway()),
      ),
    );
  }

  Future<void> openOrthomap(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => OrthomapPage(gateway: gateways.buildOrthomapGateway()),
    ),
  );

  Future<void> openWaterSources(BuildContext context) async {
    if (!await _ensureFormalMember(
      context,
      toolName: '周边水源',
      reason: '辖区消火栓与战备水源台账属单位执勤数据，请先登录或加入单位后再查看。',
    )) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            WaterSourcesPage(gateway: gateways.buildWaterSourcesGateway()),
      ),
    );
  }
}

class _VideoResourcesRouteHost extends StatefulWidget {
  const _VideoResourcesRouteHost({
    required this.controller,
    required this.gateways,
    required this.videoPlayback,
    required this.onOpenAdmin,
    required this.onVideoFloating,
  });

  final AppController controller;
  final FieldToolsGateways gateways;
  final VideoPlaybackSession videoPlayback;
  final Future<void> Function(BuildContext context) onOpenAdmin;
  final VoidCallback onVideoFloating;

  @override
  State<_VideoResourcesRouteHost> createState() =>
      _VideoResourcesRouteHostState();
}

class _VideoResourcesRouteHostState extends State<_VideoResourcesRouteHost> {
  late final VideoResourcesStore _store;

  @override
  void initState() {
    super.initState();
    _store = VideoResourcesStore(
      repositoryProvider: widget.gateways.buildVideoRepository,
      isGuestProvider: () => widget.controller.isGuest,
      needsAuthenticationProvider: () => widget.controller.needsAuthentication,
      authListenable: widget.controller,
    );
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) => VideoResourcesPage(
        store: _store,
        playback: widget.videoPlayback,
        onOpenAdmin: widget.onOpenAdmin,
        onAuthenticate: widget.controller.leaveUnit,
        onVideoFloating: widget.onVideoFloating,
        isOffline: widget.controller.connectionLost,
      ),
    );
  }
}
