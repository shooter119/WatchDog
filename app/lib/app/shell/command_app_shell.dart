import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/design_system.dart';
import '../../features/copilot/state/copilot_store.dart';
import '../../features/voice/state/voice_intent_router.dart';
import '../../features/voice/state/voice_session_store.dart';
import '../../services/audio_service.dart';
import '../../services/diagnostic_log_service.dart';
import '../../services/foreground_keep_alive.dart';
import '../../services/system_pip.dart';
import '../../services/theme_controller.dart';
import '../../services/video_playback_session.dart';
import '../../state/app_controller.dart';
import '../../widgets/pip_shell.dart';
import 'guest_banner_bar.dart';
import 'legacy_tab_adapters.dart';
import 'shell_copilot_adapter.dart';
import 'shell_keys.dart';
import 'shell_monitor_adapter.dart';
import 'shell_nav_bar.dart';
import 'shell_voice_bridge.dart';
import 'shell_voice_coordinator.dart';

/// Design System v3.0 新外壳根组件（4 Tab + 中置 64dp 语音指令键）。
///
/// 继承既有 `main.dart` 全部关键机制：昼白/暗曜主题瞬切、`WidgetsBindingObserver`
/// 恢复同步与视频 Surface 重挂、`SystemPip` 切换 `PipShell`、悬浮视频小窗与全屏、
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
  late ShellCopilotAdapter _copilotAdapter;
  late ShellVoiceCoordinator _voiceCoordinator;
  late LegacyTabAdapters _adapters;
  int _tab = ShellVoiceBridge.commandTabIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ownsVideoPlayback = widget.videoPlayback == null;
    _videoPlayback = widget.videoPlayback ?? VideoPlaybackSession();
    _videoPlayback.addListener(_syncSystemPip);

    widget.controller.setPipActive(SystemPip.isActive.value);
    SystemPip.isActive.addListener(_handlePipActiveChanged);
    DiagnosticLogService.instance.setPage(_pageName(_tab));

    _voiceBridge = _createVoiceBridge();
    _monitorAdapter = _createMonitorAdapter();
    _copilotAdapter = _createCopilotAdapter();
    _voiceCoordinator = _createVoiceCoordinator();
    _adapters = _createAdapters();
    _voiceBridge.updateSlot(widget.voiceSlot ?? _adapters.createVoiceSlot());

    if (widget.enableStartupSideEffects) {
      unawaited(
        ForegroundKeepAlive.init().catchError((Object error, StackTrace _) {
          debugPrint('ForegroundKeepAlive init failed: $error');
        }),
      );
      unawaited(widget.controller.init());
      unawaited(widget.controller.checkUpdateSilently());
    }
  }

  @override
  void didUpdateWidget(covariant CommandAppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.videoPlayback, widget.videoPlayback)) {
      _videoPlayback.removeListener(_syncSystemPip);
      if (_ownsVideoPlayback) _videoPlayback.dispose();
      _ownsVideoPlayback = widget.videoPlayback == null;
      _videoPlayback = widget.videoPlayback ?? VideoPlaybackSession();
      _videoPlayback.addListener(_syncSystemPip);
    }

    final controllerChanged = !identical(oldWidget.controller, widget.controller);
    if (controllerChanged) {
      _voiceBridge.dispose();
      _voiceBridge = _createVoiceBridge();
      _monitorAdapter.dispose();
      _monitorAdapter = _createMonitorAdapter();
      widget.controller.setPipActive(SystemPip.isActive.value);
    }

    final copilotChanged =
        controllerChanged ||
        !identical(oldWidget.chatAudioService, widget.chatAudioService) ||
        !identical(oldWidget.copilotStore, widget.copilotStore);
    if (copilotChanged) {
      _copilotAdapter.dispose();
      _copilotAdapter = _createCopilotAdapter();
    }

    final voiceChanged =
        controllerChanged ||
        !identical(oldWidget.voiceSessionStore, widget.voiceSessionStore) ||
        !identical(oldWidget.voiceIntentRouter, widget.voiceIntentRouter);
    if (voiceChanged) {
      _voiceCoordinator.dispose();
      _voiceCoordinator = _createVoiceCoordinator();
    }

    final adaptersChanged =
        controllerChanged ||
        copilotChanged ||
        voiceChanged ||
        !identical(oldWidget.videoPlayback, widget.videoPlayback) ||
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

  ShellMonitorAdapter _createMonitorAdapter() =>
      ShellMonitorAdapter(controller: widget.controller);

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

  LegacyTabAdapters _createAdapters() {
    final base = widget.tabOverrides;
    return LegacyTabAdapters(
      controller: widget.controller,
      voiceBridge: _voiceBridge,
      videoPlayback: _videoPlayback,
      monitorAdapter: _monitorAdapter,
      copilotAdapter: _copilotAdapter,
      voiceCoordinator: _voiceCoordinator,
      onSelectTab: _selectTab,
      onOpenNotes: _openNotesPage,
      overrides: ShellTabOverrides(
        commandTabBuilder: widget.commandTabBuilder ?? base?.commandTabBuilder,
        monitorTabBuilder: widget.monitorTabBuilder ?? base?.monitorTabBuilder,
        copilotTabBuilder: widget.copilotTabBuilder ?? base?.copilotTabBuilder,
        mineTabBuilder: widget.mineTabBuilder ?? base?.mineTabBuilder,
        startupGateBuilder:
            widget.startupGateBuilder ?? base?.startupGateBuilder,
        floatingVideoBuilder:
            widget.floatingVideoBuilder ?? base?.floatingVideoBuilder,
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

  void _showSnackMessage(
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: duration,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _openNotesPage() {
    if (!mounted) return;
    _navigatorKey.currentState?.push<void>(_adapters.buildNotesRoute());
  }

  void _openIncidentDetails() {
    if (!mounted) return;
    final route = _adapters.buildIncidentDetailsRoute();
    if (route != null) {
      _navigatorKey.currentState?.push<void>(route);
    }
  }

  Future<void> _fullscreenFloatingVideo(BuildContext context) async {
    if (_videoPlayback.presentation != VideoPlaybackPresentation.floating ||
        !_videoPlayback.hasResource) {
      return;
    }
    _videoPlayback.enterFullscreen();
    await Navigator.of(context).push<void>(_adapters.buildFullscreenVideoRoute());
    if (!mounted || !_videoPlayback.hasResource) return;
    _videoPlayback.enterFloating();
  }

  bool _hasBoardAlert() {
    final cfg = widget.controller.calcConfig;
    return widget.controller.entries.any((entry) {
      if (!entry.isActive) return false;
      final status = entry.statusAt(warnMin: cfg.warnMin, alarmMin: cfg.alarmMin);
      return status == 'alarm' || status == 'timeout';
    });
  }

  List<CommandNavTab> _buildNavTabs() {
    final tabs = CommandNavBar.defaultTabs;
    return <CommandNavTab>[
      tabs[0],
      CommandNavTab(
        label: tabs[1].label,
        icon: tabs[1].icon,
        activeIcon: tabs[1].activeIcon,
        hasAlert: _hasBoardAlert(),
      ),
      tabs[2],
      CommandNavTab(
        label: tabs[3].label,
        icon: tabs[3].icon,
        activeIcon: tabs[3].activeIcon,
        badgeCount: widget.controller.pendingMemberCount,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ShellKeys.root,
      child: ListenableBuilder(
        listenable: ThemeController.instance,
        builder: (BuildContext context, _) {
          final brightness = ThemeController.instance.current.brightness;
          final themeId = ThemeController.instance.currentId;
          return MaterialApp(
            title: kDebugMode ? '火场智控·测试' : '火场智控',
            navigatorKey: _navigatorKey,
            scaffoldMessengerKey: _messengerKey,
            debugShowCheckedModeBanner: false,
            theme: buildCommandTheme(brightness),
            themeAnimationDuration: Duration.zero,
            builder: (BuildContext context, Widget? child) {
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: brightness == Brightness.dark
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark,
                child: ValueListenableBuilder<bool>(
                  valueListenable: SystemPip.isActive,
                  builder: (BuildContext context, bool inPip, _) => inPip
                      ? PipShell(key: ShellKeys.pipHost, session: _videoPlayback)
                      : (child ?? const SizedBox.shrink()),
                ),
              );
            },
            home: KeyedSubtree(
              key: ValueKey<String>(themeId),
              child: _buildHome(),
            ),
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
        final startupGateLocked =
            controller.needsAuthentication || controller.needsIncidentSelection;

        final Widget tabStack = IndexedStack(index: _tab, children: pages);
        final Widget bodyContent = controller.isGuest
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  GuestBannerBar(
                    onConvert: () => unawaited(controller.leaveUnit()),
                  ),
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

        final Widget appScaffold = Scaffold(
          backgroundColor: context.ds.colors.canvas,
          body: bodyContent,
          bottomNavigationBar: ExcludeSemantics(
            excluding: startupGateLocked,
            child: IgnorePointer(
              ignoring: startupGateLocked,
              child: ShellCommandNavBar(
                tabs: _buildNavTabs(),
                selectedIndex: _tab,
                voiceBridge: _voiceBridge,
                onSelectTab: _selectTab,
              ),
            ),
          ),
        );

        return PopScope(
          canPop: !startupGateLocked,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              appScaffold,
              if (!startupGateLocked) _buildGlobalVoiceOverlay(),
              if (startupGateLocked)
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

  Widget _buildGlobalVoiceOverlay() => ListenableBuilder(
    listenable: _voiceCoordinator,
    builder: (BuildContext context, _) => _voiceCoordinator.buildOverlay(context),
  );

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
