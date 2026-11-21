import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../services/camera_bridge.dart';
import '../../../services/local_asr_service.dart';
import '../../../services/local_media_store.dart';
import '../data/models/weather_info.dart';

/// 媒体核对页返回结果，用于在取景页展示非遮挡状态提示。
enum MediaReviewOutcome {
  saved,
  savedWatermarkedOnly,
  shared,
  sharedWatermarkedOnly,
}

/// 媒体域可见的当前警情轻量快照，避免跨 Feature 直接依赖 `incident` 模型或旧 `AppController`。
@immutable
class MediaIncidentRef {
  const MediaIncidentRef({
    required this.id,
    this.number = '',
    this.title = '',
  });

  final String id;
  final String number;
  final String title;

  String get displayName {
    final trimmed = title.trim();
    return trimmed.isNotEmpty ? trimmed : number;
  }
}

typedef MediaDeriveCallback = Future<LocalMedia> Function(
  LocalMedia media, {
  void Function(String stage)? onProgress,
  void Function(String message)? onError,
  bool Function()? isCancelled,
});

typedef MediaObservationSubmitter = Future<void> Function({
  required String incidentId,
  required String transcript,
  required String sourceType,
  required int capturedAt,
  required String mediaRef,
});

/// 水印相机 / 现场资料 / 媒体核对域的外部能力网关（零 `AppController` / 其他 Feature 耦合）。
class MediaGateway {
  const MediaGateway({
    required this.readCurrentIncident,
    this.fetchWeather,
    this.isObservationApiAvailable,
    this.createIncidentObservation,
    this.refreshIncidentData,
    this.deriveMedia,
    this.transcribeMediaAudio,
    this.isAsrCloudEnabled,
  });

  /// 动态读取当前警情；用于严格防串警情写入守卫与取景页警情标签。
  final MediaIncidentRef? Function() readCurrentIncident;

  /// 查询经纬度对应的地址与天气；为空时降级为 [WeatherInfo.empty]。
  final Future<WeatherInfo> Function({
    required double lat,
    required double lon,
  })?
  fetchWeather;

  /// 服务端写入接口是否已连接可用。
  final bool Function()? isObservationApiAvailable;

  /// 将核对后的口述写入指定警情。
  final MediaObservationSubmitter? createIncidentObservation;

  /// 写入成功后刷新当前警情数据。
  final Future<void> Function(String incidentId)? refreshIncidentData;

  /// 自定义派生流水线（外壳可注入冻结的 `MediaCaptureService.derive`）。
  final MediaDeriveCallback? deriveMedia;

  /// 无自定义派生流水线时使用的离线/联网语音转写函数。
  final Future<LocalAsrResult> Function(Uint8List wavBytes)?
  transcribeMediaAudio;

  /// 当前是否启用云端语音识别（仅用于阶段文案提示）。
  final bool Function()? isAsrCloudEnabled;

  bool get canSubmitObservation =>
      createIncidentObservation != null &&
      (isObservationApiAvailable?.call() ?? true);
}

/// 执行视频音轨提取、本地/联网口述识别与关键帧抽取。
///
/// 若 [MediaGateway.deriveMedia] 已注入则直接委派（保留对冻结服务的直连能力）；
/// 否则按同等步骤调用冻结的 [CameraBridge] 与 [LocalMediaStore]。
Future<LocalMedia> runMediaDerive(
  LocalMedia media, {
  required MediaGateway gateway,
  void Function(String stage)? onProgress,
  void Function(String message)? onError,
  bool Function()? isCancelled,
}) async {
  final delegated = gateway.deriveMedia;
  if (delegated != null) {
    return delegated(
      media,
      onProgress: onProgress,
      onError: onError,
      isCancelled: isCancelled,
    );
  }

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
      final cloud = gateway.isAsrCloudEnabled?.call() ?? false;
      onProgress?.call(cloud ? '正在联网识别口述内容' : '正在本地识别口述内容');
      try {
        final bytes = await File(wavPath).readAsBytes();
        final transcriber = gateway.transcribeMediaAudio;
        if (transcriber == null) {
          onError?.call('语音识别失败，请检查网络或本地模型后重试，也可手动补写口述');
        } else {
          final result = await transcriber(bytes);
          if (result.text.trim().isNotEmpty) {
            transcript = result.text.trim();
            segments = result.segments;
          }
        }
      } catch (_) {
        onError?.call('语音识别失败，请检查网络或本地模型后重试，也可手动补写口述');
      } finally {
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
