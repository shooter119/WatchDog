import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/board_page.dart';
import 'pages/chat_page.dart';
import 'pages/home_page.dart';
import 'pages/incident_selection_overlay.dart';
import 'pages/notes_page.dart';
import 'pages/settings_page.dart';
import 'pages/video_playback_surface.dart';
import 'services/audio_service.dart';
import 'services/foreground_keep_alive.dart';
import 'services/app_data_epoch.dart';
import 'services/local_asr_service.dart';
import 'services/diagnostic_log_service.dart';
import 'services/op_log_service.dart';
import 'services/system_pip.dart';
import 'services/theme_controller.dart';
import 'services/video_playback_session.dart';
import 'state/app_controller.dart';
import 'theme/app_theme.dart';
import 'theme/app_widgets.dart';
import 'theme/nav_icons.dart';
import 'widgets/pip_shell.dart';

void main() {
  final diagnostics = DiagnosticLogService.instance;
  // ensureInitialized 与 runApp 必须处于同一个 Zone，否则 Flutter 会产生
  // Zone mismatch 告警，并可能让插件的 Zone 配置行为不一致。
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      unawaited(SystemPip.initialize());
      unawaited(diagnostics.init());

      // Flutter framework 异常通常就是开发者看到的红屏；保留 Flutter 默认输出，
      // 同时异步写入诊断日志。日志失败不能阻断 Flutter 的默认错误处理。
      final previousFlutterError = FlutterError.onError;
      FlutterError.onError = (details) {
        diagnostics.recordFlutterError(details);
        if (previousFlutterError != null) {
          previousFlutterError(details);
        } else {
          FlutterError.presentError(details);
        }
      };

      // 捕获未被 Widget 层处理的异步异常；返回 false 让 Flutter 保留默认行为。
      final previousPlatformError = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stack) {
        diagnostics.recordUncaught(error, stack, source: 'platform_error');
        return previousPlatformError?.call(error, stack) ?? false;
      };

      // 新协议首次启动必须先停止旧保活、清理旧会话/离线队列/模型缓存，
      // 再创建控制器，避免旧状态在新 WebSocket 会话建立前短暂泄漏。
      unawaited(_bootstrapApp(diagnostics));
    },
    (error, stack) {
      // 兜住 runApp/Zone 内未处理的同步和异步异常。
      diagnostics.recordUncaught(error, stack, source: 'zone_error');
    },
  );
}

/// 启动链：数据纪元清理 → 主题偏好加载 → runApp。
///
/// 三步必须串行：主题在 runApp 之前读取，首帧就是正确配色，
/// 不会先白后暖；任何一步失败只降级，不能把用户卡在黑屏。
Future<void> _bootstrapApp(DiagnosticLogService diagnostics) async {
  try {
    await ensureAppDataEpoch();
  } catch (error, stack) {
    // 清理失败不阻断启动；控制器仍会要求重新认证。
    diagnostics.recordUncaught(error, stack, source: 'data_epoch_reset');
  }
  await ThemeController.instance.load();
  runApp(const WatchDogApp());
}

const double _kVoiceNavProtrusion = 12.0;
const double _kVoiceNavButtonSize = 52.0;

double _bottomNavBarHeight(BuildContext context) {
  final labelScaleHeight = (MediaQuery.textScalerOf(context).scale(12) * 1.2)
      .ceilToDouble();
  return math.max(70.0, 55.0 + labelScaleHeight);
}

class WatchDogApp extends StatefulWidget {
  final AppController? controller;
  final AudioService? chatAudioService;

  const WatchDogApp({super.key, this.controller, this.chatAudioService});

  @override
  State<WatchDogApp> createState() => _WatchDogAppState();
}

