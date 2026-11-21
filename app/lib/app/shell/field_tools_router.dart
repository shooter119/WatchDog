import 'package:flutter/material.dart';

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

  Future<void> openKeySites(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => KeySitesPage(gateway: gateways.buildKeySiteGateway()),
    ),
  );

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

  Future<void> openVideoResources(BuildContext context) =>
      Navigator.of(context).push(
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

  Future<void> openRouteTraffic(BuildContext context) =>
      Navigator.of(context).push(
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

  Future<void> openTacticalBrief(BuildContext context) {
    final brief = TacticalBriefEngine.formatObjectiveBrief(
      incident: controller.currentIncident,
      forces: controller.forces,
      entries: controller.entries,
      notes: controller.notes,
    );
    return showTacticalBriefCommandSheet(context, briefText: brief);
  }

  Future<void> openSceneMap(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SceneMapPage(gateway: gateways.buildSceneMapGateway()),
    ),
  );

  Future<void> openOrthomap(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => OrthomapPage(gateway: gateways.buildOrthomapGateway()),
    ),
  );

  Future<void> openWaterSources(BuildContext context) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              WaterSourcesPage(gateway: gateways.buildWaterSourcesGateway()),
        ),
      );
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
