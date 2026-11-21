import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/design_system.dart';
import '../../models/models.dart';
import '../../pages/home_page.dart';
import '../../pages/incident_details_page.dart';
import '../../pages/incident_selection_overlay.dart';
import '../../pages/notes_page.dart';
import '../../pages/settings_page.dart';
import '../../pages/video_playback_surface.dart';
import '../../services/video_playback_session.dart';
import '../../state/app_controller.dart';
import 'shell_copilot_adapter.dart';
import 'shell_monitor_adapter.dart';
import 'shell_voice_bridge.dart';
import 'shell_voice_coordinator.dart';

/// 新外壳 4 个 Tab 及过渡期浮层的可注入覆写槽位。
///
/// - M3a~M3g 逐里程碑把新 DS v3.0 页面注入对应槽位，无需改动 `CommandAppShell`；
/// - 单元测试可注入轻量桩组件，避免拉起全量既有页面依赖。
@immutable
class ShellTabOverrides {
  const ShellTabOverrides({
    this.commandTabBuilder,
    this.monitorTabBuilder,
    this.copilotTabBuilder,
    this.mineTabBuilder,
    this.startupGateBuilder,
    this.floatingVideoBuilder,
  });

  /// Tab 0（指挥台）覆写构造器。
  final WidgetBuilder? commandTabBuilder;

  /// Tab 1（现场监控）覆写构造器。
  final WidgetBuilder? monitorTabBuilder;

  /// Tab 2（智能辅助）覆写构造器。
  final WidgetBuilder? copilotTabBuilder;

  /// Tab 3（我的）覆写构造器。
  final WidgetBuilder? mineTabBuilder;

  /// 未认证/未选警情门禁浮层覆写构造器（M3g 替换为新全屏流程）。
  final WidgetBuilder? startupGateBuilder;

  /// 悬浮视频小窗覆写构造器（M3e 替换为新视频模块）。
  final WidgetBuilder? floatingVideoBuilder;
}

/// M2 过渡期 4-Tab 适配器（M4 整体切换并清退旧页面后删除）。
///
/// 集中隔离对既有 `pages/` 的全部引用，使 `command_app_shell.dart` 与
/// `shell_voice_bridge.dart` 保持零旧页面、零旧主题依赖。
class LegacyTabAdapters {
  LegacyTabAdapters({
    required this.controller,
    required this.voiceBridge,
    required this.videoPlayback,
    required this.monitorAdapter,
    required this.copilotAdapter,
    required this.voiceCoordinator,
    required this.onSelectTab,
    required this.onOpenNotes,
    this.overrides = const ShellTabOverrides(),
  });

  /// 过渡期指挥台顶部「火场日志」入口语义 Key。
  static const Key openNotesButtonKey = Key('shell-open-notes-btn');

  final AppController controller;
  final ShellVoiceBridge voiceBridge;
  final VideoPlaybackSession videoPlayback;
  final ShellMonitorAdapter monitorAdapter;
  final ShellCopilotAdapter copilotAdapter;
  final ShellVoiceCoordinator voiceCoordinator;
  final ValueChanged<int> onSelectTab;
  final VoidCallback onOpenNotes;
  final ShellTabOverrides overrides;

  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();

  /// 生成供 `ShellVoiceBridge` 使用的全局语音与智能辅助语音执行槽位。
  ShellVoiceSlot createVoiceSlot() {
    return ShellVoiceSlot(
      beginCommandRecording: () => unawaited(voiceCoordinator.beginRecording()),
      finishCommandRecording: () =>
          unawaited(voiceCoordinator.finishRecording()),
      beginCopilotRecording: copilotAdapter.beginRecording,
      finishCopilotRecording: copilotAdapter.finishRecording,
      dismissCopilotKeyboard: copilotAdapter.dismissKeyboard,
      submitCopilotQuestion: copilotAdapter.submitQuestion,
      supportsInPlaceCommandRecording: true,
    );
  }

  /// 构建按 0-indexed 排列的 4 个 Tab 子页面（0 指挥台 / 1 现场监控 / 2 智能辅助 / 3 我的）。
  List<Widget> buildTabs(BuildContext context) {
    return <Widget>[
      _buildCommandTab(context),
      _buildMonitorTab(context),
      _buildCopilotTab(context),
      _buildMineTab(context),
    ];
  }

