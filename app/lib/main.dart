import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/board_page.dart';
import 'pages/home_page.dart';
import 'pages/settings_page.dart';
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
  int _tab = 0; // 规范 2.3：App 启动默认进入看板
  bool _pendingVoice = false; // 底部语音按钮长按 → 切换语音页后自动开始录音
  bool _recording = false; // 录音状态（HomePage 上报，驱动底部按钮停止图标+脉冲）
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

  void _goVoice() => _selectTab(1);

  /// 录音中点击按钮 = 停止录音（松手时机丢失/权限弹窗场景的兜底出口）
  void _voiceTap() {
    if (_recording) {
      _homeKey.currentState?.finishRecording();
    } else {
      _goVoice();
    }
  }

  void _voiceLongPressStart(LongPressStartDetails _) {
    HapticFeedback.mediumImpact();
    if (_processing) return;
    if (_tab != 1) {
      setState(() {
        _tab = 1;
        _pendingVoice = true;
      });
    } else {
      _homeKey.currentState?.beginRecording();
    }
  }

  void _voiceLongPressEnd(LongPressEndDetails _) {
    _homeKey.currentState?.finishRecording();
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
            BoardPage(controller: controller, onGoVoice: _goVoice),
            HomePage(
              key: _homeKey,
              controller: controller,
              autoRecord: _pendingVoice,
              onAutoRecordConsumed: () => _pendingVoice = false,
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

/// 底部导航：看板 / 中央凸起语音按钮 / 设置（规范 2.2）
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
                  Expanded(child: _NavItem(icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard, label: '看板', selected: index == 0, onTap: () => onSelect(0))),
                  const SizedBox(width: 96),
                  Expanded(child: _NavItem(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置', selected: index == 2, onTap: () => onSelect(2))),
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
