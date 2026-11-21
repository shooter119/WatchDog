import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/sync/sync_store.dart';
import '../../design_system/design_system.dart';
import '../../features/command_home/ui/command_home_page.dart';
import '../../features/command_home/ui/sheets/connection_detail_sheet.dart';
import '../../features/command_home/ui/widgets/commander_brief_card.dart';
import '../../features/command_home/ui/widgets/field_tools_grid_section.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/incident/data/models/incident_force.dart';
import '../../features/incident/ui/incident_details_screen.dart';
import '../../features/incident/ui/widgets/incident_situation_card.dart';
import '../../features/notes/data/models/note.dart';
import '../../features/notes/state/notes_store.dart';
import '../../features/notes/ui/notes_timeline_screen.dart';
import '../../features/notes/ui/widgets/note_preview_section.dart';
import '../../services/tactical_brief_engine.dart';
import '../../services/video_playback_session.dart';
import '../../state/app_controller.dart';
import 'command_home_incident_actions.dart';
import 'field_tools_router.dart';

/// 指挥台首页与日志/警情域接线器（M3c + M3e，新外壳 Tab 0）。
///
/// 统一拼装 `CommandHomePage`、`IncidentSituationCard`、`CommanderBriefCard`、
/// `FieldToolsGridSection`、`NotePreviewSection`、`NotesTimelineScreen` 与
/// `IncidentDetailsScreen`，保持零旧 `pages/`、`theme/`、`widgets/` 依赖。
class CommandHomeAssembly {
  CommandHomeAssembly({
    required this.controller,
    required this.onOpenMonitor,
    required this.onOpenNotes,
    required this.onOpenIncidentImport,
    required this.onShowMessage,
    FieldToolsRouter? toolsRouter,
    VideoPlaybackSession? videoPlayback,
    VoidCallback? onVideoFloating,
    Future<void> Function(BuildContext context)? onOpenWatermarkSettings,
    Future<void> Function(BuildContext context)? onOpenVideoResourceAdmin,
  }) : assert(
         toolsRouter != null ||
             (videoPlayback != null &&
                 onVideoFloating != null &&
                 onOpenWatermarkSettings != null &&
                 onOpenVideoResourceAdmin != null),
       ) {
    this.toolsRouter =
        toolsRouter ??
        FieldToolsRouter(
          controller: controller,
          videoPlayback: videoPlayback!,
          onVideoFloating: onVideoFloating!,
          onOpenIncidentDetails: openIncidentDetails,
          onOpenWatermarkSettings: onOpenWatermarkSettings!,
          onOpenVideoResourceAdmin: onOpenVideoResourceAdmin!,
          onOpenIncidentImport: onOpenIncidentImport,
        );
    incidentActions = CommandHomeIncidentActions(
      controller: controller,
      toolsRouter: this.toolsRouter,
      onOpenIncidentImport: onOpenIncidentImport,
      onShowMessage: onShowMessage,
    );
    _notesStore = _ControllerNotesStore(controller);
    controller.addListener(_onControllerChanged);
  }

  final AppController controller;
  late final FieldToolsRouter toolsRouter;
  final VoidCallback onOpenMonitor;
  final VoidCallback onOpenNotes;
  final IncidentImportOpener onOpenIncidentImport;
  final void Function(String message, {Duration duration}) onShowMessage;
  late final CommandHomeIncidentActions incidentActions;

  late final _ControllerNotesStore _notesStore;
  bool _disposed = false;

  NotesStore get notesStore => _notesStore;

  void _onControllerChanged() {
    if (_disposed) return;
    _notesStore.syncFromController();
  }

  DsConnectionState resolveConnectionState() {
    if (controller.isGuest) return DsConnectionState.online;
    if (controller.syncing) return DsConnectionState.reconnecting;
    if (controller.connectionLost) return DsConnectionState.offline;
    if (controller.syncConnectionState != SyncConnectionState.connected &&
        controller.syncConnectionState != SyncConnectionState.stopped) {
      return DsConnectionState.reconnecting;
    }
    return DsConnectionState.online;
  }