class _WatchDogAppState extends State<WatchDogApp> with WidgetsBindingObserver {
  late final AppController controller;
  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();
  final GlobalKey<ChatPageState> _chatKey = GlobalKey<ChatPageState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final VideoPlaybackSession _videoPlayback = VideoPlaybackSession();
  int _tab = 2; // 警情处置默认进入（tab 顺序：日志0/看板1/警情处置2/辅助3/设置4）
  bool _pendingVoice = false; // 底部语音按钮长按 → 切换到警情处置后自动开始录音
  bool _recording = false; // 录音状态（页面上报，驱动底部按钮停止图标+脉冲）
  bool _processing = false; // 识别/确认中（禁用语音按钮，避免重复触发）
  bool _chatRecording = false; // 辅助页就地语音提问录音态
  bool _chatProcessing = false; // 辅助页就地语音提问识别态
  bool _voiceCapPressed = false; // 顶部破界凸起区按下态联动

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _videoPlayback.addListener(_syncSystemPip);
    controller =
        widget.controller ?? AppController(localAsr: LocalAsrService());
    controller.setPipActive(SystemPip.isActive.value);
    SystemPip.isActive.addListener(_handlePipActiveChanged);
    DiagnosticLogService.instance.setPage('home');
    // 等 FlutterActivity 完成插件注册后再初始化后台值守；过早在 main()
    // 调用会触发 flutter_foreground_task 的 MissingPluginException。
    // 前台服务属于可选能力，平台插件不可用或系统权限流程卡住时，不能
    // 阻塞警情同步和新建警情等核心链路。
    unawaited(
      ForegroundKeepAlive.init().catchError((error, stackTrace) {
        debugPrint('ForegroundKeepAlive init failed: $error');
      }),
    );
    controller.init();
    // 启动即静默检查 ALI OTA：有新版本时设置页显示提示（失败静默）
    controller.checkUpdateSilently();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _videoPlayback.removeListener(_syncSystemPip);
    SystemPip.isActive.removeListener(_handlePipActiveChanged);
    _videoPlayback.dispose();
    controller.dispose();
    super.dispose();
  }

  void _handlePipActiveChanged() {
    controller.setPipActive(SystemPip.isActive.value);
  }

  void _syncSystemPip() {
    // 只要还有视频会话就允许切后台时自动进 PiP；stop() 后 hasResource 为假，自动关闭。
    unawaited(SystemPip.setAutoEnter(enabled: _videoPlayback.hasResource));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(controller.handleAppResumed());
      if (_videoPlayback.hasResource) {
        _videoPlayback.reattachSurface();
      }
    } else {
      controller.handleAppPaused();
    }
  }

  void _selectTab(int i) {
    if (controller.needsIncidentSelection) return;
    HapticFeedback.selectionClick();
    DiagnosticLogService.instance.setPage(_pageName(i));
    if (_tab == 3 && i != 3) {
      if (_chatRecording) {
        unawaited(_chatKey.currentState?.finishRecording());
      }
      _chatKey.currentState?.dismissKeyboard();
    }
    setState(() {
      _tab = i;
    });
  }

  Future<void> _fullscreenFloatingVideo(BuildContext context) async {
    if (_videoPlayback.presentation != VideoPlaybackPresentation.floating ||
        !_videoPlayback.hasResource) {
      return;
    }
    _videoPlayback.enterFullscreen();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoFullscreenPage(session: _videoPlayback),
      ),
    );
    if (!mounted || !_videoPlayback.hasResource) return;
    _videoPlayback.enterFloating();
  }

  String _pageName(int tab) => switch (tab) {
    0 => 'notes',
    1 => 'board',
    2 => 'home',
    3 => 'chat',
    4 => 'settings',
    _ => 'unknown',
  };

  void _goVoice() => _selectTab(2);

  /// 录音中点击按钮 = 停止录音（松手时机丢失/权限弹窗场景的兜底出口）
  void _voiceTap() {
    if (controller.needsAuthentication || controller.needsIncidentSelection) {
      return;
    }
    if (_tab == 3) {
      if (_chatRecording) {
        unawaited(_chatKey.currentState?.finishRecording());
        return;
      }
      if (_chatProcessing) return;
      _goVoice();
      return;
    }
    if (_recording) {
      _homeKey.currentState?.finishRecording();
      return;
    }
    if (_processing) return;
    if (_tab == 2) {
      HapticFeedback.lightImpact();
      (_messengerKey.currentState ?? ScaffoldMessenger.maybeOf(context))
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('长按说话，松开识别'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } else {
      _goVoice();
    }
  }

  void _voiceLongPressStart(LongPressStartDetails _) {
    if (controller.needsAuthentication || controller.needsIncidentSelection) {
      return;
    }
    if (_tab == 3) {
      if (_chatProcessing) return;
      HapticFeedback.mediumImpact();
      _chatKey.currentState?.dismissKeyboard();
      unawaited(_chatKey.currentState?.beginRecording());
      return;
    }
    if (controller.requiresIncident) {
      controller.requestIncidentSelection();
      return;
    }
    if (_processing) return;
    HapticFeedback.mediumImpact();
    if (_tab != 2) {
      setState(() {
        _tab = 2;
        _pendingVoice = true;
      });
    } else {
      _homeKey.currentState?.beginRecording();
    }
  }

  void _voiceLongPressEnd(LongPressEndDetails _) {
    if (controller.needsAuthentication || controller.needsIncidentSelection) {
      return;
    }
    if (_tab == 3 || _chatRecording) {
      unawaited(_chatKey.currentState?.finishRecording());
      return;
    }
    if (controller.requiresIncident) return;
    if (_pendingVoice) {
      // 切页后的首帧录音尚未启动时松手，取消自动录音请求。
      setState(() => _pendingVoice = false);
      return;
    }
    _homeKey.currentState?.finishRecording();
  }

  void _voiceLongPressCancel() {
    if (_tab == 3 || _chatRecording) {
      unawaited(_chatKey.currentState?.finishRecording());
      return;
    }
    if (_pendingVoice) {
      setState(() => _pendingVoice = false);
      return;
    }
    if (_recording) {
      _homeKey.currentState?.finishRecording();
    }
  }

  /// 语音识别为火场日志：自动记入 + 跳日志页
  Future<void> _routeNote(String text) async {
    if (controller.needsIncidentSelection) return;
    if (controller.requiresIncident) {
      controller.requestIncidentSelection();
      return;
    }
    var saved = false;
    try {
      await controller.addNote(text);
      saved = true;
    } catch (e) {
      // 写日志失败要可见：提示用户 + 埋点，避免"识别成功但日志没新增"无从排查
      OpLogService.instance.record(
        'note-${DateTime.now().millisecondsSinceEpoch}',
        'note_add_fail',
        '自动记日志失败：$e',
        level: 'error',
        data: {'text': text},
      );
      if (mounted) {
        (_messengerKey.currentState ?? ScaffoldMessenger.maybeOf(context))
            ?.showSnackBar(
          SnackBar(
            content: Text('记日志失败：$e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
    if (saved && mounted) _selectTab(0);
  }

  /// 语音识别为提问：跳问答页并自动发送
  void _routeAsk(String text) {
    if (controller.needsIncidentSelection) return;
    _selectTab(3);
    _chatKey.currentState?.submitQuestion(text);
  }

  @override
  Widget build(BuildContext context) {
    // 切换主题 = 换一个 palette 实例 + 重建 MaterialApp，因此监听必须包在
    // MaterialApp 外层；写成 child: 只会构建一次，切换会完全失效。
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        assert(
          AppColors.palette.id == ThemeController.instance.currentId,
          'AppColors 与 ThemeController 必须来自同一 palette',
        );
        return _buildScaffold(context);
      },
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return MaterialApp(
      title: kDebugMode ? '火场智控·测试' : '火场智控',
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // 默认 200ms 的 Theme 渐变会与瞬切的 AppColors 并存，出现两套配色。
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppColors.palette.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: ValueListenableBuilder<bool>(
          valueListenable: SystemPip.isActive,
          builder: (context, inPip, _) => inPip
              ? PipShell(session: _videoPlayback)
              : (child ?? const SizedBox.shrink()),
        ),
      ),
      // 换主题时按 palette 换 key 强制重建整棵页面树：在 build 里读 AppColors
      // 的 const 组件会被 Flutter 的 identical 短路跳过，留下旧色。
      // 代价是切主题会重置页面滚动位置与未提交输入，可接受。
      home: KeyedSubtree(
        key: ValueKey(ThemeController.instance.currentId),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final pages = [
              NotesPage(controller: controller),
              BoardPage(controller: controller, onGoVoice: _goVoice),
              HomePage(
                key: _homeKey,
                controller: controller,
                autoRecord: _pendingVoice,
                onAutoRecordConsumed: () => _pendingVoice = false,
                onRecordingChanged: (v) => setState(() => _recording = v),
                onProcessingChanged: (v) => setState(() => _processing = v),
                onNoteIntent: _routeNote,
                onAskIntent: _routeAsk,
                onEntryConfirmed: () => _selectTab(1),
                videoPlayback: _videoPlayback,
                onVideoFloating: () => _selectTab(2),
              ),
              ChatPage(
                key: _chatKey,
                controller: controller,
                audioService: widget.chatAudioService,
                bottomNavClearance: 14.0,
                onRecordingChanged: (v) {
                  if (!mounted || _chatRecording == v) return;
                  setState(() => _chatRecording = v);
                },
                onProcessingChanged: (v) {
                  if (!mounted || _chatProcessing == v) return;
                  setState(() => _chatProcessing = v);
                },
              ),
              SettingsPage(controller: controller),
            ];
            final startupGateLocked =
                controller.needsAuthentication ||
                controller.needsIncidentSelection;
            final Widget bodyContent = controller.isGuest
                ? Column(
                    children: [
                      SafeArea(
                        bottom: false,
                        child: Container(
                          margin: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.cautionSurface,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(
                              color: AppColors.caution,
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: AppColors.caution.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.shield_outlined,
                                  size: 15,
                                  color: AppColors.cautionText,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '游客模式（数据仅保存在本机）',
                                  style: AppTextStyles.label.copyWith(
                                    color: AppColors.cautionText,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  key: const Key('guest-convert-btn'),
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.sm,
                                  ),
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    controller.leaveUnit();
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.caution.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.sm,
                                      ),
                                      border: Border.all(
                                        color: AppColors.caution,
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      '转为正式队员',
                                      style: TextStyle(
                                        color: AppColors.cautionText,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: MediaQuery.removePadding(
                          context: context,
                          removeTop: true,
                          child: IndexedStack(index: _tab, children: pages),
                        ),
                      ),
                    ],
                  )
                : IndexedStack(index: _tab, children: pages);

            final bool boardAlert = controller.entries.any((e) {
              if (!e.isActive) return false;
              final s = e.statusAt(
                warnMin: controller.calcConfig.warnMin,
                alarmMin: controller.calcConfig.alarmMin,
              );
              return s == 'alarm' || s == 'timeout';
            });

            final activeRecording = _tab == 3 ? _chatRecording : _recording;
            final activeProcessing = _tab == 3 ? _chatProcessing : _processing;

            final appScaffold = Scaffold(
              body: bodyContent,
              bottomNavigationBar: ExcludeSemantics(
                excluding: startupGateLocked,
                child: IgnorePointer(
                  ignoring: startupGateLocked,
                  child: _BottomNav(
                    index: _tab,
                    boardAlert: boardAlert,
                    pendingCount: controller.pendingMemberCount,
                    recording: activeRecording,
                    processing: activeProcessing,
                    capPressed: _voiceCapPressed,
                    onSelect: _selectTab,
                    onVoiceTap: _voiceTap,
                    onVoiceLongPressStart: _voiceLongPressStart,
                    onVoiceLongPressEnd: _voiceLongPressEnd,
                    onVoiceLongPressCancel: _voiceLongPressCancel,
                  ),
                ),
              ),
            );
            final navBarHeight = _bottomNavBarHeight(context);
            final safeBottom = MediaQuery.paddingOf(context).bottom;
            final keyboardOpen = View.of(context).viewInsets.bottom > 0;
            return PopScope(
              canPop: !startupGateLocked,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  appScaffold,
                  if (!startupGateLocked && !keyboardOpen)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: navBarHeight + safeBottom,
                      height: _kVoiceNavProtrusion,
                      child: Center(
                        child: SizedBox(
                          width: _kVoiceNavButtonSize,
                          height: _kVoiceNavProtrusion,
                          child: ExcludeSemantics(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: activeProcessing ? null : _voiceTap,
                              onLongPressStart: activeProcessing
                                  ? null
                                  : _voiceLongPressStart,
                              onLongPressEnd: activeProcessing
                                  ? null
                                  : _voiceLongPressEnd,
                              onLongPressCancel: activeProcessing
                                  ? null
                                  : () {
                                      if (_voiceCapPressed) {
                                        setState(() => _voiceCapPressed = false);
                                      }
                                      _voiceLongPressCancel();
                                    },
                              onTapDown: activeProcessing
                                  ? null
                                  : (_) {
                                      HapticFeedback.heavyImpact();
                                      setState(() => _voiceCapPressed = true);
                                    },
                              onTapUp: (_) {
                                if (_voiceCapPressed) {
                                  setState(() => _voiceCapPressed = false);
                                }
                              },
                              onTapCancel: () {
                                if (_voiceCapPressed) {
                                  setState(() => _voiceCapPressed = false);
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (startupGateLocked)
                    IncidentSelectionOverlay(
                      onEnterWithoutIncident: () {
                        controller.enterWithoutIncident();
                        _selectTab(2);
                      },
                      authenticationRequired: controller.needsAuthentication,
                      activeIncidents: controller.activeIncidents,
                      externalIncidents: controller.externalIncidents,
                      loading:
                          !controller.needsAuthentication &&
                          (controller.syncing || controller.api == null),
                      externalLoading: controller.externalIncidentsLoading,
                      externalReorganizing: controller.externalReorganizing,
                      onRefreshExternal: ({bool forceRefresh = false}) =>
                          controller.fetchExternalIncidents(
                            forceRefresh: forceRefresh,
                          ),
                      onReorganizeExternal: () =>
                          controller.reorganizeExternalIncidents(),
                      onClaimExternal: (ext) =>
                          _homeKey.currentState?.claimExternalIncidentFromGate(
                            ext,
                          ) ??
                          Future<void>.value(),
                      onAuthenticate: (unitName, name, code) =>
                          controller.authenticate(
                            unitName: unitName,
                            realName: name,
                            unitCode: code,
                          ),
                      onEnterGuestMode: () => controller.enterGuestMode(),
                      onApply:
                          (
                            unitName,
                            name,
                            code, {
                            stationName,
                            phone,
                            applyReason,
                          }) => controller.applyUnitMembership(
                            unitName: unitName,
                            unitCode: code,
                            realName: name,
                            stationName: stationName,
                            phone: phone,
                            applyReason: applyReason,
                          ),
                      onSelect: (incident) =>
                          _homeKey.currentState?.selectIncidentFromGate(
                            incident,
                          ) ??
                          Future<void>.value(),
                      onCreate: () =>
                          _homeKey.currentState?.createIncidentFromGate() ??
                          Future<void>.value(),
                    ),
                  AnimatedBuilder(
                    animation: _videoPlayback,
                    builder: (context, _) {
                      if (_videoPlayback.presentation !=
                              VideoPlaybackPresentation.floating ||
                          !_videoPlayback.hasResource) {
                        return const SizedBox.shrink();
                      }
                      return Positioned(
                        right: 12,
                        bottom:
                            (_tab == 3 ? 152 : 96) +
                            MediaQuery.paddingOf(context).bottom,
                        child: FloatingVideoWindow(
                          session: _videoPlayback,
                          onFullscreen: () => _fullscreenFloatingVideo(context),
                        ),
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 底部导航：日志 / 看板 / 中央破界悬浮「处置」语音钮 / 辅助 / 设置（全页常驻）
class _BottomNav extends StatelessWidget {
  final int index;
  final bool boardAlert;
  final int pendingCount;
  final bool recording; // 录音中：按钮变停止图标 + 橙色脉冲 + 上方提示
  final bool processing; // 识别/确认中：禁用语音按钮
  final bool capPressed; // 顶部 12dp 破界区按下态同步
  final ValueChanged<int> onSelect;
  final VoidCallback onVoiceTap;
  final GestureLongPressStartCallback onVoiceLongPressStart;
  final GestureLongPressEndCallback onVoiceLongPressEnd;
  final VoidCallback? onVoiceLongPressCancel;

  const _BottomNav({
    required this.index,
    this.boardAlert = false,
    this.pendingCount = 0,
    required this.recording,
    required this.processing,
    this.capPressed = false,
    required this.onSelect,
    required this.onVoiceTap,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressEnd,
    this.onVoiceLongPressCancel,
  });

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final barHeight = _bottomNavBarHeight(context);
    return Container(
      key: const Key('bottom-nav-surface'),
      height: barHeight + safeBottom,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.border, width: 1),
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: safeBottom,
            child: Row(
              children: [
                Expanded(
                  child: _NavItem(
                    glyph: NavGlyph.log,
                    label: '日志',
                    selected: index == 0,
                    onTap: () => onSelect(0),
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    glyph: NavGlyph.board,
                    label: '看板',
                    selected: index == 1,
                    hasAlert: boardAlert,
                    onTap: () => onSelect(1),
                  ),
                ),
                Expanded(
                  child: _CenterDisposeNavSlot(
                    selected: index == 2,
                    recording: recording,
                    processing: processing,
                    capPressed: capPressed,
                    onTap: onVoiceTap,
                    onLongPressStart: onVoiceLongPressStart,
                    onLongPressEnd: onVoiceLongPressEnd,
                    onLongPressCancel: onVoiceLongPressCancel,
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    glyph: NavGlyph.assist,
                    label: '辅助',
                    selected: index == 3,
                    onTap: () => onSelect(3),
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    glyph: NavGlyph.settings,
                    label: '设置',
                    selected: index == 4,
                    hasBadge: pendingCount > 0,
                    onTap: () => onSelect(4),
                  ),
                ),
              ],
            ),
          ),
          if (recording)
            Positioned(
              left: 0,
              right: 0,
              top: -62,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.voice,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    boxShadow: AppShadow.float,
                  ),
                  child: Text(
                    '正在聆听，松开结束',
                    style: TextStyle(
                      color: AppColors.onStatus,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 五栏共享底脚：统一标签文字行高基线与 20×3 指示条垂直位置，确保五栏 0.0dp 横向对齐。
class _NavLabelFooter extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;

  const _NavLabelFooter({
    required this.label,
    required this.selected,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            strutStyle: const StrutStyle(
              fontSize: 12,
              height: 1.15,
              forceStrutHeight: true,
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.15,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(height: 3),
          AnimatedContainer(
            key: selected ? Key('nav-indicator-$label') : null,
            duration: disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: 20,
            height: 3,
            decoration: BoxDecoration(
              color: selected ? AppColors.actionPrimary : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
        ],
      ),
    );
  }
}

class _CenterDisposeNavSlot extends StatefulWidget {
  final bool selected;
  final bool recording;
  final bool processing;
  final bool capPressed;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final GestureLongPressEndCallback onLongPressEnd;
  final VoidCallback? onLongPressCancel;

  const _CenterDisposeNavSlot({
    required this.selected,
    required this.recording,
    required this.processing,
    this.capPressed = false,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    this.onLongPressCancel,
  });

  @override
  State<_CenterDisposeNavSlot> createState() => _CenterDisposeNavSlotState();
}

class _CenterDisposeNavSlotState extends State<_CenterDisposeNavSlot> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final color =
        widget.selected ? AppColors.actionPrimary : AppColors.textTertiary;
    final semanticsLabel = widget.processing
        ? '处置，识别处理中'
        : widget.recording
        ? '处置，正在录音'
        : '处置，语音录入';
    final semanticsHint = widget.processing
        ? '识别处理中，请稍候'
        : widget.recording
        ? '点击或松开结束录音'
        : '长按开始录音，点击进入警情处置';

    return Semantics(
      label: semanticsLabel,
      hint: semanticsHint,
      selected: widget.selected,
      button: true,
      enabled: !widget.processing,
      container: true,
      excludeSemantics: true,
      onTap: widget.processing ? null : widget.onTap,
      child: GestureDetector(
        key: const Key('nav-dispose-tab'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.processing ? null : widget.onTap,
        onLongPressStart: widget.processing ? null : widget.onLongPressStart,
        onLongPressEnd: widget.processing ? null : widget.onLongPressEnd,
        onLongPressCancel: widget.processing
            ? null
            : () {
                if (_pressed) setState(() => _pressed = false);
                widget.onLongPressCancel?.call();
              },
        onTapDown: widget.processing
            ? null
            : (_) {
                HapticFeedback.heavyImpact();
                setState(() => _pressed = true);
              },
        onTapUp: (_) {
          if (_pressed) setState(() => _pressed = false);
        },
        onTapCancel: () {
          if (_pressed) setState(() => _pressed = false);
        },
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _NavLabelFooter(
                  label: '处置',
                  selected: widget.selected,
                  color: color,
                ),
              ),
            ),
            Positioned(
              top: -_kVoiceNavProtrusion,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: VoiceButton(
                  size: _kVoiceNavButtonSize,
                  recording: widget.recording,
                  processing: widget.processing,
                  activeTab: widget.selected,
                  interactive: false,
                  externalPressed: _pressed || widget.capPressed,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final NavGlyph glyph;
  final String label;
  final bool selected;
  final bool hasBadge;
  final bool hasAlert;
  final VoidCallback onTap;

  const _NavItem({
    required this.glyph,
    required this.label,
    required this.selected,
    this.hasBadge = false,
    this.hasAlert = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.actionPrimary : AppColors.textTertiary;
    final semanticsLabel = hasAlert ? '$label，有人员危险' : label;
    return Semantics(
      label: semanticsLabel,
      selected: selected,
      button: true,
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                width: 32,
                height: 28,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    NavIcon(
                      glyph: glyph,
                      color: color,
                      size: 28,
                      selected: selected,
                    ),
                    if (hasAlert)
                      Positioned(
                        right: 0,
                        top: -2,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: AppColors.alarm,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.surface,
                              width: 2,
                            ),
                          ),
                        ),
                      )
                    else if (hasBadge)
                      Positioned(
                        right: 0,
                        top: -2,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: AppColors.cautionText,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.surface,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              _NavLabelFooter(
                label: label,
                selected: selected,
                color: color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
