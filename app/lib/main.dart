import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/board_page.dart';
import 'pages/chat_page.dart';
import 'pages/home_page.dart';
import 'pages/incident_selection_overlay.dart';
import 'pages/notes_page.dart';
import 'pages/settings_page.dart';
import 'services/foreground_keep_alive.dart';
import 'services/local_asr_service.dart';
import 'services/diagnostic_log_service.dart';
import 'services/op_log_service.dart';
import 'state/app_controller.dart';
import 'theme/app_theme.dart';
import 'theme/app_widgets.dart';
import 'theme/nav_icons.dart';

void main() {
  final diagnostics = DiagnosticLogService.instance;
  // ensureInitialized 与 runApp 必须处于同一个 Zone，否则 Flutter 会产生
  // Zone mismatch 告警，并可能让插件的 Zone 配置行为不一致。
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
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

      runApp(const WatchDogApp());
    },
    (error, stack) {
      // 兜住 runApp/Zone 内未处理的同步和异步异常。
      diagnostics.recordUncaught(error, stack, source: 'zone_error');
    },
  );
}

class WatchDogApp extends StatefulWidget {
  final AppController? controller;

  const WatchDogApp({super.key, this.controller});

  @override
  State<WatchDogApp> createState() => _WatchDogAppState();
}

class _WatchDogAppState extends State<WatchDogApp> {
  late final AppController controller;
  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();
  final GlobalKey<ChatPageState> _chatKey = GlobalKey<ChatPageState>();
  final TextEditingController _chatInput =
      TextEditingController(); // 辅助页输入条（全局底部聊天操作条）
  final FocusNode _chatInputFocus = FocusNode(); // 辅助页文字输入切换按钮聚焦目标
  int _tab = 2; // 警情处置默认进入（tab 顺序：日志0/看板1/警情处置2/辅助3/设置4）
  int _preChatTab = 2; // 进入辅助页前的 tab（顶部返回/系统返回都回来源页而非固定看板）
  bool _pendingVoice = false; // 底部语音按钮长按 → 切换到警情处置后自动开始录音
  bool _recording = false; // 录音状态（页面上报，驱动底部按钮停止图标+脉冲）
  bool _processing = false; // 识别/确认中（禁用语音按钮，避免重复触发）
  bool _chatSending = false; // 问答请求中（底部发送按钮转圈禁用）
  bool _chatTextMode = false; // 辅助页输入模式：false=悬浮麦克风（默认）；true=文字输入（麦克风隐藏）

  @override
  void initState() {
    super.initState();
    controller =
        widget.controller ?? AppController(localAsr: LocalAsrService());
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
    // 启动即静默检查 GitHub Releases：有新版本时设置页显示提示（失败静默）
    controller.checkUpdateSilently();
  }

  @override
  void dispose() {
    _chatInput.dispose();
    _chatInputFocus.dispose();
    controller.dispose();
    super.dispose();
  }

  void _selectTab(int i) {
    if (controller.needsIncidentSelection) return;
    HapticFeedback.selectionClick();
    DiagnosticLogService.instance.setPage(_pageName(i));
    setState(() {
      if (i == 3 && _tab != 3) _preChatTab = _tab; // 记录进入辅助页前的来源页
      _tab = i;
      if (i != 3) _chatTextMode = false; // 离开辅助页重置为悬浮麦克风态
    });
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
    if (controller.needsIncidentSelection) return;
    if (_recording) {
      if (_tab == 3) {
        _chatKey.currentState?.finishRecording();
      } else {
        _homeKey.currentState?.finishRecording();
      }
    } else {
      _goVoice();
    }
  }

  void _voiceLongPressStart(LongPressStartDetails _) {
    if (controller.needsIncidentSelection) return;
    HapticFeedback.mediumImpact();
    if (_processing) return;
    // 问答页就地录音：转写文本直接发给辅助 AI
    if (_tab == 3) {
      _chatKey.currentState?.beginRecording();
      return;
    }
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
    if (controller.needsIncidentSelection) return;
    if (_pendingVoice) {
      // 切页后的首帧录音尚未启动时松手，取消自动录音请求。
      setState(() => _pendingVoice = false);
      return;
    }
    if (_tab == 3) {
      _chatKey.currentState?.finishRecording();
    } else {
      _homeKey.currentState?.finishRecording();
    }
  }

