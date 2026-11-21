import 'package:flutter/material.dart';

import '../../design_system/design_system.dart';
import 'shell_keys.dart';
import 'shell_voice_bridge.dart';

/// 包装 [CommandNavBar]，以透明穿透锚点绑定 [ShellKeys.navBar]、Tab 与语音键 Key。
class ShellCommandNavBar extends StatelessWidget {
  const ShellCommandNavBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.voiceBridge,
    required this.onSelectTab,
  });

  final List<CommandNavTab> tabs;
  final int selectedIndex;
  final ShellVoiceBridge voiceBridge;
  final ValueChanged<int> onSelectTab;

  Widget _anchor(Key key) => MetaData(
    key: key,
    behavior: HitTestBehavior.translucent,
    child: const SizedBox.expand(),
  );

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      key: ShellKeys.navBar,
      height: DsSizes.voiceProtrusion + DsSizes.navBarHeight + safeBottom,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: <Widget>[
          CommandNavBar(
            tabs: tabs,
            selectedIndex: selectedIndex,
            voiceState: voiceBridge.voiceState,
            onSelectTab: onSelectTab,
            onVoiceTap: voiceBridge.handleVoiceTap,
            onVoiceLongPressStart: voiceBridge.handleVoiceLongPressStart,
            onVoiceLongPressEnd: voiceBridge.handleVoiceLongPressEnd,
            onVoiceLongPressCancel: voiceBridge.handleVoiceLongPressCancel,
          ),
          // 透明穿透锚点层：MetaData(HitTestBehavior.translucent) 进入命中链满足
          // 语义 Key 测试，同时返回 false 让指针事件 100% 穿透给 CommandNavBar。
          Positioned(
            left: 0,
            right: 0,
            top: DsSizes.voiceProtrusion,
            bottom: 0,
            child: Padding(
              padding: EdgeInsets.only(bottom: safeBottom),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: _anchor(ShellKeys.tabCommand)),
                  Expanded(child: _anchor(ShellKeys.tabMonitor)),
                  const SizedBox(width: DsSizes.voiceButton + DsSpacing.sm),
                  Expanded(child: _anchor(ShellKeys.tabCopilot)),
                  Expanded(child: _anchor(ShellKeys.tabMine)),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            child: SizedBox(
              width: DsSizes.voiceButton,
              height: DsSizes.voiceButton,
              child: _anchor(ShellKeys.voiceBtn),
            ),
          ),
        ],
      ),
    );
  }
}
