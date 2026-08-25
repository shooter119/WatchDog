import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'settings.dart';

/// 本地语音识别服务：sherpa-onnx 离线 zipformer-transducer 中文模型（multi-zh-hans int8，约 75MB）。
/// 多方言（普通话/粤语/上海话等）大模型，识别精度显著高于 14M 小模型；
/// 热词走 bbpe 字节编码（名单/术语写入 hotwords 文件，modified_beam_search 上下文加权），
/// 字节级词表对任意姓名无 OOV，生僻字人名同样生效。
/// 模型文件由 CloudBase 后端的 /models/ 路径分发，国内直连下载。
/// 注：streaming 系列模型 + bbpe 热词在 sherpa-onnx 1.13.4 存在 CreateOnlineRecognizer 崩溃，暂用离线版。
class LocalAsrService {
  static const modelName = 'multi-zh-hans-2023-9-2';
  static const _encoderFile = 'encoder-epoch-20-avg-1.int8.onnx';
  static const _decoderFile = 'decoder-epoch-20-avg-1.onnx';
  static const _joinerFile = 'joiner-epoch-20-avg-1.int8.onnx';
  static const _tokensFile = 'tokens.txt';
  static const _bpeVocabFile = 'bpe.vocab';
  static const _hotwordsFile = 'hotwords.txt';

  static const _downloadBase = '${Settings.defaultModelBaseUrl}/$modelName';

  /// 语音降噪模型（DPDFNet，9.8MB）：录音 → 降噪 → 识别，火场嘈杂环境提升人名/压力识别率。
  /// 与 ASR 模型同目录下载（denoiser/），缺失时自动跳过降噪（不影响识别主流程）。
  static const _denoiserName = 'denoiser';
  static const _denoiserFile = 'dpdfnet2.onnx';
  static const _denoiserDownloadBase =
      '${Settings.defaultModelBaseUrl}/$_denoiserName';

  /// 旧模型目录（streaming 系列含崩溃 bug / 14M 小模型精度差 / Paraformer 不支持热词 / x-asr 词表稀疏），下载新模型后清理
  static const _legacyModelDirs = [
    'paraformer-zh-small-2024-03-09',
    'x-asr-zipformer-transducer-zh-en-int8-2026-06-03',
    'streaming-zipformer-zh-14M-2023-02-23',
    'streaming-zipformer-zh-int8-2025-06-30',
    'streaming-zipformer-multi-zh-hans-int8-2023-12-13',
  ];

  OfflineRecognizer? _recognizer;
  String? _recognizerHotwordsSignature;
  OfflineSpeechDenoiser? _denoiser;
  bool _initializing = false;
  Future<void>? _pendingInit;

