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
  final TextEditingController _chatInput = TextEditingController(); // 辅助页输入条（全局底部聊天操作条）
  int _tab = 1; // 规范 2.3：App 启动默认进入看板（tab 顺序：日志0/看板1/语音2/辅助3/设置4）
  bool _pendingVoice = false; // 底部语音按钮长按 → 切换语音页后自动开始录音
  bool _recording = false; // 录音状态（页面上报，驱动底部按钮停止图标+脉冲）
  bool _processing = false; // 识别/确认中（禁用语音按钮，避免重复触发）
  bool _chatSending = false; // 问答请求中（底部发送按钮转圈禁用）

  @override
  void initState() {
    super.initState();
    controller.init();
  }

  @override
  void dispose() {
    _chatInput.dispose();
    controller.dispose();
    super.dispose();
  }

  void _selectTab(int i) {
    HapticFeedback.selectionClick();
    setState(() => _tab = i);
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
              chatController: _chatInput,
              chatSending: _chatSending,
              onChatSubmit: _chatSubmit,
              onChatMicTap: _voiceTap,
              onChatMicLongPressStart: _voiceLongPressStart,
              onChatMicLongPressEnd: _voiceLongPressEnd,
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
/// 辅助页（chatMode）切换为聊天操作条：上行 语音+输入框+发送，下行 5 个导航入口（中央为语音页入口）
class _BottomNav extends StatelessWidget {
  final int index;
  final bool recording; // 录音中：按钮变停止图标 + 橙色脉冲 + 上方提示
  final bool processing; // 识别/确认中：禁用语音按钮
  final bool chatMode; // 辅助页：底部变身聊天操作条（语音+输入+发送）
  final TextEditingController chatController;
  final bool chatSending; // 问答请求中：发送按钮转圈
  final ValueChanged<String> onChatSubmit;
  final VoidCallback onChatMicTap;
  final GestureLongPressStartCallback onChatMicLongPressStart;
  final GestureLongPressEndCallback onChatMicLongPressEnd;
  final ValueChanged<int> onSelect;
  final VoidCallback onVoiceTap;
  final GestureLongPressStartCallback onVoiceLongPressStart;
  final GestureLongPressEndCallback onVoiceLongPressEnd;

  const _BottomNav({
    required this.index,
    required this.recording,
    required this.processing,
    required this.chatMode,
    required this.chatController,
    required this.chatSending,
    required this.onChatSubmit,
    required this.onChatMicTap,
    required this.onChatMicLongPressStart,
    required this.onChatMicLongPressEnd,
    required this.onSelect,
    required this.onVoiceTap,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    if (chatMode) {
      return Container(
        height: 56 + 50 + 1 + safeBottom, // +1 补偿顶部 border 占用的内容高度
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          children: [
            _ChatActionBar(
              controller: chatController,
              sending: chatSending,
              recording: recording,
              onSend: () => onChatSubmit(chatController.text),
              onMicTap: onChatMicTap,
              onMicLongPressStart: onChatMicLongPressStart,
              onMicLongPressEnd: onChatMicLongPressEnd,
            ),
            SizedBox(
              height: 50,
              child: Row(
                children: [
                  Expanded(child: _NavItem(icon: Icons.note_alt_outlined, selectedIcon: Icons.note_alt, label: '日志', selected: index == 0, onTap: () => onSelect(0))),
                  Expanded(child: _NavItem(icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard, label: '看板', selected: index == 1, onTap: () => onSelect(1))),
                  _VoiceNavEntry(
                    recording: recording,
                    processing: processing,
                    onTap: onVoiceTap,
                    onLongPressStart: onVoiceLongPressStart,
                    onLongPressEnd: onVoiceLongPressEnd,
                  ),
                  Expanded(child: _NavItem(icon: Icons.chat_bubble_outline_rounded, selectedIcon: Icons.chat_bubble_rounded, label: '辅助', selected: index == 3, onTap: () => onSelect(3))),
                  Expanded(child: _NavItem(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置', selected: index == 4, onTap: () => onSelect(4))),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 60 + safeBottom,
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.voice,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    boxShadow: AppShadow.float,
                  ),
                  child: const Text(
                    '正在聆听，松开结束',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: safeBottom,
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Expanded(child: _NavItem(icon: Icons.note_alt_outlined, selectedIcon: Icons.note_alt, label: '日志', selected: index == 0, onTap: () => onSelect(0))),
                  Expanded(child: _NavItem(icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard, label: '看板', selected: index == 1, onTap: () => onSelect(1))),
                  const SizedBox(width: 96),
                  Expanded(child: _NavItem(icon: Icons.chat_bubble_outline_rounded, selectedIcon: Icons.chat_bubble_rounded, label: '辅助', selected: index == 3, onTap: () => onSelect(3))),
                  Expanded(child: _NavItem(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置', selected: index == 4, onTap: () => onSelect(4))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 辅助页聊天操作条：语音（长按录音）+ 输入框 + 发送
class _ChatActionBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final bool recording;
  final VoidCallback onSend;
  final VoidCallback onMicTap;
  final GestureLongPressStartCallback onMicLongPressStart;
  final GestureLongPressEndCallback onMicLongPressEnd;

  const _ChatActionBar({
    required this.controller,
    required this.sending,
    required this.recording,
    required this.onSend,
    required this.onMicTap,
    required this.onMicLongPressStart,
    required this.onMicLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onMicTap,
            onLongPressStart: onMicLongPressStart,
            onLongPressEnd: onMicLongPressEnd,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: recording ? AppColors.voice : AppColors.actionPrimary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                recording ? Icons.stop_rounded : Icons.mic_rounded,
                size: 22,
                color: recording ? Colors.white : AppColors.actionPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
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
          const SizedBox(width: 8),
          FilledButton(
            onPressed: sending ? null : onSend,
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
            ),
            child: sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

/// 聊天模式下中央「语音页」入口（点击进语音页，长按就地录音）
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
    final color = recording ? AppColors.voice : AppColors.textSecondary;
    return GestureDetector(
      onTap: processing ? null : onTap,
      onLongPressStart: processing ? null : onLongPressStart,
      onLongPressEnd: processing ? null : onLongPressEnd,
      child: SizedBox(
        width: 76,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(recording ? Icons.stop_rounded : Icons.mic_rounded, size: 24, color: color),
            const SizedBox(height: 3),
            Text(
              recording ? '停止' : '语音',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(selected ? selectedIcon : icon, size: 22, color: color),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
