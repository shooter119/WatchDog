import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

/// 本地语音识别服务：sherpa-onnx（Paraformer 中文小模型 int8，约 78MB）。
/// 模型文件首次使用时下载到应用支持目录，之后完全离线可识别。
/// 注意：Paraformer 离线模型仅支持 greedy_search，不支持热词加权。
class LocalAsrService {
  static const modelName = 'paraformer-zh-small-2024-03-09';
  static const _modelFile = 'model.int8.onnx';
  static const _tokensFile = 'tokens.txt';

  static const _mirrorBase =
      'https://hf-mirror.com/csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09/resolve/main';
  static const _originBase =
      'https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09/resolve/main';

  OfflineRecognizer? _recognizer;
  bool _initializing = false;
  Future<void>? _pendingInit;

  Future<Directory> _modelDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/asr_models/$modelName');
    await dir.create(recursive: true);
    return dir;
  }

  /// 模型是否已安装（两个文件齐全）
  Future<bool> isModelInstalled() async {
    final dir = await _modelDir();
    final modelOk = await File('${dir.path}/$_modelFile').exists();
    final tokensOk = await File('${dir.path}/$_tokensFile').exists();
    return modelOk && tokensOk;
  }

  /// 下载模型（model.int8.onnx + tokens.txt），带进度回调
  Future<void> downloadModel({void Function(int received, int total)? onProgress}) async {
    final dir = await _modelDir();
    await _downloadFile(
      url: '$_mirrorBase/$_modelFile',
      path: '${dir.path}/$_modelFile',
      onProgress: onProgress,
    );
    await _downloadFile(
      url: '$_mirrorBase/$_tokensFile',
      path: '${dir.path}/$_tokensFile',
      onProgress: onProgress,
    );
  }

  Future<void> _downloadFile({
    required String url,
    required String path,
    required void Function(int received, int total)? onProgress,
  }) async {
    final part = '$path.part';
    final urls = [url, url.replaceFirst(_mirrorBase, _originBase)];
    Object? lastError;
    for (final u in urls) {
      try {
        final client = http.Client();
        try {
          final res = await client.send(http.Request('GET', Uri.parse(u)));
          if (res.statusCode != 200) {
            lastError = HttpException('HTTP ${res.statusCode}');
            continue;
          }
          final total = res.contentLength ?? 0;
          final file = File(part).openWrite();
          var received = 0;
          try {
            await for (final chunk in res.stream) {
              file.add(chunk);
              received += chunk.length;
              onProgress?.call(received, total);
            }
          } finally {
            await file.flush();
            await file.close();
          }
          await File(part).rename(path);
          return;
        } finally {
          client.close();
        }
      } catch (e) {
        lastError = e;
        try {
          final f = File(part);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    throw StateError('模型下载失败: $lastError');
  }

  /// 删除已下载的模型（释放空间）
  Future<void> removeModel() async {
    _recognizer?.free();
    _recognizer = null;
    final dir = await _modelDir();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 本地识别：wav 字节 → 文本。首次调用会加载模型（约 1-2 秒）。
  Future<String> transcribe(Uint8List wavBytes) async {
    await _ensureInitialized();
    final recognizer = _recognizer!;

    final wave = _parseWav(wavBytes);
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initializing) {
      if (_pendingInit != null) {
        await _pendingInit;
      }
      return;
    }
    if (_recognizer != null) {
      return;
    }
    _initializing = true;
    try {
      _pendingInit = _init();
      await _pendingInit;
    } finally {
      _initializing = false;
      _pendingInit = null;
    }
  }

  Future<void> _init() async {
    initBindings();
    final dir = await _modelDir();
    final modelPath = '${dir.path}/$_modelFile';
    final tokensPath = '${dir.path}/$_tokensFile';
    if (!await File(modelPath).exists() || !await File(tokensPath).exists()) {
      throw LocalAsrNotInstalledException();
    }
    _recognizer?.free();

    final config = OfflineRecognizerConfig(
      model: OfflineModelConfig(
        paraformer: OfflineParaformerModelConfig(model: modelPath),
        tokens: tokensPath,
        numThreads: 2,
      ),
      decodingMethod: 'greedy_search',
    );
    _recognizer = OfflineRecognizer(config);
  }
}

class _WavData {
  final Float32List samples;
  final int sampleRate;
  _WavData({required this.samples, required this.sampleRate});
}

/// 解析 RIFF wav（16-bit PCM）：遍历 chunk 找 fmt/data
_WavData _parseWav(Uint8List bytes) {
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw StateError('非 WAV 音频格式');
  }
  var sampleRate = 16000;
  var bitsPerSample = 16;
  int? dataStart;
  int? dataLength;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = ByteData.sublistView(bytes).getUint32(offset + 4, Endian.little);
    if (chunkId == 'fmt ') {
      sampleRate = ByteData.sublistView(bytes).getUint32(offset + 12, Endian.little);
      bitsPerSample = ByteData.sublistView(bytes).getUint16(offset + 22, Endian.little);
    } else if (chunkId == 'data') {
      dataStart = offset + 8;
      dataLength = size;
      break;
    }
    offset += 8 + size + (size % 2);
  }
  if (dataStart == null || dataLength == null) {
    throw StateError('WAV 缺少数据区');
  }
  if (bitsPerSample != 16) {
    throw StateError('仅支持 16-bit PCM，实际 $bitsPerSample bit');
  }
  final data = ByteData.sublistView(bytes, dataStart, dataStart + dataLength);
  final count = dataLength ~/ 2;
  final samples = Float32List(count);
  for (var i = 0; i < count; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return _WavData(samples: samples, sampleRate: sampleRate);
}

/// 本地模型未安装：需先在设置中下载
class LocalAsrNotInstalledException implements Exception {
  @override
  String toString() => '本地语音模型未下载，请先在设置中下载';
}