  Future<Directory> _modelDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/asr_models/$modelName');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _denoiserDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/asr_models/$_denoiserName');
    await dir.create(recursive: true);
    return dir;
  }

  /// 降噪模型是否已安装
  Future<bool> isDenoiserInstalled() async {
    final dir = await _denoiserDir();
    return File('${dir.path}/$_denoiserFile').exists();
  }

  /// 模型是否已安装（五个文件齐全）
  Future<bool> isModelInstalled() async {
    final dir = await _modelDir();
    for (final name in [_encoderFile, _decoderFile, _joinerFile, _tokensFile, _bpeVocabFile]) {
      if (!await File('${dir.path}/$name').exists()) return false;
    }
    return true;
  }

  /// 下载模型（encoder + decoder + joiner + tokens + bpe.vocab + 降噪模型），带进度回调
  Future<void> downloadModel({void Function(int received, int total)? onProgress}) async {
    final dir = await _modelDir();
    final apiToken = await Settings.apiToken;
    for (final name in [_encoderFile, _decoderFile, _joinerFile, _tokensFile, _bpeVocabFile]) {
      await _downloadFile(
        url: '$_downloadBase/$name',
        path: '${dir.path}/$name',
        apiToken: apiToken,
        onProgress: onProgress,
      );
    }
    // 降噪模型（DPDFNet）：失败不阻断 ASR 模型下载（降噪只是增强项）
    try {
      final ddir = await _denoiserDir();
      await _downloadFile(
        url: '$_denoiserDownloadBase/$_denoiserFile',
        path: '${ddir.path}/$_denoiserFile',
        apiToken: apiToken,
        onProgress: onProgress,
      );
    } catch (_) {
      // 降噪模型下载失败静默：识别仍可用，只是少了降噪
    }
    await _cleanupLegacyModels();
  }

  Future<void> _cleanupLegacyModels() async {
    final base = await getApplicationSupportDirectory();
    for (final name in _legacyModelDirs) {
      try {
        final dir = Directory('${base.path}/asr_models/$name');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _downloadFile({
    required String url,
    required String path,
    required String apiToken,
    required void Function(int received, int total)? onProgress,
  }) async {
    final part = '$path.part';
    final urls = [url, url];
    Object? lastError;
    for (final u in urls) {
      try {
        final client = http.Client();
        try {
          final request = http.Request('GET', Uri.parse(u));
          if (apiToken.isNotEmpty) request.headers['X-Api-Token'] = apiToken;
          final res = await client.send(request);
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
    _denoiser?.free();
    _denoiser = null;
    final dir = await _modelDir();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    final ddir = await _denoiserDir();
    try {
      await ddir.delete(recursive: true);
    } catch (_) {}
  }

  /// 本地识别：wav 字节 → 文本。首次调用会加载模型（约 1-2 秒）。
  /// 降噪模型已安装时先做 DPDFNet 语音增强，再喂识别器（火场嘈杂环境提升人名/压力识别率）。
  Future<String> transcribe(
    Uint8List wavBytes, {
    List<String> hotwords = const [],
  }) async {
    await _ensureInitialized(hotwords: hotwords);
    final recognizer = _recognizer!;

    final wave = _parseWav(wavBytes);
    final stream = recognizer.createStream();
    try {
      var samples = wave.samples;
      final denoiser = _denoiser;
      if (denoiser != null && samples.isNotEmpty) {
        final denoised = denoiser.run(samples: samples, sampleRate: wave.sampleRate);
        if (denoised.samples.isNotEmpty) samples = denoised.samples;
      }
      stream.acceptWaveform(samples: samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  Future<void> _ensureInitialized({required List<String> hotwords}) async {
    if (_initializing) {
      if (_pendingInit != null) {
        await _pendingInit;
      }
      return;
    }
    if (_recognizer != null && _signatureFor(hotwords) == _recognizerHotwordsSignature) {
      return;
    }
    _initializing = true;
    try {
      _pendingInit = _init(hotwords: hotwords);
      await _pendingInit;
    } finally {
      _initializing = false;
      _pendingInit = null;
    }
  }

  Future<void> _init({required List<String> hotwords}) async {
    initBindings();
    final dir = await _modelDir();
    final encoderPath = '${dir.path}/$_encoderFile';
    final decoderPath = '${dir.path}/$_decoderFile';
    final joinerPath = '${dir.path}/$_joinerFile';
    final tokensPath = '${dir.path}/$_tokensFile';
    final bpeVocabPath = '${dir.path}/$_bpeVocabFile';
    for (final p in [encoderPath, decoderPath, joinerPath, tokensPath, bpeVocabPath]) {
      if (!await File(p).exists()) {
        throw LocalAsrNotInstalledException();
      }
    }
    _recognizer?.free();

    final words = <String>{
      ...hotwords,
      '兆帕',
      '个压',
      '气瓶',
      '空气呼吸器',
      '进场',
      '出来',
      '退场',
    }.toList();
    final hotwordsPath = '${dir.path}/$_hotwordsFile';
    await File(hotwordsPath).writeAsString('${words.join('\n')}\n');

    final config = OfflineRecognizerConfig(
      model: OfflineModelConfig(
        transducer: OfflineTransducerModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          joiner: joinerPath,
        ),
        tokens: tokensPath,
        numThreads: 2,
        modelingUnit: 'bbpe',
        bpeVocab: bpeVocabPath,
      ),
      decodingMethod: 'modified_beam_search',
      maxActivePaths: 4,
      hotwordsFile: hotwordsPath,
      // 热词加权：1.5 偏弱，同音竞争时名单姓名常被默认词压过（如 陆河圣→路和胜），
      // 提到 4.0 让名单/术语在 modified_beam_search 中显著占优
      hotwordsScore: 4.0,
    );
    _recognizer = OfflineRecognizer(config);
    _recognizerHotwordsSignature = _signatureFor(hotwords);
    await _ensureDenoiser();
  }

  /// 加载降噪模型（DPDFNet）：模型缺失/加载失败时静默跳过（降噪是增强项，不影响识别）
  Future<void> _ensureDenoiser() async {
    _denoiser?.free();
    _denoiser = null;
    try {
      final dir = await _denoiserDir();
      final model = '${dir.path}/$_denoiserFile';
      if (!await File(model).exists()) return;
      _denoiser = OfflineSpeechDenoiser(
        OfflineSpeechDenoiserConfig(
          model: OfflineSpeechDenoiserModelConfig(
            dpdfnet: OfflineSpeechDenoiserDpdfNetModelConfig(model: model),
            numThreads: 2,
          ),
        ),
      );
    } catch (_) {
      // 降噪器加载失败静默
    }
  }

  String _signatureFor(List<String> hotwords) => hotwords.join('|');
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
