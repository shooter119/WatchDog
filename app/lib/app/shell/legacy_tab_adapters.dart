import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../design_system/design_system.dart';
import '../../features/video/ui/video_playback_surface.dart';
import '../../models/models.dart';
import '../../pages/incident_import_page.dart';
import '../../pages/incident_selection_overlay.dart';
import '../../pages/settings_page.dart';
import '../../pages/video_resource_admin_page.dart';
import '../../pages/watermark_settings_page.dart';
import '../../services/video_playback_session.dart';
import '../../state/app_controller.dart';
import 'command_home_assembly.dart';
import 'shell_copilot_adapter.dart';
import 'shell_monitor_adapter.dart';
import 'shell_voice_bridge.dart';
import 'shell_voice_coordinator.dart';

/// 新外壳 4 个 Tab 及浮层的可注入覆写槽位。
///
/// - M3a~M3e 已完成 Tab 0/1/2 及全套现场工具/视频/PiP 替换；M3f~M3g 替换 Tab 3 与启动引导；
/// - 单元测试可注入轻量桩组件，避免拉起全量页面依赖。
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

  /// 悬浮视频小窗覆写构造器。
  final WidgetBuilder? floatingVideoBuilder;
}

/// 过渡期 4-Tab 装配与 M3f/M3g 旧页隔离适配层（M4 整体清退旧页面后删除）。
///
/// 集中隔离对尚未替换的旧 `pages/`（Tab 3 设置、启动门禁、水印设置、视频源管理、
/// 警情导入）的全部引用，保证 `command_app_shell.dart`、`command_home_assembly.dart`
/// 与 `field_tools_router.dart` 保持零旧页面、零旧主题、零旧组件依赖。
class LegacyTabAdapters {
  LegacyTabAdapters({
    required this.controller,
    required this.voiceBridge,
    required this.videoPlayback,
    required this.homeAssembly,
    required this.monitorAdapter,
    required this.copilotAdapter,
    required this.voiceCoordinator,
    required this.onSelectTab,
    required this.onShowMessage,
    this.overrides = const ShellTabOverrides(),
  });

  final AppController controller;
  final ShellVoiceBridge voiceBridge;
  final VideoPlaybackSession videoPlayback;
  final CommandHomeAssembly homeAssembly;
  final ShellMonitorAdapter monitorAdapter;
  final ShellCopilotAdapter copilotAdapter;
  final ShellVoiceCoordinator voiceCoordinator;
  final ValueChanged<int> onSelectTab;
  final ShellVoiceMessageCallback onShowMessage;
  final ShellTabOverrides overrides;

  /// M3f 过渡期桥接：打开旧版水印设置页。
  static Future<void> openLegacyWatermarkSettings(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const WatermarkSettingsPage()),
    );
  }

  /// M3f 过渡期桥接：打开旧版视频监控源管理页。
  static Future<void> openLegacyVideoResourceAdmin(
    BuildContext context,
    AppController controller,
  ) {
    final api = controller.api;
    if (api == null) return Future<void>.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => VideoResourceAdminPage(api: api)),
    );
  }

  /// M3g 过渡期桥接：打开旧版警情资料导入页。
  static Future<bool?> openLegacyIncidentImport(
    BuildContext context,
    AppController controller, {
    bool chooseSourceOnOpen = false,
  }) {
    final api = controller.api;
    final incident = controller.currentIncident;
    if (api == null || incident == null) return Future<bool?>.value(null);
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => IncidentImportPage(
          api: api,
          incident: incident,
          chooseSourceOnOpen: chooseSourceOnOpen,
        ),
      ),
    );
  }

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
    return homeAssembly.buildCommandHomePage(context);
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

  /// 构建认证/选警情启动门禁浮层（M3g 前暂用 `IncidentSelectionOverlay`）。
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
      onClaimExternal: (ExternalIncident ext) async {
        try {
          await controller.claimExternalIncident(ext);
        } catch (error) {
          onShowMessage('认领建档失败：$error', duration: const Duration(seconds: 3));
          rethrow;
        }
      },
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
          controller.selectIncident(incident.id, knownIncident: incident),
      onCreate: () => _createIncidentFromGate(context),
    );
  }

  Future<void> _createIncidentFromGate(BuildContext context) async {
    try {
      await controller.createIncident();
    } on IncidentCreateConflictException catch (conflict) {
      if (!context.mounted) return;
      final join = await showCommandSheet<bool>(
        context: context,
        title: '已有刚创建的警情',
        builder: (BuildContext ctx) => Text(
          '${conflict.existing.displayName}\n\n${conflict.message}',
          style: ctx.ds.typography.body.copyWith(
            color: ctx.ds.colors.textSecondary,
          ),
        ),
        actionsBuilder: (BuildContext ctx) => <Widget>[
          CommandButton(
            label: '暂不加入',
            variant: CommandButtonVariant.secondary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          CommandButton(
            label: '加入现有警情',
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      );
      if (join != true) return;
      try {
        await controller.selectIncident(
          conflict.existing.id,
          knownIncident: conflict.existing,
        );
      } catch (joinError) {
        onShowMessage('加入警情失败：$joinError', duration: const Duration(seconds: 3));
      }
    }
  }

  /// 构建 DS v3.0 应用内悬浮视频小窗。
  Widget buildFloatingVideo(
    BuildContext context, {
    required VoidCallback onFullscreen,
  }) {
    final override = overrides.floatingVideoBuilder;
    if (override != null) return override(context);
    return FloatingVideoOverlay(
      session: videoPlayback,
      onFullscreen: onFullscreen,
    );
  }

  /// 构建 DS v3.0 全屏视频播放路由。
  Route<void> buildFullscreenVideoRoute() {
    return MaterialPageRoute<void>(
      builder: (_) => VideoFullscreenScreen(session: videoPlayback),
    );
  }

  /// 构建 DS v3.0 火场日志时间线二级页面路由。
  Route<void> buildNotesRoute() => homeAssembly.buildNotesRoute();

  /// 构建 DS v3.0 警情详情二级页面路由（供智能辅助警情胶囊跳转）。
  Route<void>? buildIncidentDetailsRoute() =>
      homeAssembly.buildIncidentDetailsRoute();
}
