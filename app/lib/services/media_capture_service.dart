import 'dart:io';

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
    required WatermarkPayload watermark,
    required LocationFix? fix,
  }) async {
    final media = LocalMedia(
      id: LocalMediaStore.newId(),
      incidentId: incidentId,
      kind: 'photo',
      path: path,
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
    required int durationMs,
    required WatermarkPayload watermark,
    required LocationFix? fix,
  }) async {
    final media = LocalMedia(
      id: LocalMediaStore.newId(),
      incidentId: incidentId,
      kind: 'video',
      path: path,
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
  static Future<LocalMedia> derive(
    LocalMedia media, {
    required AppController controller,
    void Function(String stage)? onProgress,
  }) async {
    if (!media.isVideo || !File(media.path).existsSync()) return media;

    onProgress?.call('正在提取音轨');
    final wavPath = await CameraBridge.extractAudioWav(media.path);
    var transcript = media.transcript;
    var segments = media.segments;

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
        // 本地模型未安装或识别失败时保留空转写，用户仍可手动补写
      } finally {
        // WAV 只是中间产物，识别完即删，避免占空间
        try {
          await File(wavPath).delete();
        } catch (_) {}
      }
    }

    onProgress?.call('正在提取关键画面');
    final frames = await CameraBridge.extractFrames(media.path, count: 3);

    await LocalMediaStore.instance.updateDerived(
      id: media.id,
      transcript: transcript,
      segments: segments,
      frames: frames,
    );
    final updated = await LocalMediaStore.instance.byId(media.id);
    return updated ?? media;
  }

  /// 清理过期媒体（默认 30 天），返回被删除的文件路径。
  static Future<int> purgeExpired({int days = LocalMediaStore.retentionDays}) async {
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
}
