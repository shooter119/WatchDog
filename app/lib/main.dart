import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/board_page.dart';
import 'pages/chat_page.dart';
import 'pages/home_page.dart';
import 'pages/notes_page.dart';
import 'pages/settings_page.dart';
import 'models/models.dart';
import 'services/local_asr_service.dart';
import 'state/app_controller.dart';
import 'theme/app_theme.dart';
import 'theme/app_widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WatchDogApp());
}

class WatchDogApp extends StatefulWidget {
  const WatchDogApp({super.key});

  @override
  State<WatchDogApp> createState() => _WatchDogAppState();
}

class _WatchDogAppState extends State<WatchDogApp> {
  final AppController controller = AppController(localAsr: LocalAsrService());
  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();
  final GlobalKey<ChatPageState> _chatKey = GlobalKey<ChatPageState>();
  final TextEditingController _chatInput =
      TextEditingController(); // 辅助页输入条（全局底部聊天操作条）
  final FocusNode _chatInputFocus = FocusNode(); // 辅助页文字输入切换按钮聚焦目标
  int _tab = 1; // 规范 2.3：App 启动默认进入看板（tab 顺序：日志0/看板1/语音2/辅助3/设置4）
  bool _pendingVoice = false; // 底部语音按钮长按 → 切换语音页后自动开始录音
  bool _recording = false; // 录音状态（页面上报，驱动底部按钮停止图标+脉冲）
  bool _processing = false; // 识别/确认中（禁用语音按钮，避免重复触发）
  bool _chatSending = false; // 问答请求中（底部发送按钮转圈禁用）
  bool _chatTextMode = false; // 辅助页输入模式：false=悬浮麦克风（默认）；true=文字输入（麦克风隐藏）

  @override
  void initState() {
    super.initState();
    controller.init();
  }

  @override
  void dispose() {
    _chatInput.dispose();
    _chatInputFocus.dispose();
    controller.dispose();
    super.dispose();
  }

  void _selectTab(int i) {
    HapticFeedback.selectionClick();
    setState(() {
      _tab = i;
      if (i != 3) _chatTextMode = false; // 离开辅助页重置为悬浮麦克风态
    });
  }

  void _goVoice() => _selectTab(2);

  /// 录音中点击按钮 = 停止录音（松手时机丢失/权限弹窗场景的兜底出口）
  void _voiceTap() {
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
    HapticFeedback.mediumImpact();
    if (_processing) return;
    // 问答页就地录音：识别为提问直接发本页，其余按意图路由
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
    if (_tab == 3) {
      _chatKey.currentState?.finishRecording();
    } else {
      _homeKey.currentState?.finishRecording();
    }
  }

  /// 语音识别为火场日志：自动记入 + 跳日志页
  Future<void> _routeNote(String text) async {
    try {
      await controller.addNote(text);
    } catch (_) {
      // 记日志失败不影响跳转，日志页可见失败原因
    }
    _selectTab(0);
  }

  /// 语音识别为提问：跳问答页并自动发送
  void _routeAsk(String text) {
    _selectTab(3);
    _chatKey.currentState?.submitQuestion(text);
  }

  /// 问答页就地录音识别为进出场：切语音页并展示确认面板
  void _routeEntryExit(String text, ParseResult parsed) {
    _selectTab(2);
    _homeKey.currentState?.applyVoiceResult(text, parsed);
  }

