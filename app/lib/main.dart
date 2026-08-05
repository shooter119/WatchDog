import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/board_page.dart';
import 'pages/home_page.dart';
import 'pages/settings_page.dart';
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
  final AppController controller = AppController();
  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();
  int _tab = 0; // 规范 2.3：App 启动默认进入看板
  bool _pendingVoice = false; // 底部语音按钮长按 → 切换语音页后自动开始录音

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

  void _voiceLongPressStart(LongPressStartDetails _) {
    HapticFeedback.mediumImpact();
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
            ),
            SettingsPage(controller: controller),
          ];
          return Scaffold(
            body: IndexedStack(index: _tab, children: pages),
            bottomNavigationBar: _BottomNav(
              index: _tab,
              onSelect: _selectTab,
              onVoiceTap: _goVoice,
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
  final ValueChanged<int> onSelect;
  final VoidCallback onVoiceTap;
  final GestureLongPressStartCallback onVoiceLongPressStart;
  final GestureLongPressEndCallback onVoiceLongPressEnd;

  const _BottomNav({
    required this.index,
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
                onTap: onVoiceTap,
                onLongPressStart: onVoiceLongPressStart,
                onLongPressEnd: onVoiceLongPressEnd,
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
