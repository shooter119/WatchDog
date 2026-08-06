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
  int _tab = 1; // 规范 2.3：App 启动默认进入看板（tab 顺序：日志0/看板1/语音2/辅助3/设置4）
  bool _pendingVoice = false; // 底部语音按钮长按 → 切换语音页后自动开始录音
  bool _recording = false; // 录音状态（页面上报，驱动底部按钮停止图标+脉冲）
  bool _processing = false; // 识别/确认中（禁用底部按钮，避免重复触发）

  @override
  void initState() {
    super.initState();
    controller.init();
  }

  @override
  void dispose() {
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
            ),
            SettingsPage(controller: controller),
          ];
          return Scaffold(
            body: IndexedStack(index: _tab, children: pages),
            bottomNavigationBar: _BottomNav(
              index: _tab,
              recording: _recording,
              processing: _processing,
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
class _BottomNav extends StatelessWidget {
  final int index;
  final bool recording; // 录音中：按钮变停止图标 + 橙色脉冲 + 上方提示
  final bool processing; // 识别/确认中：禁用语音按钮
  final ValueChanged<int> onSelect;
  final VoidCallback onVoiceTap;
  final GestureLongPressStartCallback onVoiceLongPressStart;
  final GestureLongPressEndCallback onVoiceLongPressEnd;

  const _BottomNav({
    required this.index,
    required this.recording,
    required this.processing,
    required this.onSelect,
    required this.onVoiceTap,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
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
