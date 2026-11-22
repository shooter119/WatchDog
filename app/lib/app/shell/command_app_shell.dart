import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/app_logger.dart';
import '../../design_system/design_system.dart';
import '../../features/copilot/state/copilot_store.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/video/ui/pip_shell.dart';
import '../../features/voice/state/voice_intent_router.dart';
import '../../features/voice/state/voice_session_store.dart';
import '../../services/audio_service.dart';
import '../../services/diagnostic_log_service.dart';
import '../../services/foreground_keep_alive.dart';
import '../../services/system_pip.dart';
import '../../services/theme_controller.dart';
import '../../services/video_playback_session.dart';
import '../../state/app_controller.dart';
import 'command_home_assembly.dart';
import 'guest_banner_bar.dart';
import 'onboarding_assembly.dart';
import 'profile_hub_assembly.dart';
import 'shell_copilot_adapter.dart';
import 'shell_keys.dart';
import 'shell_monitor_adapter.dart';
import 'shell_nav_bar.dart';
import 'shell_tab_adapters.dart';
import 'shell_voice_bridge.dart';
import 'shell_voice_coordinator.dart';

/// Design System v3.0 新外壳根组件（4 Tab + 中置 64dp 语音指令键）。
///
/// 继承既有 `main.dart` 全部关键机制：昼白/暗曜主题瞬切、`WidgetsBindingObserver`
/// 恢复同步与视频 Surface 重挂、`SystemPip` 切换 [CommandPipShell]、悬浮视频小窗与全屏、
/// `PopScope` 启动门禁锁、[GuestBannerBar] 游客横幅及 0-indexed 4 Tab `IndexedStack`。
class CommandAppShell extends StatefulWidget {
  const CommandAppShell({
    super.key,
    required this.controller,
    this.chatAudioService,
    this.videoPlayback,
    this.voiceSlot,
    this.voiceSessionStore,
    this.voiceIntentRouter,
    this.copilotStore,
    this.enableStartupSideEffects = true,
    this.disposeController = false,
    this.tabOverrides,
    this.commandTabBuilder,
    this.monitorTabBuilder,
    this.copilotTabBuilder,
    this.mineTabBuilder,
    this.startupGateBuilder,
    this.floatingVideoBuilder,
  });

  final AppController controller;
  final AudioService? chatAudioService;
  final VideoPlaybackSession? videoPlayback;
  final ShellVoiceSlot? voiceSlot;
  final VoiceSessionStore? voiceSessionStore;
  final VoiceIntentRouter? voiceIntentRouter;
  final CopilotStore? copilotStore;

  /// 是否执行前台保活、控制器初始化及静默检查更新（Widget 测试可设为 `false`）。
  final bool enableStartupSideEffects;

  /// 是否在 `dispose` 时释放 [controller]（默认由调用方管理）。
  final bool disposeController;

  /// 可选聚合槽位覆写；单项 `*Builder` 优先级高于 `tabOverrides`。
  final ShellTabOverrides? tabOverrides;
  final WidgetBuilder? commandTabBuilder;
  final WidgetBuilder? monitorTabBuilder;
  final WidgetBuilder? copilotTabBuilder;
  final WidgetBuilder? mineTabBuilder;
  final WidgetBuilder? startupGateBuilder;
  final WidgetBuilder? floatingVideoBuilder;

  @override
  State<CommandAppShell> createState() => _CommandAppShellState();
}

