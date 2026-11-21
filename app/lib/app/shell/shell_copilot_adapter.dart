import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/copilot/state/copilot_store.dart';
import '../../features/copilot/ui/copilot_page.dart';
import '../../services/audio_service.dart';
import '../../services/realtime_asr_service.dart';
import '../../state/app_controller.dart';

/// 将 [AppController] 桥接为 M3d DS v3.0 [CopilotPage] 与 [CopilotStore]，
/// 托管 Tab 2 就地语音提问与来自全局语音 `ask` 意图的自动提问投递。
class ShellCopilotAdapter {
  ShellCopilotAdapter({
    required this.controller,
    AudioService? chatAudioService,
    CopilotStore? storeOverride,
    this.onOpenIncidentDetails,
  }) : _ownsStore = storeOverride == null,
       store =
           storeOverride ??
           CopilotStore(
             audioService: chatAudioService,
             gateway: CopilotGateway(
               readScope: () => controller.assistantScope,
               fetchHistory: controller.fetchChatHistory,
               askAssistantStream: controller.askAssistantStream,
               cancelAssistantRequest: controller.cancelAssistantRequest,
               clearHistory: controller.clearChatHistory,
               analyzeVision: controller.analyzeVision,
               transcribeAudio: controller.transcribeAudio,
               hasIncidentContext: () =>
                   controller.currentIncident?.info.isNotEmpty == true,
               onOpenIncidentDetails: onOpenIncidentDetails,
               isRealtimeAsrEnabled: () =>
                   controller.asrCloudEnabled && controller.api != null,
               createRealtimeSession: (CopilotRealtimeTextCallback onText) {
                 final api = controller.api;
                 if (api == null) return null;
                 return RealtimeAsrSessionAdapter(
                   RealtimeAsrService(api: api, onText: onText),
                 );
               },
               scopeListenable: controller,
             ),
           );

  final AppController controller;
  final VoidCallback? onOpenIncidentDetails;
  final CopilotStore store;
  final bool _ownsStore;

  final GlobalKey<CopilotPageState> pageKey = GlobalKey<CopilotPageState>();
  bool _disposed = false;

  /// 构建新外壳 Tab 2（智能辅助）页面。
  Widget buildCopilotPage(
    BuildContext context, {
    required ValueChanged<bool> onRecordingChanged,
    required ValueChanged<bool> onProcessingChanged,
  }) {
    return CopilotPage(
      key: pageKey,
      store: store,
      bottomNavClearance: 4.0,
      onRecordingChanged: onRecordingChanged,
      onProcessingChanged: onProcessingChanged,
      onOpenIncidentDetails: onOpenIncidentDetails,
    );
  }

  /// 在 Tab 2 原地开始语音提问录音。
  Future<void> beginRecording() =>
      pageKey.currentState?.beginRecording() ?? Future<void>.value();

  /// 结束 Tab 2 原地语音提问录音。
  Future<void> finishRecording() =>
      pageKey.currentState?.finishRecording() ?? Future<void>.value();

  /// 切离 Tab 2 或长按语音键前收起软键盘。
  void dismissKeyboard() => pageKey.currentState?.dismissKeyboard();

  /// 提交问题（来自全局语音 `ask` 意图自动跳转并发送）。
  void submitQuestion(String question) {
    final state = pageKey.currentState;
    if (state != null) {
      unawaited(state.submitQuestion(question));
    } else {
      unawaited(store.submitQuestion(question));
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsStore) {
      store.dispose();
    }
  }
}