  /// 辅助页底部操作条发送（文字/语音识别为提问）
  void _chatSubmit(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    _chatInput.clear();
    _chatKey.currentState?.submitQuestion(clean);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '安全员助手',
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
            ),
            ChatPage(
              key: _chatKey,
              controller: controller,
              onBack: () => _selectTab(1),
              onEntryExit: _routeEntryExit,
              onNote: _routeNote,
              onRecordingChanged: (v) => setState(() => _recording = v),
              onProcessingChanged: (v) => setState(() => _processing = v),
              onSendingChanged: (v) => setState(() => _chatSending = v),
            ),
            SettingsPage(controller: controller),
          ];
          return Scaffold(
            body: IndexedStack(index: _tab, children: pages),
            bottomNavigationBar: _BottomNav(
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
    if (chatMode) {
      if (!chatTextMode) {
        // 语音态：中央悬浮麦克风 + 左侧「文字」切换，无输入框
        return Container(
          padding: EdgeInsets.only(bottom: safeBottom),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: SizedBox(
            height: 68,
            child: Row(
              children: [
                Expanded(
                  child: _TextInputToggle(
                    textMode: false,
                    onTap: () => onChatTextModeChange(true),
                  ),
                ),
                _VoiceNavEntry(
                  recording: recording,
                  processing: processing,
                  onTap: onVoiceTap,
                  onLongPressStart: onVoiceLongPressStart,
                  onLongPressEnd: onVoiceLongPressEnd,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        );
      }
      // 文字态：输入框 + 发送（呼出键盘），麦克风隐藏，底部「语音」切换回语音态
      return Container(
        padding: EdgeInsets.only(bottom: safeBottom),
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
                  Expanded(
                    child: _TextInputToggle(
                      textMode: true,
                      onTap: () => onChatTextModeChange(false),
                    ),
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
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
            top: -30,
            child: Center(
              child: VoiceButton(
                size: 80,
                recording: recording,
                enabled: !processing,
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
              top: -92,
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
                      icon: Icons.view_timeline_outlined,
                      selectedIcon: Icons.view_timeline,
                      label: '日志',
                      selected: index == 0,
                      onTap: () => onSelect(0),
                    ),
                  ),
                  Expanded(
                    child: _NavItem(
                      icon: Icons.dashboard_outlined,
                      selectedIcon: Icons.dashboard,
                      label: '看板',
                      selected: index == 1,
                      onTap: () => onSelect(1),
                    ),
                  ),
                  const SizedBox(width: 96),
                  Expanded(
                    child: _NavItem(
                      icon: Icons.support_agent_outlined,
                      selectedIcon: Icons.support_agent,
                      label: '辅助',
                      selected: index == 3,
                      onTap: () => onSelect(3),
                    ),
                  ),
                  Expanded(
                    child: _NavItem(
                      icon: Icons.tune_outlined,
                      selectedIcon: Icons.tune,
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
              minimumSize: const Size(48, 44),
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
    final color = textMode ? AppColors.textPrimary : AppColors.textTertiary;
    return Semantics(
      label: textMode ? '切换为语音输入' : '切换为文字输入',
      button: true,
      selected: textMode,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3),
            decoration: BoxDecoration(
              color: textMode ? AppColors.surfaceSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  textMode ? Icons.keyboard_alt_rounded : icon,
                  size: 24,
                  color: color,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: textMode ? FontWeight.w700 : FontWeight.w500,
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

/// 聊天模式下中央「语音页」入口（点击进语音页，长按就地录音）
/// 保持橙色语音层级：浅橙胶囊 + 橙色 mic，录音中橙底白字
class _VoiceNavEntry extends StatelessWidget {
  final bool recording;
  final bool processing;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final GestureLongPressEndCallback onLongPressEnd;

  const _VoiceNavEntry({
    required this.recording,
    required this.processing,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final recordingColor = Colors.white;
    final idleColor = AppColors.voice;
    return Semantics(
      label: recording ? '停止录音' : '语音录入（长按录音）',
      button: true,
      enabled: !processing,
      hint: recording ? '松开结束录音' : '点击进入语音页',
      child: GestureDetector(
        onTap: processing ? null : onTap,
        onLongPressStart: processing ? null : onLongPressStart,
        onLongPressEnd: processing ? null : onLongPressEnd,
        child: Container(
          width: 76,
          margin: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: recording
                ? AppColors.voice
                : AppColors.voice.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                recording ? Icons.stop_rounded : Icons.mic_rounded,
                size: 24,
                color: recording ? recordingColor : idleColor,
              ),
              const SizedBox(height: 4),
              Text(
                recording ? '停止' : '语音',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: recording ? recordingColor : idleColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导航项：选中 filled 图标 + surfaceSubtle 胶囊 + textPrimary，未选中 outlined + textTertiary
class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.textPrimary : AppColors.textTertiary;
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      container: true,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3),
            decoration: BoxDecoration(
              color: selected ? AppColors.surfaceSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(selected ? selectedIcon : icon, size: 24, color: color),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
