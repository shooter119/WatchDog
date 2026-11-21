import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/design_system.dart';
import '../../services/op_log_service.dart';
import '../../state/app_controller.dart';

/// 新外壳底部中置语音键运行态（与 Design System v3.0 [DsVoiceState] 保持同义）。
typedef DsVoiceButtonState = DsVoiceState;

/// 语音交互提示回调（由外壳接至 `ScaffoldMessenger` 展示浮动提示）。
typedef ShellVoiceMessageCallback =
    void Function(String message, {Duration duration});

/// 全局语音执行槽位。
///
/// M2 过渡期由 `LegacyTabAdapters` 桥接至既有 `HomePage` / `ChatPage`；
/// M3b 上线全局 `VoiceSessionStore` 后可直接替换本槽位，无需重写 `CommandAppShell`。
@immutable
class ShellVoiceSlot {
  const ShellVoiceSlot({
    this.beginCommandRecording,
    this.finishCommandRecording,
    this.beginCopilotRecording,
    this.finishCopilotRecording,
    this.dismissCopilotKeyboard,
    this.submitCopilotQuestion,
    this.supportsInPlaceCommandRecording = false,
  });

  /// 启动指挥台/全局火场语音录入。
  final VoidCallback? beginCommandRecording;

  /// 结束指挥台/全局火场语音录入并触发转写解析。
  final VoidCallback? finishCommandRecording;

  /// 在「智能辅助」Tab 就地开始语音提问录音。
  final Future<void> Function()? beginCopilotRecording;

  /// 在「智能辅助」Tab 就地结束语音提问录音。
  final Future<void> Function()? finishCopilotRecording;

  /// 离开「智能辅助」Tab 或长按语音前收起软键盘。
  final VoidCallback? dismissCopilotKeyboard;

  /// 将语音识别为「提问」的文本投递至「智能辅助」Tab 并发送。
  final void Function(String question)? submitCopilotQuestion;

  /// 是否支持在非指挥台 Tab 原地启动全局语音录音（M2 过渡期为 `false`，M3b 为 `true`）。
  final bool supportsInPlaceCommandRecording;
}

/// 新外壳中置 64dp 语音指令键交互桥接器。
///
/// 统一托管：
/// - 0-indexed 4 Tab 索引契约（0 指挥台 / 1 现场监控 / 2 智能辅助 / 3 我的）；
/// - 短按（停止录音 / 指挥台操作提示 / 切回指挥台）与长按（开始/松手/取消）手势；
/// - Tab 2（智能辅助）就地语音提问分流；
/// - 语音按钮三态 [DsVoiceButtonState]（`idle` / `recording` / `processing`）；
/// - 意图路由（`note` 自动记日志、`ask` 跳转提问、`entry` 确认后跳现场监控）。
class ShellVoiceBridge extends ChangeNotifier {
  ShellVoiceBridge({
    required this.controller,
    required this.onSelectTab,
    this.onShowMessage,
    this.onNoteSaved,
    ShellVoiceSlot slot = const ShellVoiceSlot(),
    int initialTab = commandTabIndex,
  }) : _slot = slot,
       _activeTab = initialTab;

  /// Tab 0：指挥台（默认首页）。
  static const int commandTabIndex = 0;

  /// Tab 1：现场监控（空呼安全看板）。
  static const int monitorTabIndex = 1;

  /// Tab 2：智能辅助（Copilot，长按语音键原地提问）。
  static const int copilotTabIndex = 2;

  /// Tab 3：我的（身份 + 队站管理 + 系统设置）。
  static const int mineTabIndex = 3;

  final AppController controller;
  final ValueChanged<int> onSelectTab;
  final ShellVoiceMessageCallback? onShowMessage;
  final VoidCallback? onNoteSaved;

  ShellVoiceSlot _slot;
  int _activeTab;
  bool _pendingAutoRecord = false;
  bool _commandRecording = false;
  bool _commandProcessing = false;
  bool _copilotRecording = false;
  bool _copilotProcessing = false;