  DsStatus _highestRiskStatus(AirSafetySummary airSummary) {
    return switch (airSummary.level) {
      AirSafetyLevel.critical => DsStatus.alarm,
      AirSafetyLevel.warning => DsStatus.caution,
      AirSafetyLevel.normal => DsStatus.safe,
      AirSafetyLevel.idle => DsStatus.neutral,
    };
  }

  /// 构建新外壳 Tab 0（指挥台）页面。
  Widget buildCommandHomePage(BuildContext context) {
    final incident = controller.currentIncident;
    final connState = resolveConnectionState();
    final intel = TacticalBriefEngine.extractIntelligence(controller.notes);
    final airSummary = TacticalBriefEngine.extractAirSafetySummary(
      controller.entries,
    );

    final tools = FieldToolsGridSection.buildDefaultTools(
      onKeySites: () => unawaited(toolsRouter.openKeySites(context)),
      onHazmat: () => unawaited(toolsRouter.openHazmat(context)),
      onCamera: () => unawaited(toolsRouter.openCamera(context)),
      onLocationShare: () => unawaited(toolsRouter.openLocationShare(context)),
      onVideoResources: () =>
          unawaited(toolsRouter.openVideoResources(context)),
      onRouteTraffic: () => unawaited(toolsRouter.openRouteTraffic(context)),
      onTacticalBrief: () => unawaited(toolsRouter.openTacticalBrief(context)),
      onSceneMap: () => unawaited(toolsRouter.openSceneMap(context)),
      onWaterSources: () => unawaited(toolsRouter.openWaterSources(context)),
    );

    final Widget? glanceSlot = airSummary.hasActive
        ? ValueListenableBuilder<int>(
            valueListenable: controller.clockTick,
            builder: (BuildContext context, _, _) {
              final liveSummary = TacticalBriefEngine.extractAirSafetySummary(
                controller.entries,
              );
              return CommanderBriefCard.fromIntelligence(
                summary: liveSummary,
                intelligence: intel,
                onTap: onOpenMonitor,
              );
            },
          )
        : null;

    return CommandHomePage(
      hasIncident: incident != null,
      incidentCardSlot: incident != null
          ? _buildIncidentCard(context, incident, connState, airSummary)
          : null,
      onChooseIncident: controller.requestIncidentSelection,
      glanceCardSlot: glanceSlot,
      tools: tools,
      notesPreviewSlot: NotePreviewSection(
        notes: _notesStore.notes,
        requiresIncident: controller.requiresIncident,
        onSeeAll: onOpenNotes,
        onNoteTap: (_) => onOpenNotes(),
      ),
      connectionState: connState,
      pendingSyncCount: controller.offlineReviewCount,
      isOffline: controller.connectionLost,
      onConnectionTap: () => unawaited(openConnectionDetail(context)),
      onRefresh: controller.refreshNow,
      bottomClearance: DsSizes.voiceProtrusion,
    );
  }

  Widget _buildIncidentCard(
    BuildContext context,
    Incident incident,
    DsConnectionState connState,
    AirSafetySummary airSummary,
  ) {
    return IncidentSituationCard(
      incident: incident,
      forces: controller.forces,
      hasActiveEntries: airSummary.hasActive,
      highestRiskStatus: _highestRiskStatus(airSummary),
      connectionState: connState,
      pendingSyncCount: controller.offlineReviewCount,
      onConnectionTap: () => unawaited(openConnectionDetail(context)),
      onRename: incidentActions.renameIncident,
      onAddForce: () => unawaited(incidentActions.editForce(context)),
      onImportInfo: () => unawaited(incidentActions.openImport(context)),
      onAdjustIncident: () =>
          unawaited(incidentActions.adjustIncidentLevel(context)),
      onDetails: () => unawaited(openIncidentDetails(context)),
      onEditForce: (IncidentForce f) =>
          unawaited(incidentActions.editForce(context, force: f)),
      onRemoveForce: (IncidentForce f) =>
          unawaited(incidentActions.removeForce(f)),
      onArchive: incidentActions.archiveIncident,
      onExit: incidentActions.exitIncident,
      keySiteSlot: incidentActions.buildKeySiteCard(incident),
    );
  }

