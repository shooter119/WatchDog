import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool enabled = true;
  Future<void>? _initFuture;

  Future<void> init() {
    if (_ready) return Future<void>.value();
    final pending = _initFuture;
    if (pending != null) return pending;
    final future = _initInternal();
    _initFuture = future;
    future.whenComplete(() {
      if (identical(_initFuture, future)) _initFuture = null;
    });
    return future;
  }

  Future<void> _initInternal() async {
    try {
      // Android 11+ 的包可见性限制下，先显式选择一个已安装的引擎；
      // 部分国产系统不会自动设置默认 TTS 引擎。
      final defaultEngine = await _tts.getDefaultEngine;
      if (defaultEngine == null || defaultEngine.toString().trim().isEmpty) {
        final engines = await _tts.getEngines;
        if (engines is List && engines.isNotEmpty) {
          await _tts.setEngine(engines.first.toString());
        }
      }

      var languageReady = false;
      for (final language in ['zh-CN', 'zh']) {
        try {
          final result = await _tts.setLanguage(language);
          if (result == 1 || result == true) {
            languageReady = true;
            break;
          }
        } catch (_) {
          // 尝试下一个中文 locale。
        }
      }
      if (!languageReady) {
        throw StateError('系统未安装可用的中文语音引擎或语音包');
      }
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      _ready = true;
    } catch (e) {
      _ready = false;
      // 初始化失败不能让主流程崩溃，但保留日志便于定位设备 TTS 配置问题。
      // 下一次 speak 会再次尝试初始化，允许用户安装/启用语音引擎后即时恢复。
      debugPrint('TtsService init failed: $e');
    }
  }

  /// 调度播报：等待初始化完成，避免启动阶段的首条播报被直接丢弃。
  void speak(String text) {
    if (!enabled || text.trim().isEmpty) return;
    unawaited(_speakWhenReady(text));
  }

  Future<void> _speakWhenReady(String text) async {
    try {
      if (!_ready) await init();
      if (!_ready || !enabled) return;
      await _tts.stop();
      final result = await _tts.speak(text, focus: true);
      if (result is num && result == 0) {
        _ready = false;
        debugPrint('TtsService speak rejected by system TTS engine');
      }
    } catch (e) {
      _ready = false;
      debugPrint('TtsService speak failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