  /// 当前激活的语音槽位实现。
  ShellVoiceSlot get slot => _slot;

  /// 当前激活的 0-indexed Tab。
  int get activeTab => _activeTab;

  /// 过渡期标志：从其他 Tab 长按切回 Tab 0 后自动触发一次录音。
  bool get pendingAutoRecord => _pendingAutoRecord;

  /// 指挥台/全局火场语音是否处于录音中。
  bool get commandRecording => _commandRecording;

  /// 指挥台/全局火场语音是否处于识别/确认处理中。
  bool get commandProcessing => _commandProcessing;

  /// 智能辅助 Tab 是否处于就地录音中。
  bool get copilotRecording => _copilotRecording;

  /// 智能辅助 Tab 是否处于就地识别处理中。
  bool get copilotProcessing => _copilotProcessing;

  /// 当前 Tab 对应的有效录音态。
  bool get isRecording =>
      _activeTab == copilotTabIndex ? _copilotRecording : _commandRecording;

  /// 当前 Tab 对应的有效识别处理态。
  bool get isProcessing =>
      _activeTab == copilotTabIndex ? _copilotProcessing : _commandProcessing;

  /// 驱动 `CommandNavBar` 中置语音键的三态枚举。
  DsVoiceButtonState get voiceState {
    if (isProcessing) return DsVoiceButtonState.processing;
    if (isRecording) return DsVoiceButtonState.recording;
    return DsVoiceButtonState.idle;
  }

  /// 动态替换语音槽位（便于 M3b 平滑接入 `VoiceSessionStore` 或测试注入）。
  void updateSlot(ShellVoiceSlot nextSlot) {
    _slot = nextSlot;
  }

  /// 同步外壳当前激活 Tab，在语音键展示态发生变化时通知监听方。
  void syncActiveTab(int tabIndex) {
    if (_activeTab == tabIndex) return;
    final previousState = voiceState;
    _activeTab = tabIndex;
    if (voiceState != previousState) {
      notifyListeners();
    }
  }

  /// 切离某 Tab 前执行清理（离开智能辅助页时结束就地录音并收起软键盘）。
  void handleTabLeaving(int previousTab, int nextTab) {
    if (previousTab == copilotTabIndex && nextTab != copilotTabIndex) {
      if (_copilotRecording) {
        unawaited(_slot.finishCopilotRecording?.call());
      }
      _slot.dismissCopilotKeyboard?.call();
    }
  }

  /// 消费过渡期自动录音请求（由旧 `HomePage` 在首帧触发后回调）。
  void consumePendingAutoRecord() {
    _pendingAutoRecord = false;
  }

  /// 上报指挥台/全局语音录音态变化。
  void setCommandRecording(bool value) {
    if (_commandRecording == value) return;
    _commandRecording = value;
    notifyListeners();
  }

  /// 上报指挥台/全局语音识别处理态变化。
  void setCommandProcessing(bool value) {
    if (_commandProcessing == value) return;
    _commandProcessing = value;
    notifyListeners();
  }

  /// 上报智能辅助就地录音态变化。
  void setCopilotRecording(bool value) {
    if (_copilotRecording == value) return;
    _copilotRecording = value;
    notifyListeners();
  }

  /// 上报智能辅助就地识别处理态变化。
  void setCopilotProcessing(bool value) {
    if (_copilotProcessing == value) return;
    _copilotProcessing = value;
    notifyListeners();
  }

