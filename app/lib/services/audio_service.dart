import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 录音服务：按住说话 → 返回 wav 音频字节
/// 注意：豆包 ASR 不支持 m4a/aac，必须用 wav/pcm
double normalizeAmplitudeDbfs(double dbfs) {
  if (!dbfs.isFinite) return 0.15;
  // record 插件返回 dBFS（通常为负值），映射到语音动画需要的 0~1。
  // -60dBFS 视作静音，保留微小底噪指示；0dBFS 为满幅。
  final normalized = ((dbfs + 60) / 60).clamp(0.0, 1.0).toDouble();
  return normalized <= 0.01 ? 0.15 : normalized;
}

class AudioService {
  static const maxAudioBytes = 15 * 1024 * 1024;
  final AudioRecorder _recorder = AudioRecorder();
  Future<void> _operationTail = Future<void>.value();
  String? _path;
  bool _disposed = false;

  bool get isRecording => _path != null;

  /// 检查并主动申请麦克风权限；不能依赖插件的默认参数，避免真机首次安装
  /// 时只检查不弹系统授权框，导致录音流程无声失败。
  Future<bool> hasPermission() => _recorder.hasPermission(request: true);

  Future<T> _enqueue<T>(Future<T> Function() operation) async {
    final previous = _operationTail;
    final gate = Completer<void>();
    _operationTail = gate.future;
    await previous;
    try {
      return await operation();
    } finally {
      gate.complete();
    }
  }

  Future<void> start() {
    return _enqueue(() async {
      if (_disposed) throw StateError('录音服务已释放');
      if (_path != null) throw StateError('录音正在进行');
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      _path = path;
      try {
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
            androidConfig: AndroidRecordConfig(
              audioSource: AndroidAudioSource.voiceRecognition,
            ),
          ),
          path: path,
        );
      } catch (_) {
        // recorder.start 可能已经创建了空文件；启动失败必须回滚所有权，
        // 否则下一次录音会覆盖路径并遗留无法清理的临时音频。
        _path = null;
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
        rethrow;
      }
    });
  }

  /// 录音电平（0-1），用于 UI 振幅动画
  Stream<double> amplitudeStream() {
    return _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .map((a) => normalizeAmplitudeDbfs(a.current));
  }

  Future<Uint8List> stop() {
    return _enqueue(() async {
      final path = _path;
      _path = null;
      if (path == null) throw StateError('未在录音');
      final file = File(path);
      try {
        await _recorder.stop();
        if (!await file.exists()) throw StateError('录音文件不存在');
        final length = await file.length();
        if (length > maxAudioBytes) {
          throw StateError('录音过长，已拒绝处理');
        }
        return await file.readAsBytes();
      } finally {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    });
  }

  Future<void> dispose() {
    return _enqueue(() async {
      if (_disposed) return;
      _disposed = true;
      final path = _path;
      _path = null;
      try {
        if (path != null) await _recorder.stop();
      } catch (_) {}
      if (path != null) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      await _recorder.dispose();
    });
  }
}
