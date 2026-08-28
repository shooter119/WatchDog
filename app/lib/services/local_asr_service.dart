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
  static const _generationDirName = '.generations';
  static const _activePointerName = '.active';
  static const _completeMarkerName = '.complete';
  static const _completeMarkerContents = 'watchdog-asr-collection-v1';
  static const _requiredModelFiles = [
    _encoderFile,
    _decoderFile,
    _joinerFile,
    _tokensFile,
    _bpeVocabFile,
  ];

  /// 语音降噪模型（DPDFNet，9.8MB）：录音 → 降噪 → 识别，火场嘈杂环境提升人名/压力识别率。
  /// 与 ASR 模型同目录下载（denoiser/），缺失时自动跳过降噪（不影响识别主流程）。
  static const _denoiserName = 'denoiser';
  static const _denoiserFile = 'dpdfnet2.onnx';

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
  Future<void>? _pendingInit;
  Future<void>? _downloadFuture;
  Future<void>? _removeFuture;
  Future<void>? _disposeFuture;
  Future<void> _transcriptionQueue = Future<void>.value();
  String? _recognizerGenerationId;
  bool _disposed = false;

  final Future<Directory> Function() _supportDirectoryProvider;
  final http.Client Function() _httpClientFactory;
  final String? _modelBaseUrlOverride;

  LocalAsrService({
    Future<Directory> Function()? supportDirectoryProvider,
    http.Client Function()? httpClientFactory,
    String? modelBaseUrl,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _httpClientFactory = httpClientFactory ?? (() => http.Client()),
       _modelBaseUrlOverride = modelBaseUrl?.trim().replaceFirst(
         RegExp(r'/+$'),
         '',
       );

  /// 模型源优先级：构造时显式传入 > dart-define 独立覆盖 > 当前运行时 API
  /// 地址的 /models。最后一项让设置页切换服务器后模型下载不会打到旧网关。
  Future<String> _resolvedModelBaseUrl() async {
    final explicit = _modelBaseUrlOverride;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final compileTimeOverride = Settings.modelBaseUrlOverride
        .trim()
        .replaceFirst(RegExp(r'/+$'), '');
    if (compileTimeOverride.isNotEmpty) return compileTimeOverride;
    final serverUrl = await Settings.serverUrl;
    return '$serverUrl/models';
  }

  Future<Directory> _modelRoot() async {
    final base = await _supportDirectoryProvider();
    return Directory('${base.path}/asr_models/$modelName');
  }

  Future<Directory> _denoiserRoot() async {
    final base = await _supportDirectoryProvider();
    return Directory('${base.path}/asr_models/$_denoiserName');
  }

  /// 降噪模型是否已安装
  Future<bool> isDenoiserInstalled() async {
    final dir = await _activeGeneration(await _denoiserRoot(), const [
      _denoiserFile,
    ]);
    return dir != null;
  }

  /// 模型是否已安装：只接受 active 指向的、带完成标记的完整集合。
  Future<bool> isModelInstalled() async {
    final dir = await _activeGeneration(
      await _modelRoot(),
      _requiredModelFiles,
    );
    return dir != null;
  }

  /// 下载模型（encoder + decoder + joiner + tokens + bpe.vocab + 降噪模型），带进度回调
  Future<void> downloadModel({
    void Function(int received, int total)? onProgress,
  }) async {
    if (_disposed) throw StateError('本地语音识别服务已释放');
    final modelBaseUrl = await _resolvedModelBaseUrl();
    if (!Settings.isSafeHttpUrl(modelBaseUrl)) {
      throw ArgumentError('本地模型服务器地址必须使用 HTTPS');
    }
    final removing = _removeFuture;
    if (removing != null) await removing;
    final running = _downloadFuture;
    if (running != null) {
      await running;
      return;
    }
    final future = _downloadModelInternal(
      modelBaseUrl: modelBaseUrl,
      onProgress: onProgress,
    );
    _downloadFuture = future;
    try {
      await future;
    } finally {
      if (identical(_downloadFuture, future)) {
        _downloadFuture = null;
      }
    }
  }

  Future<void> _downloadModelInternal({
    required String modelBaseUrl,
    required void Function(int received, int total)? onProgress,
  }) async {
    await _downloadCollection(
      root: await _modelRoot(),
      files: _requiredModelFiles,
      urlFor: (name) => '$modelBaseUrl/$modelName/$name',
      onProgress: onProgress,
    );
    // 降噪模型（DPDFNet）：失败不阻断 ASR 模型下载（降噪只是增强项）
    try {
      await _downloadCollection(
        root: await _denoiserRoot(),
        files: const [_denoiserFile],
        urlFor: (name) => '$modelBaseUrl/$_denoiserName/$name',
        onProgress: onProgress,
      );
    } catch (_) {
      // 降噪模型下载失败静默：识别仍可用，只是少了降噪
    }
    await _cleanupLegacyModels();
  }

  Future<void> _downloadCollection({
    required Directory root,
    required List<String> files,
    required String Function(String name) urlFor,
    required void Function(int received, int total)? onProgress,
  }) async {
    await root.create(recursive: true);
    final generations = Directory('${root.path}/$_generationDirName');
    await generations.create(recursive: true);
    await _cleanupStagingArtifacts(root, generations);
    final generationId = await _newGenerationId(generations);
    final staging = Directory('${generations.path}/.$generationId.staging');
    await staging.create(recursive: true);
    try {
      for (final name in files) {
        await _downloadFile(
          url: urlFor(name),
          path: '${staging.path}/$name',
          onProgress: onProgress,
        );
      }
      if (!await _allFilesPresent(staging, files)) {
        throw StateError('模型集合不完整，已拒绝激活');
      }
      await File(
        '${staging.path}/$_completeMarkerName',
      ).writeAsString(_completeMarkerContents, flush: true);
      if (!await _isCompleteCollection(staging, files)) {
        throw StateError('模型集合完成标记校验失败');
      }
      final committed = Directory('${generations.path}/$generationId');
      await staging.rename(committed.path);
      await _activateGeneration(root, generationId);
    } catch (_) {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _cleanupLegacyModels() async {
    final base = await _supportDirectoryProvider();
    for (final name in _legacyModelDirs) {
      try {
        final dir = Directory('${base.path}/asr_models/$name');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  /// 清理进程被杀后留下的临时集合和 active 指针临时文件。
  /// 不触碰已提交的 generation，避免删除当前识别器仍在使用的模型。
  Future<void> _cleanupStagingArtifacts(
    Directory root,
    Directory generations,
  ) async {
    try {
      if (await generations.exists()) {
        await for (final entity in generations.list(followLinks: false)) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (entity is Directory &&
              name.startsWith('.') &&
              name.endsWith('.staging')) {
            try {
              await entity.delete(recursive: true);
            } catch (_) {}
          }
        }
      }
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (entity is File &&
              (name.startsWith('$_activePointerName.') ||
                  name.startsWith('..$_activePointerName.')) &&
              name.endsWith('.part')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // 清理是恢复性增强，失败不能阻断本次完整集合下载。
    }
  }

  Future<String> _newGenerationId(Directory generations) async {
    var suffix = DateTime.now().microsecondsSinceEpoch;
    while (await Directory('${generations.path}/g-$suffix').exists() ||
        await Directory('${generations.path}/.g-$suffix.staging').exists()) {
      suffix++;
    }
    return 'g-$suffix';
  }

  Future<Directory?> _activeGeneration(
    Directory root,
    List<String> files,
  ) async {
    final generationId = await _activeGenerationId(root, files);
    if (generationId == null) return null;
    final generation = Directory(
      '${root.path}/$_generationDirName/$generationId',
    );
    return generation;
  }

  Future<String?> _activeGenerationId(
    Directory root,
    List<String> files,
  ) async {
    final generationId = await _readActivePointer(root);
    if (generationId == null || !RegExp(r'^g-[0-9]+$').hasMatch(generationId)) {
      return null;
    }
    final generation = Directory(
      '${root.path}/$_generationDirName/$generationId',
    );
    if (!await _isCompleteCollection(generation, files)) return null;
    return generationId;
  }

  Future<String?> _readActivePointer(Directory root) async {
    final pointer = File('${root.path}/$_activePointerName');
    if (!await pointer.exists()) return null;
    try {
      final value = (await pointer.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> _activateGeneration(Directory root, String generationId) async {
    final pointer = File('${root.path}/$_activePointerName');
    final next = File('${root.path}/$_activePointerName.$generationId.part');
    await next.writeAsString('$generationId\n', flush: true);
    try {
      await next.rename(pointer.path);
    } catch (_) {
      try {
        if (await next.exists()) await next.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<bool> _allFilesPresent(Directory dir, List<String> files) async {
    if (!await dir.exists()) return false;
    for (final name in files) {
      final file = File('${dir.path}/$name');
      if (!await file.exists() || await file.length() == 0) return false;
    }
    return true;
  }

  Future<bool> _isCompleteCollection(Directory dir, List<String> files) async {
    if (!await _allFilesPresent(dir, files)) return false;
    final marker = File('${dir.path}/$_completeMarkerName');
    if (!await marker.exists()) return false;
    try {
      return (await marker.readAsString()).trim() == _completeMarkerContents;
    } catch (_) {
      return false;
    }
  }

  Future<void> _downloadFile({
    required String url,
    required String path,
    required void Function(int received, int total)? onProgress,
  }) async {
    final part = '$path.part';
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final client = _httpClientFactory();
        try {
          final request = http.Request('GET', Uri.parse(url));
          final res = await client
              .send(request)
              .timeout(const Duration(seconds: 60));
          if (res.statusCode != 200) {
            lastError = HttpException('HTTP ${res.statusCode}');
            // 客户端错误重试没有意义；5xx 和传输异常仍保留一次恢复机会。
            if (res.statusCode >= 400 && res.statusCode < 500) break;
            continue;
          }
          final total = res.contentLength ?? 0;
          if (total > 160 * 1024 * 1024) {
            throw StateError('模型文件过大，已拒绝下载');
          }
          final file = File(part).openWrite();
          var received = 0;
          try {
            await for (final chunk in res.stream.timeout(
              const Duration(seconds: 60),
            )) {
              file.add(chunk);
              received += chunk.length;
              if (received > 160 * 1024 * 1024) {
                throw StateError('模型文件过大，已拒绝下载');
              }
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
  Future<void> removeModel() {
    if (_disposed) return Future<void>.value();
    final existing = _removeFuture;
    if (existing != null) return existing;
    final future = _removeModelInternal();
    _removeFuture = future;
    future.then<void>(
      (_) {
        if (identical(_removeFuture, future)) _removeFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_removeFuture, future)) _removeFuture = null;
      },
    );
    return future;
  }

  Future<void> _removeModelInternal() async {
    final download = _downloadFuture;
    if (download != null) {
      try {
        await download;
      } catch (_) {
        // 下载失败时仍继续清理，旧 active 集合也应被用户明确删除。
      }
    }
    await _transcriptionQueue;
    _recognizer?.free();
    _recognizer = null;
    _recognizerHotwordsSignature = null;
    _recognizerGenerationId = null;
    _denoiser?.free();
    _denoiser = null;
    final dir = await _modelRoot();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    final ddir = await _denoiserRoot();
    try {
      await ddir.delete(recursive: true);
    } catch (_) {}
  }

  /// 本地识别：wav 字节 → 文本。首次调用会加载模型（约 1-2 秒）。
  /// 降噪模型已安装时先做 DPDFNet 语音增强，再喂识别器（火场嘈杂环境提升人名/压力识别率）。
  Future<String> transcribe(
    Uint8List wavBytes, {
    List<String> hotwords = const [],
  }) {
    if (_disposed) {
      return Future<String>.error(StateError('本地语音识别服务已释放'));
    }
    // OfflineRecognizer 的 native 实例在热词切换时会被替换；串行化整段
    // 识别，避免上一条录音仍在使用 stream 时被下一次初始化释放。
    final future = _transcriptionQueue.then(
      (_) => _transcribeInternal(wavBytes, hotwords: hotwords),
    );
    _transcriptionQueue = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return future;
  }

  Future<String> _transcribeInternal(
    Uint8List wavBytes, {
    required List<String> hotwords,
  }) async {
    if (_disposed) throw StateError('本地语音识别服务已释放');
    await _ensureInitialized(hotwords: hotwords);
    if (_disposed) throw StateError('本地语音识别服务已释放');
    final recognizer = _recognizer!;

    final wave = _parseWav(wavBytes);
    final stream = recognizer.createStream();
    try {
      var samples = wave.samples;
      final denoiser = _denoiser;
      if (denoiser != null && samples.isNotEmpty) {
        final denoised = denoiser.run(
          samples: samples,
          sampleRate: wave.sampleRate,
        );
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
    final signature = _signatureFor(hotwords);
    while (true) {
      final generationId = await _activeModelGenerationId();
      if (_recognizer != null &&
          signature == _recognizerHotwordsSignature &&
          generationId == _recognizerGenerationId) {
        return;
      }
      final pending = _pendingInit;
      if (pending != null) {
        await pending;
        // 等待的是另一组热词或另一代模型，必须重新检查，不能直接复用。
        continue;
      }
      final future = _init(hotwords: hotwords);
      _pendingInit = future;
      try {
        await future;
        return;
      } finally {
        if (identical(_pendingInit, future)) _pendingInit = null;
      }
    }
  }

  Future<String?> _activeModelGenerationId() async =>
      _activeGenerationId(await _modelRoot(), _requiredModelFiles);

  Future<void> _init({required List<String> hotwords}) async {
    initBindings();
    final root = await _modelRoot();
    final generationId = await _activeGenerationId(root, _requiredModelFiles);
    if (generationId == null) {
      throw LocalAsrNotInstalledException();
    }
    final dir = Directory('${root.path}/$_generationDirName/$generationId');
    final encoderPath = '${dir.path}/$_encoderFile';
    final decoderPath = '${dir.path}/$_decoderFile';
    final joinerPath = '${dir.path}/$_joinerFile';
    final tokensPath = '${dir.path}/$_tokensFile';
    final bpeVocabPath = '${dir.path}/$_bpeVocabFile';
    for (final p in [
      encoderPath,
      decoderPath,
      joinerPath,
      tokensPath,
      bpeVocabPath,
    ]) {
      if (!await File(p).exists()) {
        throw LocalAsrNotInstalledException();
      }
    }
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
    final nextRecognizer = OfflineRecognizer(config);
    final previousRecognizer = _recognizer;
    _recognizer = nextRecognizer;
    _recognizerHotwordsSignature = _signatureFor(hotwords);
    _recognizerGenerationId = generationId;
    previousRecognizer?.free();
    await _ensureDenoiser();
  }

  /// 释放 native 识别器；等待当前串行识别完成，避免释放仍在使用的 stream。
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final future = _disposeInternal();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeInternal() async {
    if (_disposed) {
      await _transcriptionQueue;
      return;
    }
    _disposed = true;
    final download = _downloadFuture;
    if (download != null) {
      try {
        await download;
      } catch (_) {
        // 下载失败仍需继续释放识别器和降噪器。
      }
    }
    final pendingInit = _pendingInit;
    if (pendingInit != null) {
      try {
        await pendingInit;
      } catch (_) {
        // 初始化失败不应阻止其余 native 资源释放。
      }
    }
    await _transcriptionQueue;
    _recognizer?.free();
    _recognizer = null;
    _recognizerHotwordsSignature = null;
    _recognizerGenerationId = null;
    _denoiser?.free();
    _denoiser = null;
  }

  /// 加载降噪模型（DPDFNet）：模型缺失/加载失败时静默跳过（降噪是增强项，不影响识别）
  Future<void> _ensureDenoiser() async {
    _denoiser?.free();
    _denoiser = null;
    try {
      final dir = await _activeGeneration(await _denoiserRoot(), const [
        _denoiserFile,
      ]);
      if (dir == null) return;
      final model = '${dir.path}/$_denoiserFile';
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
    final size = ByteData.sublistView(
      bytes,
    ).getUint32(offset + 4, Endian.little);
    if (chunkId == 'fmt ') {
      sampleRate = ByteData.sublistView(
        bytes,
      ).getUint32(offset + 12, Endian.little);
      bitsPerSample = ByteData.sublistView(
        bytes,
      ).getUint16(offset + 22, Endian.little);
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