  /// 短按中置语音键：
  /// - 录音中作为兜底停止出口（应对松手时机丢失或权限弹窗打断）；
  /// - 处理中屏蔽重复触发；
  /// - 指挥台页提示「长按说话，松开识别」，其余页切回指挥台。
  void handleVoiceTap() {
    if (controller.needsAuthentication || controller.needsIncidentSelection) {
      return;
    }
    if (_activeTab == copilotTabIndex) {
      if (_copilotRecording) {
        unawaited(_slot.finishCopilotRecording?.call());
        return;
      }
      if (_copilotProcessing) return;
      onSelectTab(commandTabIndex);
      return;
    }
    if (_commandRecording) {
      _slot.finishCommandRecording?.call();
      return;
    }
    if (_commandProcessing) return;
    if (_activeTab == commandTabIndex) {
      HapticFeedback.lightImpact();
      onShowMessage?.call(
        '长按说话，松开识别',
        duration: const Duration(seconds: 2),
      );
    } else {
      onSelectTab(commandTabIndex);
    }
  }

  /// 长按开始：
  /// - Tab 2（智能辅助）原地开始语音提问；
  /// - 其余 Tab 校验已绑定警情后原地或切回指挥台开始火场语音录入。
  void handleVoiceLongPressStart(LongPressStartDetails _) {
    if (controller.needsAuthentication || controller.needsIncidentSelection) {
      return;
    }
    if (_activeTab == copilotTabIndex) {
      if (_copilotProcessing) return;
      HapticFeedback.mediumImpact();
      _slot.dismissCopilotKeyboard?.call();
      unawaited(_slot.beginCopilotRecording?.call());
      return;
    }
    if (controller.requiresIncident) {
      controller.requestIncidentSelection();
      return;
    }
    if (_commandProcessing) return;
    HapticFeedback.mediumImpact();
    if (_slot.supportsInPlaceCommandRecording ||
        _activeTab == commandTabIndex) {
      _slot.beginCommandRecording?.call();
    } else {
      _pendingAutoRecord = true;
      onSelectTab(commandTabIndex);
      notifyListeners();
    }
  }

  /// 长按松开：结束录音并触发转写解析；若切页首帧尚未开录则取消待录请求。
  void handleVoiceLongPressEnd(LongPressEndDetails _) {
    if (controller.needsAuthentication || controller.needsIncidentSelection) {
      return;
    }
    if (_activeTab == copilotTabIndex || _copilotRecording) {
      unawaited(_slot.finishCopilotRecording?.call());
      return;
    }
    if (controller.requiresIncident) return;
    if (_pendingAutoRecord) {
      _pendingAutoRecord = false;
      notifyListeners();
      return;
    }
    _slot.finishCommandRecording?.call();
  }

  /// 长按被系统手势打断：安全结束已开始的录音或清除待录标志。
  void handleVoiceLongPressCancel() {
    if (_activeTab == copilotTabIndex || _copilotRecording) {
      unawaited(_slot.finishCopilotRecording?.call());
      return;
    }
    if (_pendingAutoRecord) {
      _pendingAutoRecord = false;
      notifyListeners();
      return;
    }
    if (_commandRecording) {
      _slot.finishCommandRecording?.call();
    }
  }

  /// 语音识别为火场日志：自动记入并触发可见反馈与日志入口跳转。
  Future<void> routeNoteIntent(String text) async {
    if (controller.needsIncidentSelection) return;
    if (controller.requiresIncident) {
      controller.requestIncidentSelection();
      return;
    }
    var saved = false;
    try {
      await controller.addNote(text);
      saved = true;
    } catch (error) {
      OpLogService.instance.record(
        'note-${DateTime.now().millisecondsSinceEpoch}',
        'note_add_fail',
        '自动记日志失败：$error',
        level: 'error',
        data: <String, dynamic>{'text': text},
      );
      onShowMessage?.call(
        '记日志失败：$error',
        duration: const Duration(seconds: 3),
      );
    }
    if (saved) {
      onNoteSaved?.call();
    }
  }

  /// 语音识别为提问：切至 Tab 2（智能辅助）并自动发送。
  void routeAskIntent(String text) {
    if (controller.needsIncidentSelection) return;
    onSelectTab(copilotTabIndex);
    _slot.submitCopilotQuestion?.call(text);
  }

  /// 进场语音确认完成后跳转 Tab 1（现场监控）。
  void routeEntryConfirmed() {
    onSelectTab(monitorTabIndex);
  }
}
