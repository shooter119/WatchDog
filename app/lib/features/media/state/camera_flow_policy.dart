import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../services/camera_bridge.dart';
import '../../../services/local_media_store.dart';
import '../../../services/media_capture_service.dart';
import '../../../services/screen_on.dart';
import '../../../services/settings.dart';
import '../../../services/storage_service.dart';
import '../../../services/watermark_settings.dart';
import '../data/models/weather_info.dart';
import 'media_gateway.dart';

/// 拍摄前时效、存储阈值与真实时间差计算规则（独立可单测）。
class CameraFlowPolicy {
  static bool locationExpired(
    LocationFix? fix,
    DateTime? received,
    DateTime now,
  ) =>
      fix == null ||
      received == null ||
      fix.ageMs + now.difference(received).inMilliseconds > 300000;

  static int minimumBytes(bool video) => (video ? 200 : 20) * 1024 * 1024;

  static Duration elapsed(DateTime started, DateTime now) =>
      now.isBefore(started) ? Duration.zero : now.difference(started);

  static String formatTimer(Duration elapsed) {
    final total = elapsed.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static List<DeviceOrientation> preferredOrientationsFor(
    CameraCaptureOrientation orientation,
  ) => switch (orientation) {
    CameraCaptureOrientation.landscape => const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ],
    CameraCaptureOrientation.portrait => const [DeviceOrientation.portraitUp],
  };

  static String outcomeStatusText(MediaReviewOutcome outcome) => switch (outcome) {
    MediaReviewOutcome.saved => '已保存带水印版和无水印版到手机相册',
    MediaReviewOutcome.savedWatermarkedOnly => '旧资料仅保存了带水印版',
    MediaReviewOutcome.shared => '两份已保存，分享菜单已关闭',
    MediaReviewOutcome.sharedWatermarkedOnly => '旧资料已保存带水印版，分享菜单已关闭',
  };

  static String? storageErrorFor(int? availableBytes, {required bool video}) {
    if (availableBytes == null) return '无法检查存储空间，请重试后拍摄';
    if (availableBytes < minimumBytes(video)) {
      return '存储空间不足，请清理至少 ${video ? 200 : 20} MB 后重试';
    }
    return null;
  }
}

/// 显式拍摄模式：拍照 / 录像分离，避免厚手套误触长按。
enum CameraCaptureMode { photo, video }

/// 水印成片生成失败时暂存的母版上下文，支持原路径重试或显式放弃。
@immutable
class PendingMediaRender {
  const PendingMediaRender({
    required this.video,
    required this.sourcePath,
    required this.watermark,
    required this.fix,
    this.durationMs = 0,
    this.review = true,
  });

  final bool video;
  final String sourcePath;
  final WatermarkPayload watermark;
  final LocationFix? fix;
  final int durationMs;
  final bool review;
}

enum PendingRenderChoice { retry, discard }

typedef CameraReviewOpener = Future<MediaReviewOutcome?> Function(
  LocalMedia media, {
  required bool deriving,
});

/// 读取水印配置并回落到单位名称，生成基础 [WatermarkPayload]。
Future<WatermarkPayload> loadCameraBaseWatermark() async {
  final config = await WatermarkSettings.load();
  final unitName = await Settings.unitName;
  return WatermarkPayload(
    unitTitle: config.unitTitle.isNotEmpty ? config.unitTitle : unitName,
    department: config.department,
    actorName: config.actorName,
    showTime: config.showTime,
    showWeather: config.showWeather,
    showLocation: config.showLocation,
    showCoordinates: config.showCoordinates,
    showLogo: config.showLogo,
    timestampMs: DateTime.now().millisecondsSinceEpoch,
  );
}

/// 拉取最新定位（过滤超 5 分钟旧定位）与地址天气，组装刷新后的水印载荷。
Future<({LocationFix? fix, DateTime received, WatermarkPayload watermark})>
resolveCameraLocationWatermark({
  required bool hasLocationPermission,
  required WatermarkPayload current,
  required MediaGateway gateway,
}) async {
  var fix = hasLocationPermission ? await CameraBridge.currentLocation() : null;
  final received = DateTime.now();
  if (fix != null && fix.ageMs > 300000) fix = null;

  WeatherInfo weather = WeatherInfo.empty;
  final fetcher = gateway.fetchWeather;
  if (fix != null && fetcher != null) {
    weather = await fetcher(lat: fix.lat, lon: fix.lon);
  }
  final updated = WatermarkPayload(
    unitTitle: current.unitTitle,
    department: current.department,
    actorName: current.actorName,
    timestampMs: current.timestampMs,
    showTime: current.showTime,
    showWeather: current.showWeather,
    showLocation: current.showLocation,
    showCoordinates: current.showCoordinates,
    showLogo: current.showLogo,
    address: weather.address?.isNotEmpty == true ? weather.address! : '',
    weather: weather.line ?? '',
    latitude: fix?.lat,
    longitude: fix?.lon,
  );
  return (fix: fix, received: received, watermark: updated);
}

/// 检查本机剩余空间是否满足拍摄需求；返回 null 表示可用，否则返回错误提示。
Future<String?> checkCameraStorageError({required bool video}) async {
  final bytes = await StorageService.availableBytes();
  return CameraFlowPolicy.storageErrorFor(bytes, video: video);
}

/// 将水印成片与无水印母版登记到本机媒体库。
Future<LocalMedia> registerRenderedMedia({
  required PendingMediaRender pending,
  required String watermarkedPath,
  required String incidentId,
}) {
  if (pending.video) {
    return MediaCaptureService.registerVideo(
      incidentId: incidentId,
      path: watermarkedPath,
      sourcePath: pending.sourcePath,
      durationMs: pending.durationMs,
      watermark: pending.watermark,
      fix: pending.fix,
    );
  }
  return MediaCaptureService.registerPhoto(
    incidentId: incidentId,
    path: watermarkedPath,
    sourcePath: pending.sourcePath,
    watermark: pending.watermark,
    fix: pending.fix,
  );
}

/// 锁定相机方向。
void lockCameraOrientation(CameraCaptureOrientation orientation) {
  unawaited(
    SystemChrome.setPreferredOrientations(
      CameraFlowPolicy.preferredOrientationsFor(orientation),
    ),
  );
}

/// 在屏幕常亮保护下调用原生水印合成通道。
Future<String?> renderWatermarkedWithWakeLock({
  required PendingMediaRender pending,
  required String taskId,
}) async {
  await ScreenOn.setKeepScreenOn(true);
  final watermarked = await CameraBridge.renderWatermarkedCopy(
    sourcePath: pending.sourcePath,
    watermark: pending.watermark,
    taskId: taskId,
  );
  await ScreenOn.setKeepScreenOn(false);
  return watermarked;
}
