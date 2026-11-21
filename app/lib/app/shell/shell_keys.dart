import 'package:flutter/foundation.dart';

/// 新外壳（Command App Shell）语义 `Key` 契约集中定义。
///
/// 全部值与 M2 架构契约及既有回归测试保持严格一致，供外壳组件、
/// 过渡期适配层与自动化测试统一引用，避免字符串硬编码漂移。
abstract final class ShellKeys {
  /// 新外壳根容器
  static const Key root = Key('shell-root');

  /// 底部 4 Tab + 中置语音键导航栏
  static const Key navBar = Key('shell-nav-bar');

  /// Tab 0：指挥台（默认首页）
  static const Key tabCommand = Key('shell-tab-command');

  /// Tab 1：现场监控（空呼安全看板）
  static const Key tabMonitor = Key('shell-tab-monitor');

  /// Tab 2：智能辅助（Copilot）
  static const Key tabCopilot = Key('shell-tab-copilot');

  /// Tab 3：我的（身份 + 队站管理 + 系统设置）
  static const Key tabMine = Key('shell-tab-mine');

  /// 底部中置 64dp 凸起全局语音指令键
  static const Key voiceBtn = Key('shell-voice-btn');

  /// 游客模式常驻顶部横幅
  static const Key guestBanner = Key('shell-guest-banner');

  /// 游客模式“转为正式队员”操作按钮（严格保留既有回归测试 Key）
  static const Key guestConvertBtn = Key('guest-convert-btn');

  /// 未登录/未选警情门禁锁覆盖层
  static const Key startupGate = Key('shell-startup-gate');

  /// 系统画中画（PiP）承载宿主
  static const Key pipHost = Key('shell-pip-host');

  /// 悬浮视频小窗承载节点
  static const Key floatingVideo = Key('shell-floating-video');

  /// 按 0-indexed 底栏顺序排列的 4 个 Tab 语义 Key。
  static const List<Key> tabs = <Key>[
    tabCommand,
    tabMonitor,
    tabCopilot,
    tabMine,
  ];

  /// 根据 0-indexed Tab 索引获取对应语义 Key（0: 指挥台, 1: 现场监控, 2: 智能辅助, 3: 我的）。
  static Key tabAt(int index) {
    RangeError.checkValidIndex(index, tabs, 'index');
    return tabs[index];
  }
}
