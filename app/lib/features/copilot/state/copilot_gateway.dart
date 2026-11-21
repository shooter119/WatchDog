import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../data/models/chat_message.dart';
import '../data/models/vision_analysis.dart';
import 'copilot_voice_recorder.dart';

/// 流式渲染挂钩：由 UI 层接入揭示器，headless 单测可不挂接。
class CopilotStreamCallbacks {
  const CopilotStreamCallbacks({
    required this.onStart,
    required this.onChunk,
    required this.onComplete,
    required this.onStop,
  });

  final void Function(String streamId) onStart;
  final void Function(String streamId, String delta) onChunk;
  final void Function(String streamId, String fullReply) onComplete;
  final VoidCallback onStop;
}

/// 拍照图片预处理结果。
class CopilotPreparedImage {
  const CopilotPreparedImage.ok(this.bytes) : errorMessage = null;
  const CopilotPreparedImage.error(this.errorMessage) : bytes = null;

  final Uint8List? bytes;
  final String? errorMessage;
  bool get isValid => bytes != null && errorMessage == null;
}

/// 智能辅助域外部能力网关（零 `AppController` / 其他 Store 耦合）。
class CopilotGateway {
  const CopilotGateway({
    required this.readScope,
    required this.fetchHistory,
    required this.askAssistantStream,
    required this.cancelAssistantRequest,
    required this.clearHistory,
    required this.analyzeVision,
    required this.transcribeAudio,
    this.loadLegacyHistory,
    this.hasIncidentContext,
    this.onOpenIncidentDetails,
    this.isRealtimeAsrEnabled,
    this.createRealtimeSession,
    this.scopeListenable,
  });

  final String Function() readScope;
  final Future<List<ChatMessage>> Function() fetchHistory;
  final Future<String> Function(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history,
  })
  askAssistantStream;
  final VoidCallback cancelAssistantRequest;
  final Future<void> Function() clearHistory;
  final Future<VisionAnalysis> Function(
    Uint8List bytes, {
    required String mimeType,
    String message,
    String? opId,
  })
  analyzeVision;
  final Future<String> Function(Uint8List bytes, {String? opId})
  transcribeAudio;
  final Future<List<ChatMessage>> Function()? loadLegacyHistory;
  final bool Function()? hasIncidentContext;
  final VoidCallback? onOpenIncidentDetails;
  final bool Function()? isRealtimeAsrEnabled;
  final CopilotRealtimeSession? Function(CopilotRealtimeTextCallback onText)?
  createRealtimeSession;
  final Listenable? scopeListenable;
}

/// 拍照识险图片压缩默认实现：宽 ≤ 1600px、JPG quality=82。无法解码时返回空数组。
Uint8List compressCopilotVisionImage(
  Uint8List original, {
  int maxWidth = 1600,
  int quality = 82,
}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(original);
  } catch (_) {
    return Uint8List(0);
  }
  if (decoded == null) return Uint8List(0);
  final resized = decoded.width > maxWidth
      ? img.copyResize(decoded, width: maxWidth)
      : decoded;
  return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
}

/// 将结构化识险响应格式化为 4 段 Markdown 与免责声明。
String formatCopilotVisionAnalysis(VisionAnalysis analysis) {
  String section(String title, List<String> values) => values.isEmpty
      ? '$title\n暂无明确内容'
      : '$title\n${values.map((v) => '• $v').join('\n')}';
  final relevance = switch (analysis.relevance) {
    'related' => '相关',
    'unrelated' => '无关',
    'unsafe_to_judge' => '图片质量不足',
    _ => '关联性不明确',
  };
  return '**图片相关性：$relevance**\n\n'
      '${section('### 已确认事实', analysis.facts)}\n\n'
      '${section('### 可能风险', analysis.risks)}\n\n'
      '${section('### 待确认事项', analysis.toConfirm)}\n\n'
      '${section('### 建议措施', analysis.suggestions)}\n\n'
      '> ${analysis.disclaimer}';
}