class _CommandAppShellState extends State<CommandAppShell>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  late VideoPlaybackSession _videoPlayback;
  late bool _ownsVideoPlayback;
  late ShellVoiceBridge _voiceBridge;
  late ShellMonitorAdapter _monitorAdapter;
  late OnboardingAssembly _onboardingAssembly;
  late ProfileHubAssembly _profileHubAssembly;
  late CommandHomeAssembly _homeAssembly;
  late ShellCopilotAdapter _copilotAdapter;
  late ShellVoiceCoordinator _voiceCoordinator;
  late ShellTabAdapters _adapters;
  int _tab = ShellVoiceBridge.commandTabIndex;
  bool _warmSandNoticeScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsVideoPlayback = widget.videoPlayback == null;
    _videoPlayback = (widget.videoPlayback ?? VideoPlaybackSession())..addListener(_syncSystemPip);
    widget.controller.setPipActive(SystemPip.isActive.value);
    SystemPip.isActive.addListener(_handlePipActiveChanged);
    DiagnosticLogService.instance.setPage(_pageName(_tab));
    _voiceBridge = _createVoiceBridge();
    _monitorAdapter = _createMonitorAdapter();
    _onboardingAssembly = _createOnboardingAssembly();
    _profileHubAssembly = _createProfileHubAssembly();
    _homeAssembly = _createHomeAssembly();
    _copilotAdapter = _createCopilotAdapter();
    _voiceCoordinator = _createVoiceCoordinator();
    _adapters = _createAdapters();
    _voiceBridge.updateSlot(widget.voiceSlot ?? _adapters.createVoiceSlot());
    if (widget.enableStartupSideEffects) {
      unawaited(ForegroundKeepAlive.init().catchError(
        (Object e, StackTrace s) => AppLogger.error('ForegroundKeepAlive failed', tag: 'shell', error: e, stackTrace: s),
      ));
      unawaited(widget.controller.init());
      unawaited(widget.controller.checkUpdateSilently());
    }
  }

  @override
  void didUpdateWidget(covariant CommandAppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final videoChanged = !identical(oldWidget.videoPlayback, widget.videoPlayback);
    if (videoChanged) {
      _videoPlayback.removeListener(_syncSystemPip);
      if (_ownsVideoPlayback) _videoPlayback.dispose();
      _ownsVideoPlayback = widget.videoPlayback == null;
      _videoPlayback = (widget.videoPlayback ?? VideoPlaybackSession())..addListener(_syncSystemPip);
    }

    final controllerChanged = !identical(oldWidget.controller, widget.controller);
    if (controllerChanged) {
      _voiceBridge.dispose();
      _voiceBridge = _createVoiceBridge();
      _monitorAdapter.dispose();
      _monitorAdapter = _createMonitorAdapter();
      _onboardingAssembly = _createOnboardingAssembly();
      _profileHubAssembly.dispose();
      _profileHubAssembly = _createProfileHubAssembly();
      widget.controller.setPipActive(SystemPip.isActive.value);
    }

    if (controllerChanged || videoChanged) {
      _homeAssembly.dispose();
      _homeAssembly = _createHomeAssembly();
    }

    final copilotChanged = controllerChanged ||
        !identical(oldWidget.chatAudioService, widget.chatAudioService) ||
        !identical(oldWidget.copilotStore, widget.copilotStore);
    if (copilotChanged) {
      _copilotAdapter.dispose();
      _copilotAdapter = _createCopilotAdapter();
    }

    final voiceChanged = controllerChanged ||
        !identical(oldWidget.voiceSessionStore, widget.voiceSessionStore) ||
        !identical(oldWidget.voiceIntentRouter, widget.voiceIntentRouter);
    if (voiceChanged) {
      _voiceCoordinator.dispose();
      _voiceCoordinator = _createVoiceCoordinator();
    }

    final adaptersChanged = controllerChanged || videoChanged || copilotChanged || voiceChanged ||
        oldWidget.tabOverrides != widget.tabOverrides ||
        oldWidget.commandTabBuilder != widget.commandTabBuilder ||
        oldWidget.monitorTabBuilder != widget.monitorTabBuilder ||
        oldWidget.copilotTabBuilder != widget.copilotTabBuilder ||
        oldWidget.mineTabBuilder != widget.mineTabBuilder ||
        oldWidget.startupGateBuilder != widget.startupGateBuilder ||
        oldWidget.floatingVideoBuilder != widget.floatingVideoBuilder;

    if (adaptersChanged) _adapters = _createAdapters();
    if (adaptersChanged || oldWidget.voiceSlot != widget.voiceSlot) {
      _voiceBridge.updateSlot(widget.voiceSlot ?? _adapters.createVoiceSlot());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _videoPlayback.removeListener(_syncSystemPip);
    SystemPip.isActive.removeListener(_handlePipActiveChanged);
    if (_ownsVideoPlayback) _videoPlayback.dispose();
    _voiceCoordinator.dispose();
    _copilotAdapter.dispose();
    _homeAssembly.dispose();
    _profileHubAssembly.dispose();
    _monitorAdapter.dispose();
    _voiceBridge.dispose();
    if (widget.disposeController) widget.controller.dispose();
    super.dispose();
  }

  ShellVoiceBridge _createVoiceBridge() => ShellVoiceBridge(
    controller: widget.controller,
    onSelectTab: _selectTab,
    onShowMessage: _showSnackMessage,
    onNoteSaved: _openNotesPage,
    initialTab: _tab,
  );

  OnboardingAssembly _createOnboardingAssembly() => OnboardingAssembly(
    controller: widget.controller,
    onSelectTab: _selectTab,
    onShowMessage: _showSnackMessage,
  );

  ProfileHubAssembly _createProfileHubAssembly() => ProfileHubAssembly(
    controller: widget.controller,
    monitorAdapter: _monitorAdapter,
    buildIncidentDetailsRoute: ([Incident? target]) => _homeAssembly.buildIncidentDetailsRoute(target),
    onSelectThemeId: ThemeController.instance.selectById,
  );

  CommandHomeAssembly _createHomeAssembly() => CommandHomeAssembly(
    controller: widget.controller,
    videoPlayback: _videoPlayback,
    onVideoFloating: () => _selectTab(ShellVoiceBridge.commandTabIndex),
    onOpenMonitor: () => _selectTab(ShellVoiceBridge.monitorTabIndex),
    onOpenNotes: _openNotesPage,
    onOpenWatermarkSettings: ProfileHubAssembly.openWatermarkSettings,
    onOpenVideoResourceAdmin: _profileHubAssembly.openVideoResourceAdmin,
    onOpenIncidentImport: _onboardingAssembly.openIncidentImport,
    onShowMessage: _showSnackMessage,
  );

  ShellMonitorAdapter _createMonitorAdapter() => ShellMonitorAdapter(controller: widget.controller);

  ShellCopilotAdapter _createCopilotAdapter() => ShellCopilotAdapter(
    controller: widget.controller,
    chatAudioService: widget.chatAudioService,
    storeOverride: widget.copilotStore,
    onOpenIncidentDetails: _openIncidentDetails,
  );

  ShellVoiceCoordinator _createVoiceCoordinator() => ShellVoiceCoordinator(
    controller: widget.controller,
    voiceBridge: _voiceBridge,
    navigatorKey: _navigatorKey,
    findEntryById: _monitorAdapter.findEntryById,
    onShowMessage: _showSnackMessage,
    onSelectTab: _selectTab,
    sessionStoreOverride: widget.voiceSessionStore,
    routerOverride: widget.voiceIntentRouter,
  );

  ShellTabAdapters _createAdapters() {
    final base = widget.tabOverrides;
    return ShellTabAdapters(
      controller: widget.controller,
      voiceBridge: _voiceBridge,
      videoPlayback: _videoPlayback,
      homeAssembly: _homeAssembly,
      monitorAdapter: _monitorAdapter,
      copilotAdapter: _copilotAdapter,
      profileHubAssembly: _profileHubAssembly,
      onboardingAssembly: _onboardingAssembly,
      voiceCoordinator: _voiceCoordinator,
      onSelectTab: _selectTab,
      onShowMessage: _showSnackMessage,
      overrides: ShellTabOverrides(
        commandTabBuilder: widget.commandTabBuilder ?? base?.commandTabBuilder,
        monitorTabBuilder: widget.monitorTabBuilder ?? base?.monitorTabBuilder,
        copilotTabBuilder: widget.copilotTabBuilder ?? base?.copilotTabBuilder,
        mineTabBuilder: widget.mineTabBuilder ?? base?.mineTabBuilder,
        startupGateBuilder: widget.startupGateBuilder ?? base?.startupGateBuilder,
        floatingVideoBuilder: widget.floatingVideoBuilder ?? base?.floatingVideoBuilder,
      ),
    );
  }

  void _handlePipActiveChanged() =>
      widget.controller.setPipActive(SystemPip.isActive.value);

  void _syncSystemPip() =>
      unawaited(SystemPip.setAutoEnter(enabled: _videoPlayback.hasResource));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.handleAppResumed());
      if (_videoPlayback.hasResource) _videoPlayback.reattachSurface();
    } else {
      widget.controller.handleAppPaused();
    }
  }

  void _selectTab(int nextTab) {
    if (widget.controller.needsIncidentSelection) return;
    if (nextTab < 0 || nextTab >= ShellKeys.tabs.length) return;
    HapticFeedback.selectionClick();
    DiagnosticLogService.instance.setPage(_pageName(nextTab));
    _voiceBridge.handleTabLeaving(_tab, nextTab);
    if (_tab != nextTab) setState(() => _tab = nextTab);
    _voiceBridge.syncActiveTab(nextTab);
  }

  String _pageName(int tab) => switch (tab) {
    ShellVoiceBridge.commandTabIndex => 'command',
    ShellVoiceBridge.monitorTabIndex => 'monitor',
    ShellVoiceBridge.copilotTabIndex => 'copilot',
    ShellVoiceBridge.mineTabIndex => 'mine',
    _ => 'unknown',
  };

  void _showSnackMessage(String message, {Duration duration = const Duration(seconds: 2)}) {
    if (!mounted) return;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: duration, behavior: SnackBarBehavior.floating));
  }

  void _openNotesPage() {
    if (mounted) _navigatorKey.currentState?.push<void>(_adapters.buildNotesRoute());
  }

  void _openIncidentDetails() {
    final route = mounted ? _adapters.buildIncidentDetailsRoute() : null;
    if (route != null) _navigatorKey.currentState?.push<void>(route);
  }

  Future<void> _fullscreenFloatingVideo(BuildContext context) async {
    if (_videoPlayback.presentation != VideoPlaybackPresentation.floating || !_videoPlayback.hasResource) return;
    _videoPlayback.enterFullscreen();
    await Navigator.of(context).push<void>(_adapters.buildFullscreenVideoRoute());
    if (mounted && _videoPlayback.hasResource) _videoPlayback.enterFloating();
  }

  bool _hasBoardAlert() {
    final cfg = widget.controller.calcConfig;
    return widget.controller.entries.any((e) {
      if (!e.isActive) return false;
      final s = e.statusAt(warnMin: cfg.warnMin, alarmMin: cfg.alarmMin);
      return s == 'alarm' || s == 'timeout';
    });
  }

  List<CommandNavTab> _buildNavTabs() {
    final t = CommandNavBar.defaultTabs;
    return <CommandNavTab>[
      t[0],
      CommandNavTab(label: t[1].label, icon: t[1].icon, activeIcon: t[1].activeIcon, hasAlert: _hasBoardAlert()),
      t[2],
      CommandNavTab(label: t[3].label, icon: t[3].icon, activeIcon: t[3].activeIcon, badgeCount: widget.controller.pendingMemberCount),
    ];
  }

  void _scheduleWarmSandMigrationNotice() {
    if (_warmSandNoticeScheduled) return;
    _warmSandNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmSandNoticeScheduled = false;
      if (!mounted || !ThemeController.instance.warmSandMigratedPending) return;
      _showSnackMessage('原「暖砂」配色已平滑升级为「昼白」，可在「我的 → 界面外观」随时切换', duration: const Duration(seconds: 4));
      unawaited(ThemeController.instance.consumeWarmSandMigrationNotice());
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ShellKeys.root,
      child: ListenableBuilder(
        listenable: ThemeController.instance,
        builder: (BuildContext context, _) {
          final themeController = ThemeController.instance;
          if (themeController.warmSandMigratedPending) _scheduleWarmSandMigrationNotice();
          return MaterialApp(
            title: kDebugMode ? '火场智控·测试' : '火场智控',
            navigatorKey: _navigatorKey,
            scaffoldMessengerKey: _messengerKey,
            debugShowCheckedModeBanner: false,
            theme: buildCommandTheme(Brightness.light),
            darkTheme: buildCommandTheme(Brightness.dark),
            themeMode: themeController.themeMode,
            themeAnimationDuration: Duration.zero,
            builder: (BuildContext context, Widget? child) {
              final dark = Theme.of(context).brightness == Brightness.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
                child: ValueListenableBuilder<bool>(
                  valueListenable: SystemPip.isActive,
                  builder: (_, bool inPip, _) => inPip
                      ? CommandPipShell(key: ShellKeys.pipHost, session: _videoPlayback)
                      : (child ?? const SizedBox.shrink()),
                ),
              );
            },
            home: _buildHome(),
          );
        },
      ),
    );
  }

  Widget _buildHome() {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.controller, _voiceBridge]),
      builder: (BuildContext context, _) {
        final controller = widget.controller;
        final pages = _adapters.buildTabs(context);
        final locked =
            controller.needsAuthentication || controller.needsIncidentSelection;
        final Widget tabStack = IndexedStack(index: _tab, children: pages);
        final Widget body = controller.isGuest
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  GuestBannerBar(onConvert: () => unawaited(controller.leaveUnit())),
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: tabStack,
                    ),
                  ),
                ],
              )
            : tabStack;

        return PopScope(
          canPop: !locked,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ExcludeSemantics(
                excluding: locked,
                child: IgnorePointer(
                  ignoring: locked,
                  child: Scaffold(
                    backgroundColor: context.ds.colors.canvas,
                    body: body,
                    bottomNavigationBar: ShellCommandNavBar(
                      tabs: _buildNavTabs(),
                      selectedIndex: _tab,
                      voiceBridge: _voiceBridge,
                      onSelectTab: _selectTab,
                    ),
                  ),
                ),
              ),
              if (!locked)
                ListenableBuilder(
                  listenable: _voiceCoordinator,
                  builder: (ctx, _) => _voiceCoordinator.buildOverlay(ctx),
                ),
              if (locked)
                KeyedSubtree(
                  key: ShellKeys.startupGate,
                  child: _adapters.buildStartupGate(context),
                ),
              _buildFloatingVideoOverlay(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFloatingVideoOverlay() => ListenableBuilder(
    listenable: _videoPlayback,
    builder: (BuildContext context, _) {
      if (_videoPlayback.presentation != VideoPlaybackPresentation.floating ||
          !_videoPlayback.hasResource) {
        return const SizedBox.shrink();
      }
      final bottom =
          (_tab == ShellVoiceBridge.copilotTabIndex ? 152 : 96) +
          MediaQuery.paddingOf(context).bottom;
      return Positioned(
        right: 12,
        bottom: bottom,
        child: KeyedSubtree(
          key: ShellKeys.floatingVideo,
          child: _adapters.buildFloatingVideo(
            context,
            onFullscreen: () => unawaited(_fullscreenFloatingVideo(context)),
          ),
        ),
      );
    },
  );
}