  Widget _buildCommandTab(BuildContext context) {
    final override = overrides.commandTabBuilder;
    if (override != null) return override(context);

    final home = HomePage(
      key: _homeKey,
      controller: controller,
      autoRecord: voiceBridge.pendingAutoRecord,
      onAutoRecordConsumed: voiceBridge.consumePendingAutoRecord,
      onRecordingChanged: voiceBridge.setCommandRecording,
      onProcessingChanged: voiceBridge.setCommandProcessing,
      onNoteIntent: (String text) => unawaited(voiceBridge.routeNoteIntent(text)),
      onAskIntent: voiceBridge.routeAskIntent,
      onEntryConfirmed: voiceBridge.routeEntryConfirmed,
      videoPlayback: videoPlayback,
      onVideoFloating: () => onSelectTab(ShellVoiceBridge.commandTabIndex),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SafeArea(
          bottom: false,
          child: _TransitionalNotesEntryBar(
            noteCount: controller.notes.length,
            onTap: onOpenNotes,
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: home,
          ),
        ),
      ],
    );
  }

  Widget _buildMonitorTab(BuildContext context) {
    final override = overrides.monitorTabBuilder;
    if (override != null) return override(context);
    return monitorAdapter.buildMonitorPage(
      context,
      onGoVoice: () => onSelectTab(ShellVoiceBridge.commandTabIndex),
    );
  }

  Widget _buildCopilotTab(BuildContext context) {
    final override = overrides.copilotTabBuilder;
    if (override != null) return override(context);
    return copilotAdapter.buildCopilotPage(
      context,
      onRecordingChanged: voiceBridge.setCopilotRecording,
      onProcessingChanged: voiceBridge.setCopilotProcessing,
    );
  }

  Widget _buildMineTab(BuildContext context) {
    final override = overrides.mineTabBuilder;
    if (override != null) return override(context);
    return SettingsPage(controller: controller);
  }

  /// 构建认证/选警情启动门禁浮层（默认复用既有 `IncidentSelectionOverlay`）。
  Widget buildStartupGate(BuildContext context) {
    final override = overrides.startupGateBuilder;
    if (override != null) return override(context);
    return IncidentSelectionOverlay(
      onEnterWithoutIncident: () {
        controller.enterWithoutIncident();
        onSelectTab(ShellVoiceBridge.commandTabIndex);
      },
      authenticationRequired: controller.needsAuthentication,
      activeIncidents: controller.activeIncidents,
      externalIncidents: controller.externalIncidents,
      loading:
          !controller.needsAuthentication &&
          (controller.syncing || controller.api == null),
      externalLoading: controller.externalIncidentsLoading,
      onRefreshExternal: ({bool forceRefresh = false}) =>
          controller.fetchExternalIncidents(forceRefresh: forceRefresh),
      onClaimExternal: (ExternalIncident ext) =>
          _homeKey.currentState?.claimExternalIncidentFromGate(ext) ??
          controller.claimExternalIncident(ext),
      onAuthenticate: (String unitName, String name, String code) =>
          controller.authenticate(
            unitName: unitName,
            realName: name,
            unitCode: code,
          ),
      onEnterGuestMode: () => controller.enterGuestMode(),
      onApply: (
        String unitName,
        String name,
        String code, {
        String? stationName,
        String? phone,
        String? applyReason,
      }) => controller.applyUnitMembership(
        unitName: unitName,
        unitCode: code,
        realName: name,
        stationName: stationName,
        phone: phone,
        applyReason: applyReason,
      ),
      onSelect: (Incident incident) =>
          _homeKey.currentState?.selectIncidentFromGate(incident) ??
          controller.selectIncident(incident.id, knownIncident: incident),
      onCreate: () =>
          _homeKey.currentState?.createIncidentFromGate() ??
          controller.createIncident(),
    );
  }

  /// 构建悬浮视频小窗。
  Widget buildFloatingVideo(
    BuildContext context, {
    required VoidCallback onFullscreen,
  }) {
    final override = overrides.floatingVideoBuilder;
    if (override != null) return override(context);
    return FloatingVideoWindow(
      session: videoPlayback,
      onFullscreen: onFullscreen,
    );
  }

  /// 构建全屏视频播放路由。
  Route<void> buildFullscreenVideoRoute() {
    return MaterialPageRoute<void>(
      builder: (_) => VideoFullscreenPage(session: videoPlayback),
    );
  }

  /// 构建过渡期火场日志二级页面路由（M3c 将日志时间线整合进指挥台后移除）。
  Route<void> buildNotesRoute() {
    return MaterialPageRoute<void>(
      builder: (_) => _TransitionalNotesScreen(controller: controller),
    );
  }

  /// 构建过渡期警情背景资料二级页面路由（供智能辅助警情胶囊跳转，M3c 后替换）。
  Route<void>? buildIncidentDetailsRoute() {
    final api = controller.api;
    final incident = controller.currentIncident;
    if (api == null || incident == null) return null;
    return MaterialPageRoute<void>(
      builder: (_) => IncidentDetailsPage(
        api: api,
        incident: incident,
        controller: controller,
      ),
    );
  }
}

/// 过渡期指挥台顶部火场日志入口条（完全采用 Design System v3.0 语义 Token）。
class _TransitionalNotesEntryBar extends StatelessWidget {
  const _TransitionalNotesEntryBar({
    required this.noteCount,
    required this.onTap,
  });

  final int noteCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.md,
        DsSpacing.sm,
        DsSpacing.md,
        DsSpacing.xs,
      ),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderMd,
          side: BorderSide(color: colors.border, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: LegacyTabAdapters.openNotesButtonKey,
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.event_note_outlined,
                    size: DsSizes.iconMd,
                    color: colors.brandText,
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  Expanded(
                    child: Text(
                      '火场日志',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.body.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  Text(
                    '$noteCount 条',
                    style: typo.captionTabular.copyWith(
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: DsSpacing.xs),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: DsSizes.iconMd,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 过渡期火场日志二级页面容器。
class _TransitionalNotesScreen extends StatelessWidget {
  const _TransitionalNotesScreen({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Scaffold(
      backgroundColor: ds.colors.canvas,
      appBar: AppBar(title: const Text('火场日志')),
      body: AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, _) {
          return MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: NotesPage(controller: controller),
          );
        },
      ),
    );
  }
}
