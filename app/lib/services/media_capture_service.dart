import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../state/app_controller.dart';
import 'camera_bridge.dart';
import 'local_media_store.dart';

/// 把刚拍摄的媒体登记到本机媒体库，并派生可分析的数据。
///
/// 约束：视频本身不上传；只从视频里抽出 16k WAV（本机识别）与少量关键帧，
/// 需要分析时再把文字与关键帧交给后端。
class MediaCaptureService {
  /// 登记一张照片。照片不需要转写，直接入库。
  static Future<LocalMedia> registerPhoto({
    required String incidentId,
    required String path,
    String sourcePath = '',
    required WatermarkPayload watermark,
    required LocationFix? fix,
  }) async {
    final media = LocalMedia(
      id: LocalMediaStore.newId(),
      incidentId: incidentId,
      kind: 'photo',
      path: path,
      sourcePath: sourcePath,
      durationMs: 0,
      capturedAt: watermark.timestampMs == 0
          ? DateTime.now().millisecondsSinceEpoch
          : watermark.timestampMs,
      lat: fix?.lat,
      lon: fix?.lon,
      address: watermark.address,
      weather: watermark.weather,
      transcript: '',
      segments: const [],
      frames: const [],
      observationId: '',
    );
    await LocalMediaStore.instance.insert(media);
    return media;
  }

  /// 登记一段视频，并在后台派生转写与关键帧。
  static Future<LocalMedia> registerVideo({
    required String incidentId,
    required String path,
    String sourcePath = '',
    required int durationMs,
    required WatermarkPayload watermark,
    required LocationFix? fix,
  }) async {
    final media = LocalMedia(
      id: LocalMediaStore.newId(),
      incidentId: incidentId,
      kind: 'video',
      path: path,
      sourcePath: sourcePath,
      durationMs: durationMs,
      capturedAt: watermark.timestampMs == 0
          ? DateTime.now().millisecondsSinceEpoch
          : watermark.timestampMs,
      lat: fix?.lat,
      lon: fix?.lon,
      address: watermark.address,
      weather: watermark.weather,
      transcript: '',
      segments: const [],
      frames: const [],
      observationId: '',
    );
    await LocalMediaStore.instance.insert(media);
    return media;
  }

  /// 抽取音轨 → 本地识别 → 抽帧。任一步失败都不抛出，返回尽可能完整的结果。
  ///
  /// [onProgress] 用于界面上给出「正在识别…」的具体阶段，避免用户以为卡死。
  /// [onError] 在识别失败时给出可展示的原因，界面据此提供「重试识别」；
  /// [isCancelled] 在阶段之间检查，用户取消后不再写回识别结果。
  static Future<LocalMedia> derive(
    LocalMedia media, {
    required AppController controller,
    void Function(String stage)? onProgress,
    void Function(String message)? onError,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;
    if (!media.isVideo) return media;
    if (!File(media.path).existsSync()) {
      onError?.call('找不到视频文件，无法识别口述内容');
      return media;
    }

    var transcript = media.transcript;
    var segments = media.segments;
    var frames = media.frames;
    try {
      onProgress?.call('正在提取音轨');
      final wavPath = await CameraBridge.extractAudioWav(media.path);
      if (cancelled()) return media;

      if (wavPath != null && File(wavPath).existsSync()) {
        onProgress?.call('正在识别口述内容');
        try {
          final bytes = await File(wavPath).readAsBytes();
          final result = await controller.transcribeMediaAudio(bytes);
          if (result.text.trim().isNotEmpty) {
            transcript = result.text.trim();
            segments = result.segments;
          }
        } catch (_) {
          // 本地模型未安装或识别失败时保留已有转写，用户仍可手动补写或重试
          onError?.call('本地语音识别失败，可重试识别或手动补写口述');
        } finally {
          // WAV 只是中间产物，识别完即删，避免占空间
          try {
            await File(wavPath).delete();
          } catch (_) {}
        }
      } else {
        onError?.call('无法提取视频音轨，可重试识别或手动补写口述');
      }
      if (cancelled()) return media;

      onProgress?.call('正在提取关键画面');
      frames = await CameraBridge.extractFrames(media.path, count: 3);
    } catch (error) {
      onError?.call('识别失败：$error');
    }
    if (cancelled()) return media;

    await LocalMediaStore.instance.updateDerived(
      id: media.id,
      transcript: transcript,
      segments: segments,
      frames: frames,
    );
    final updated = await LocalMediaStore.instance.byId(media.id);
    return updated ?? media;
  }

  /// 统计超期文件数量（默认 30 天），用于清理前的二次确认。
  static Future<int> countExpired({int days = LocalMediaStore.retentionDays}) =>
      LocalMediaStore.instance.countExpired(days: days);

  /// 清理过期媒体（默认 30 天），返回被删除的文件路径。
  static Future<int> purgeExpired({
    int days = LocalMediaStore.retentionDays,
  }) async {
    final paths = await LocalMediaStore.instance.purgeExpired(days: days);
    for (final path in paths) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (_) {
        // 文件被其他应用占用时忽略，下次再清
      }
    }
    return paths.length;
  }

