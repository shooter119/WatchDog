import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 录音服务：按住说话 → 返回 wav 音频字节
/// 注意：豆包 ASR 不支持 m4a/aac，必须用 wav/pcm
class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  String? _path;

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _path!,
    );
  }

  /// 录音电平（0-1），用于 UI 振幅动画
  Stream<double> amplitudeStream() {
    return _recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).map((a) {
      final v = a.current.clamp(0.0, 1.0);
      return v <= 0.01 ? 0.15 : v;
    });
  }

  Future<Uint8List> stop() async {
    final path = _path;
    _path = null;
    if (path == null) throw StateError('未在录音');
    await _recorder.stop();
    final file = File(path);
    if (!await file.exists()) throw StateError('录音文件不存在');
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {}
    return bytes;
  }

  Future<void> dispose() => _recorder.dispose();
}
