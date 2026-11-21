import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/video/ui/video_playback_surface.dart';
import '../../services/video_playback_session.dart';
import '../../state/app_controller.dart';
import 'command_home_assembly.dart';
import 'onboarding_assembly.dart';
import 'profile_hub_assembly.dart';
import 'shell_copilot_adapter.dart';
import 'shell_monitor_adapter.dart';
import 'shell_voice_bridge.dart';
import 'shell_voice_coordinator.dart';

/// 外壳 4 个 Tab 及浮层的可注入覆写槽位。
///
/// 单元测试可注入轻量桩组件，避免拉起全量页面依赖。
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

  /// 未认证/未选警情门禁浮层覆写构造器。
  final WidgetBuilder? startupGateBuilder;

  /// 悬浮视频小窗覆写构造器。
  final WidgetBuilder? floatingVideoBuilder;
}

/// 外壳 4-Tab 装配与路由 DI 适配层（Design System v3.0）。
class ShellTabAdapters {
  ShellTabAdapters({
    required this.controller,
    required this.voiceBridge,
    required this.videoPlayback,
    required this.homeAssembly,
    required this.monitorAdapter,
    required this.copilotAdapter,
    required this.profileHubAssembly,
    required this.onboardingAssembly,
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
  final ProfileHubAssembly profileHubAssembly;
  final OnboardingAssembly onboardingAssembly;
  final ShellVoiceCoordinator voiceCoordinator;
  final ValueChanged<int> onSelectTab;
  final ShellVoiceMessageCallback onShowMessage;
  final ShellTabOverrides overrides;

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
    return profileHubAssembly.buildProfileHubPage(context);
  }

  /// 构建 DS v3.0 全屏启动引导门禁（单位认证 -> 待审 -> 选警情）。
  Widget buildStartupGate(BuildContext context) {
    final override = overrides.startupGateBuilder;
    if (override != null) return override(context);
    return onboardingAssembly.buildStartupGate(context);
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