  /// 补登记孤儿文件。
  ///
  /// 录像结束的那一瞬间如果界面被关闭、进程被回收或订阅已取消，原生侧仍会把文件
  /// 写完，但 Dart 收不到 stopped 事件，数据库里就没有这条记录 —— 用户会「拍了却找不到」。
  /// 启动时扫一遍拍摄目录，把数据库里不存在的文件补登记为未关联记录，至少可见可分享。
  static Future<int> recoverOrphanedFiles() async {
    if (!Platform.isAndroid) return 0;
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return 0;
      final dir = Directory(p.join(base.path, 'capture'));
      if (!dir.existsSync()) return 0;

      final known = await LocalMediaStore.instance.allPaths();
      final files = dir.listSync().whereType<File>().toList(growable: false);
      final byName = <String, File>{
        for (final file in files) p.basename(file.path): file,
      };
      var recovered = 0;
      for (final entity in files) {
        final name = p.basename(entity.path);
        final lower = name.toLowerCase();
        if (lower.endsWith('.part')) {
          try {
            await entity.delete();
          } catch (_) {
            // 被占用时留给下一次启动继续清理。
          }
          continue;
        }
        final isPhoto = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
        final isVideo = lower.endsWith('.mp4');
        if (!isPhoto && !isVideo) continue;

        final stem = p.basenameWithoutExtension(name);
        final isWatermarked = stem.endsWith('_WM');
        final isNewSource = stem.startsWith('SRC_');
        // 未完成的母版没有可展示的带水印成片，不能伪装成正常资料。
        if (isNewSource) continue;
        if (known.contains(entity.path)) continue;

        String sourcePath = '';
        if (isWatermarked) {
          final sourceStem = 'SRC_${stem.substring(0, stem.length - 3)}';
          final source = byName['$sourceStem${p.extension(name)}'];
          if (source != null) sourcePath = source.path;
        }

        // 文件名形如 IMG_20261018_161039_160.jpg，时间可直接从名字复原
        final stamp =
            _timestampFromName(name) ??
            entity.statSync().modified.millisecondsSinceEpoch;
        await LocalMediaStore.instance.insertRecovered(
          LocalMedia(
            id: LocalMediaStore.newId(),
            incidentId: '',
            kind: isVideo ? 'video' : 'photo',
            path: entity.path,
            sourcePath: sourcePath,
            durationMs: 0,
            capturedAt: stamp,
            lat: null,
            lon: null,
            address: '',
            weather: '',
            transcript: '',
            segments: const [],
            frames: const [],
            observationId: '',
          ),
        );
        known.add(entity.path);
        if (sourcePath.isNotEmpty) known.add(sourcePath);
        recovered++;
      }

      // 生成水印失败的母版没有可展示成片；若本次启动也没有可配对成片，
      // 就作为未完成临时文件清理，避免隐藏视频永久占用空间。
      for (final entity in files) {
        final name = p.basename(entity.path);
        final stem = p.basenameWithoutExtension(name);
        if (!stem.startsWith('SRC_') || known.contains(entity.path)) continue;
        final cleanStem = stem.substring('SRC_'.length);
        final watermarked = byName['${cleanStem}_WM${p.extension(name)}'];
        if (watermarked != null && watermarked.existsSync()) continue;
        try {
          await entity.delete();
        } catch (_) {
          // 下次启动重试。
        }
      }
      return recovered;
    } catch (_) {
      return 0;
    }
  }

  static int? _timestampFromName(String name) {
    final match = RegExp(r'_(\d{8})_(\d{6})_').firstMatch(name);
    if (match == null) return null;
    final date = match.group(1)!;
    final time = match.group(2)!;
    try {
      return DateTime(
        int.parse(date.substring(0, 4)),
        int.parse(date.substring(4, 6)),
        int.parse(date.substring(6, 8)),
        int.parse(time.substring(0, 2)),
        int.parse(time.substring(2, 4)),
        int.parse(time.substring(4, 6)),
      ).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }
}
