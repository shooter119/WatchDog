import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool enabled = true;

  Future<void> init() async {
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// 立即调度播报，不等待 TTS 引擎完成（火场场景对延迟敏感）
  void speak(String text) {
    if (!_ready || !enabled) return;
    _tts.stop();
    _tts.speak(text);
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