  /// 弹出连接与同步状态详情抽屉。
  Future<void> openConnectionDetail(BuildContext context) {
    return showConnectionDetailSheet(
      context,
      listenable: controller,
      snapshotProvider: () => ConnectionDetailSnapshot(
        isGuest: controller.isGuest,
        syncing: controller.syncing,
        connectionLost: controller.connectionLost,
        syncConnectionState: controller.syncConnectionState,
        serverUrl: controller.api?.baseUrl ?? '',
        pendingSyncCount: controller.offlineReviewCount,
      ),
      onRetrySync: controller.refreshNow,
    );
  }

  /// 构建 DS v3.0 火场日志全量时间线二级页路由。
  Route<void> buildNotesRoute() {
    return MaterialPageRoute<void>(
      builder: (_) => ListenableBuilder(
        listenable: controller,
        builder: (BuildContext context, _) => NotesTimelineScreen(
          store: _notesStore,
          requiresIncident: controller.requiresIncident,
          connectionState: resolveConnectionState(),
          pendingSyncCount: controller.offlineReviewCount,
          isOffline: controller.connectionLost,
          onRefresh: controller.refreshNow,
          onOpenTacticalBrief: () =>
              unawaited(toolsRouter.openTacticalBrief(context)),
          onConnectionTap: () => unawaited(openConnectionDetail(context)),
          onRequestIncidentSelection: () {
            Navigator.of(context).pop();
            controller.requestIncidentSelection();
          },
        ),
      ),
    );
  }

  /// 构建 DS v3.0 警情详情页路由（供指挥台、智能辅助与路况页复用）。
  Route<void>? buildIncidentDetailsRoute([Incident? target]) {
    final incident = target ?? controller.currentIncident;
    if (incident == null) return null;
    return MaterialPageRoute<void>(
      builder: (_) => IncidentDetailsScreen(
        incident: incident,
        importRepository: incidentActions.buildImportRepository(incident.id),
        keySiteSlot: incidentActions.buildKeySiteCard(incident),
        onExitIncident: incident.isActive
            ? controller.exitCurrentIncident
            : null,
        onArchiveIncident: incident.isActive ? controller.archiveCurrent : null,
        onDetailsUpdated: () =>
            unawaited(controller.refreshIncidentData(incident.id)),
      ),
    );
  }

  /// 推入警情详情页并在返回后刷新当前警情数据。
  Future<void> openIncidentDetails(BuildContext context) async {
    final incident = controller.currentIncident;
    final route = buildIncidentDetailsRoute(incident);
    if (route == null || incident == null) return;
    await Navigator.of(context).push<void>(route);
    if (controller.api != null) {
      await controller.refreshIncidentData(incident.id);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_onControllerChanged);
    _notesStore.dispose();
  }
}

class _ControllerNotesStore extends NotesStore {
  _ControllerNotesStore(this._controller)
    : super(initialNotes: _controller.notes);

  final AppController _controller;

  void syncFromController() {
    if (disposed) return;
    setNotes(_controller.notes, notify: true);
  }

  @override
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    final created = await _controller.addNote(
      text,
      category: category,
      opId: opId,
    );
    syncFromController();
    return created;
  }

  @override
  Future<Note> addActionLog({
    required Iterable<String> names,
    required String action,
    required String category,
    Map<String, double>? pressuresMpa,
    String? opId,
  }) async {
    final created = await _controller.addActionLog(
      names: names,
      action: action,
      category: category,
      pressuresMpa: pressuresMpa,
      opId: opId,
    );
    syncFromController();
    return created;
  }

  @override
  Future<Note> updateNote(
    String id, {
    String? text,
    String? category,
  }) async {
    final updated = await _controller.updateNote(
      id,
      text: text,
      category: category,
    );
    syncFromController();
    return updated;
  }

  @override
  Future<void> deleteNote(String id) async {
    await _controller.deleteNote(id);
    syncFromController();
  }
}