  /// 语音识别为火场日志：自动记入 + 跳日志页
  Future<void> _routeNote(String text) async {
    if (controller.needsIncidentSelection) return;
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
        ScaffoldMessenger.of(context).showSnackBar(
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

  /// 辅助页底部操作条发送（文字/语音识别为提问）
  void _chatSubmit(String text) {
    if (controller.needsIncidentSelection) return;
    final clean = text.trim();
    if (clean.isEmpty) return;
    _chatInput.clear();
    _chatKey.currentState?.submitQuestion(clean);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '火场智控',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AnimatedBuilder(
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
            ),
            ChatPage(
              key: _chatKey,
              controller: controller,
              onBack: () => _selectTab(_preChatTab),
              onRecordingChanged: (v) => setState(() => _recording = v),
              onProcessingChanged: (v) => setState(() => _processing = v),
              onSendingChanged: (v) => setState(() => _chatSending = v),
            ),
            SettingsPage(controller: controller),
          ];
          // 辅助页系统返回键 = 回来源页（与顶部返回箭头一致）；其它页维持系统默认（退出）
          final startupGateLocked =
              controller.needsAuthentication ||
              controller.needsIncidentSelection;
          final appScaffold = Scaffold(
            body: IndexedStack(index: _tab, children: pages),
            bottomNavigationBar: ExcludeSemantics(
              excluding: startupGateLocked,
              child: IgnorePointer(
                ignoring: startupGateLocked,
                child: _BottomNav(
                  index: _tab,
                  recording: _recording,
                  processing: _processing,
                  chatMode: _tab == 3,
                  chatTextMode: _chatTextMode,
                  chatController: _chatInput,
                  chatInputFocus: _chatInputFocus,
                  chatSending: _chatSending,
                  onChatSubmit: _chatSubmit,
                  onChatTextModeChange: (v) {
                    if (startupGateLocked) return;
                    setState(() => _chatTextMode = v);
                    if (v) {
                      _chatInputFocus.requestFocus();
                    } else {
                      _chatInputFocus.unfocus();
                    }
                  },
                  onSelect: _selectTab,
                  onVoiceTap: _voiceTap,
                  onVoiceLongPressStart: _voiceLongPressStart,
                  onVoiceLongPressEnd: _voiceLongPressEnd,
                ),
              ),
            ),
          );
          return PopScope(
            canPop: !startupGateLocked && _tab != 3,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && !startupGateLocked && _tab == 3) {
                _selectTab(_preChatTab);
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                appScaffold,
                if (startupGateLocked)
                  IncidentSelectionOverlay(
                    authenticationRequired: controller.needsAuthentication,
                    activeIncidents: controller.activeIncidents,
                    loading:
                        !controller.needsAuthentication &&
                        (controller.syncing || controller.api == null),
                    onAuthenticate: (unitName, name, code) =>
                        controller.authenticate(
                          unitName: unitName,
                          realName: name,
                          unitCode: code,
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
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 底部导航：日志 / 看板 / 中央凸起语音按钮 / 辅助 / 设置（左右对称）
/// 辅助页（chatMode）：默认仅悬浮麦克风入口（无导航、无输入框）；
/// 点「文字」切换为文字输入（麦克风隐藏，输入框+键盘呼出）
class _BottomNav extends StatelessWidget {
  final int index;
  final bool recording; // 录音中：按钮变停止图标 + 橙色脉冲 + 上方提示
  final bool processing; // 识别/确认中：禁用语音按钮
  final bool chatMode; // 辅助页：底部变身聊天操作条（语音+输入+发送）
  final bool chatTextMode; // 辅助页文字输入模式（true=输入框，麦克风隐藏）
  final TextEditingController chatController;
  final FocusNode chatInputFocus; // 文字输入切换按钮的聚焦目标
  final bool chatSending; // 问答请求中：发送按钮转圈
  final ValueChanged<String> onChatSubmit;
  final ValueChanged<bool> onChatTextModeChange; // 切换文字/语音输入模式
  final ValueChanged<int> onSelect;
  final VoidCallback onVoiceTap;
  final GestureLongPressStartCallback onVoiceLongPressStart;
  final GestureLongPressEndCallback onVoiceLongPressEnd;

  const _BottomNav({
    required this.index,
    required this.recording,
    required this.processing,
    required this.chatMode,
    required this.chatTextMode,
    required this.chatController,
    required this.chatInputFocus,
    required this.chatSending,
    required this.onChatSubmit,
    required this.onChatTextModeChange,
    required this.onSelect,
    required this.onVoiceTap,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    // Scaffold 不会把 bottomNavigationBar 顶过键盘（body 才避让），
    // 这里手动加 viewInsets 底边距，让辅助页输入条悬浮在键盘上方。
    final keyboardInset = chatMode
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    if (chatMode) {
      if (!chatTextMode) {
        // 语音态：中央凸起圆形橙色麦克风（与普通页 VoiceButton 一致）+ 左侧「文字」切换，无输入框
        return Container(
          key: const Key('bottom-nav-surface'),
          height: 68 + safeBottom,
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: -2,
                child: Center(
                  child: VoiceButton(
                    recording: recording,
                    processing: processing,
                    enabled: true,
                    onTap: onVoiceTap,
                    onLongPressStart: onVoiceLongPressStart,
                    onLongPressEnd: onVoiceLongPressEnd,
                  ),
                ),
              ),
              if (recording)
                Positioned(
                  left: 0,
                  right: 0,
                  top: -64,
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
                      child: const Text(
                        '正在聆听，松开结束',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: safeBottom,
                child: SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      Expanded(
                        child: _TextInputToggle(
                          textMode: false,
                          onTap: () => onChatTextModeChange(true),
                        ),
                      ),
                      const Expanded(child: SizedBox()),
                      const Expanded(child: SizedBox()),
                      const Expanded(child: SizedBox()),
                      const Expanded(child: SizedBox()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
      // 文字态：输入框 + 发送（呼出键盘），麦克风隐藏，底部「语音」切换回语音态
      return Container(
        key: const Key('bottom-nav-surface'),
        padding: EdgeInsets.only(bottom: safeBottom + keyboardInset),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ChatActionBar(
              controller: chatController,
              focusNode: chatInputFocus,
              sending: chatSending,
              onSend: () => onChatSubmit(chatController.text),
            ),
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const Expanded(child: SizedBox()),
                  const Expanded(child: SizedBox()),
                  Expanded(
                    child: _TextInputToggle(
                      textMode: true,
                      onTap: () => onChatTextModeChange(false),
                    ),
                  ),
                  const Expanded(child: SizedBox()),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      key: const Key('bottom-nav-surface'),
      height: 68 + safeBottom,
      // 普通警情处置页的麦克风是底部主操作，不再用顶部灰色横线切割它。
      decoration: const BoxDecoration(color: AppColors.surface),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: -2,
            child: Center(
              child: VoiceButton(
                recording: recording,
                processing: processing,
                enabled: true,
                onTap: onVoiceTap,
                onLongPressStart: onVoiceLongPressStart,
                onLongPressEnd: onVoiceLongPressEnd,
              ),
            ),
          ),
          if (recording)
            Positioned(
              left: 0,
              right: 0,
              top: -64,
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
                  child: const Text(
                    '正在聆听，松开结束',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: safeBottom,
            child: SizedBox(
              height: 56,
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
                      onTap: () => onSelect(1),
                    ),
                  ),
                  const Expanded(child: SizedBox()),
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
                      onTap: () => onSelect(4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 辅助页文字输入操作条：输入框 + 发送（仅文字态显示，无麦克风图标）
class _ChatActionBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool sending;
  final VoidCallback onSend;

  const _ChatActionBar({
    required this.controller,
    this.focusNode,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 104),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (v) => onSend(),
                decoration: const InputDecoration(
                  hintText: '输入你的问题…',
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: sending ? null : onSend,
            style: FilledButton.styleFrom(
              minimumSize: const Size(56, 56),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
            child: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

/// 辅助页输入模式切换按钮：语音态显示「文字」，文字态显示「语音」，互斥切换
class _TextInputToggle extends StatelessWidget {
  final bool textMode; // true=当前为文字输入模式
  final VoidCallback onTap;

  const _TextInputToggle({required this.textMode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final icon = textMode ? Icons.mic_rounded : Icons.keyboard_alt_outlined;
    final label = textMode ? '语音' : '文字';
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    const color = AppColors.textTertiary;
    return Semantics(
      label: textMode ? '切换为语音输入' : '切换为文字输入',
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(vertical: 2),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.translate(
                  offset: const Offset(0, -1),
                  child: Icon(icon, size: 28, color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.1,
                    fontWeight: FontWeight.w400,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final NavGlyph glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.glyph,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.textPrimary : AppColors.textTertiary;
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(vertical: 2),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.translate(
                  offset: const Offset(0, -1),
                  child: NavIcon(glyph: glyph, color: color, size: 28),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
