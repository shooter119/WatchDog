import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'screen_on.dart';

/// 水印内容：拍摄开始时组装一次，原生侧在录制期间冻结不再变更。
///
/// 单位抬头与拍摄部门来自「水印设置」，与登录身份解耦：
/// 换班组、临时支援时改设置即可，不必重新认证。
class WatermarkPayload {
  final String unitTitle;
  final String department;
  final String actorName;
  final String address;
  final String weather;
  final double? latitude;
  final double? longitude;
  final int timestampMs;
  final bool showTime;
  final bool showWeather;
  final bool showLocation;
  final bool showCoordinates;
  final bool showLogo;

  const WatermarkPayload({
    this.unitTitle = '',
    this.department = '',
    this.actorName = '',
    this.address = '',
    this.weather = '',
    this.latitude,
    this.longitude,
    this.timestampMs = 0,
    this.showTime = true,
    this.showWeather = true,
    this.showLocation = true,
    this.showCoordinates = true,
    this.showLogo = true,
  });

  WatermarkPayload copyWith({
    String? unitTitle,
    String? department,
    String? actorName,
    String? address,
    String? weather,
    double? latitude,
    double? longitude,
    int? timestampMs,
    bool? showTime,
    bool? showWeather,
    bool? showLocation,
    bool? showCoordinates,
    bool? showLogo,
  }) {
    return WatermarkPayload(
      unitTitle: unitTitle ?? this.unitTitle,
      department: department ?? this.department,
      actorName: actorName ?? this.actorName,
      address: address ?? this.address,
      weather: weather ?? this.weather,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      timestampMs: timestampMs ?? this.timestampMs,
      showTime: showTime ?? this.showTime,
      showWeather: showWeather ?? this.showWeather,
      showLocation: showLocation ?? this.showLocation,
      showCoordinates: showCoordinates ?? this.showCoordinates,
      showLogo: showLogo ?? this.showLogo,
    );
  }

  Map<String, Object?> toMap() => {
    'unitTitle': unitTitle,
    'department': department,
    'actorName': actorName,
    'address': address,
    'weather': weather,
    'latitude': latitude,
    'longitude': longitude,
    'timestampMs': timestampMs == 0
        ? DateTime.now().millisecondsSinceEpoch
        : timestampMs,
    'showTime': showTime,
    'showWeather': showWeather,
    'showLocation': showLocation,
    'showCoordinates': showCoordinates,
    'showLogo': showLogo,
  };
}

/// 录制事件：原生侧通过 EventChannel 推回的开始/结束/到达上限/错误。
class CameraRecordEvent {
  final String type;
  final String? path;
  final int? durationMs;
  final String? taskId;
  final double? progress;
  final bool autoStopped;
  final String? code;
  final String? message;

  const CameraRecordEvent({
    required this.type,
    this.path,
    this.durationMs,
    this.taskId,
    this.progress,
    this.autoStopped = false,
    this.code,
    this.message,
  });

  factory CameraRecordEvent.fromMap(Map<Object?, Object?> map) {
    return CameraRecordEvent(
      type: (map['type'] as String?) ?? 'unknown',
      path: map['path'] as String?,
      durationMs: (map['durationMs'] as num?)?.toInt(),
      taskId: map['taskId'] as String?,
      progress: (map['progress'] as num?)?.toDouble(),
      autoStopped: map['autoStopped'] == true,
      code: map['code']?.toString(),
      message: map['message'] as String?,
    );
  }
}

/// 定位结果（Android 系统 LocationManager，不依赖 Google Play Services）。
class LocationFix {
  final double lat;
  final double lon;
  final double accuracyMeters;
  final String provider;
  final int ageMs;

  const LocationFix({
    required this.lat,
    required this.lon,
    required this.accuracyMeters,
    required this.provider,
    required this.ageMs,
  });

  static LocationFix? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lon = (raw['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return LocationFix(
      lat: lat,
      lon: lon,
      accuracyMeters: (raw['accuracy'] as num?)?.toDouble() ?? -1,
      provider: (raw['provider'] as String?) ?? 'unknown',
      ageMs: (raw['ageMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 水印相机原生能力入口。
///
/// 平台限制：仅 Android 提供实现；其他平台所有方法返回 null / false，
/// 调用方据此隐藏入口，避免出现「点了没反应」的按钮。
class CameraBridge {
  static const MethodChannel _channel = MethodChannel('watchdog/camera');
  static const MethodChannel _locationChannel = MethodChannel(
    'watchdog/location',
  );
  static const MethodChannel _mediaChannel = MethodChannel('watchdog/media');
  static const EventChannel _events = EventChannel('watchdog/camera_events');

  /// 单段视频上限：60 秒（产品约定），与原生侧默认值保持一致。
  static const Duration maxRecordingDuration = Duration(seconds: 60);
  static const String viewType = 'watchdog/camera_view';

  /// 用 [defaultTargetPlatform] 而非 dart:io 判断，便于测试覆盖非 Android 分支；
  /// 生产环境两者在 Android 上等价，Web 端始终视为不支持。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Stream<CameraRecordEvent>? _eventStream;

  /// 录制事件流；订阅前不会丢事件，因为原生侧只在有 sink 时发送。
  static Stream<CameraRecordEvent> get events {
    _eventStream ??= _events
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map(
          (event) => CameraRecordEvent.fromMap(event as Map<Object?, Object?>),
        );
    return _eventStream!;
  }

  /// 运行时权限状态。相机为必需项，麦克风与定位为增强项。
  static Future<CameraPermissionState> requestPermissions() async {
    if (!isSupported) return CameraPermissionState.denied;
    try {
      final raw = await _channel.invokeMethod<Object?>('requestPermissions');
      return CameraPermissionState.fromMap(raw);
    } catch (_) {
      return CameraPermissionState.denied;
    }
  }

  static Future<CameraPermissionState> permissionState() async {
    if (!isSupported) return CameraPermissionState.denied;
    try {
      final raw = await _channel.invokeMethod<Object?>('permissionState');
      return CameraPermissionState.fromMap(raw);
    } catch (_) {
      return CameraPermissionState.denied;
    }
  }

  static Future<void> openSystemSettings() async {
    await ScreenOn.openAppSettings();
  }

  static Future<String?> takePhoto() {
    return _channel.invokeMethod<String>('takePhoto');
  }

  /// 从无水印母版生成带水印成片。视频进度通过 [events] 的
  /// `watermark_progress` 事件返回，并用 [taskId] 隔离旧任务。
  static Future<String?> renderWatermarkedCopy({
    required String sourcePath,
    required WatermarkPayload watermark,
    required String taskId,
  }) async {
    try {
      return await _mediaChannel.invokeMethod<String>('renderWatermarkedCopy', {
        'path': sourcePath,
        'taskId': taskId,
        'watermark': watermark.toMap(),
      });
    } catch (_) {
      return null;
    }
  }

  static Future<void> startRecording() async {
    await _channel.invokeMethod<void>('startRecording');
  }

  static Future<void> stopRecording() async {
    await _channel.invokeMethod<void>('stopRecording');
  }

  static Future<void> switchCamera() async {
    await _channel.invokeMethod<void>('switchCamera');
  }

  static Future<void> setTorch(bool on) async {
    await _channel.invokeMethod<void>('setTorch', {'on': on});
  }

  static Future<void> updateWatermark(WatermarkPayload payload) async {
    await _channel.invokeMethod<void>('updateWatermark', payload.toMap());
  }

  static Future<void> setMaxDuration(Duration duration) async {
    await _channel.invokeMethod<void>('setMaxDuration', {
      'maxDurationMs': duration.inMilliseconds,
    });
  }

  static Future<bool> isRecording() async {
    return await _channel.invokeMethod<bool>('isRecording') ?? false;
  }

  // ---- 视频派生数据（全部本机处理，视频不出设备）----

  /// 抽取音轨并转为 16k 单声道 WAV，供本地 ASR 使用。失败返回 null。
  static Future<String?> extractAudioWav(String videoPath) async {
    try {
      return await _mediaChannel.invokeMethod<String>('extractAudioWav', {
        'path': videoPath,
      });
    } catch (_) {
      return null;
    }
  }

  /// 均匀抽帧，返回 JPEG 路径列表；数量默认 3，最多 6。
  static Future<List<String>> extractFrames(
    String videoPath, {
    int count = 3,
  }) async {
    try {
      final result = await _mediaChannel.invokeMethod<List<Object?>>(
        'extractFrames',
        {'path': videoPath, 'count': count},
      );
      return result?.whereType<String>().toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// 用系统默认应用打开（播放/查看），文件通过 FileProvider 临时授权。
  ///
  /// 没有可处理的应用或原生通道不可用时返回 false，调用方可以提示改用分享。
  static Future<bool> openWithSystem(String path) async {
    try {
      await _mediaChannel.invokeMethod<void>('openWithSystem', {'path': path});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 把本机拍摄文件复制到系统相册（同一文件重复保存会复用原相册项）。
  ///
  /// 成功返回相册 Uri；权限被拒或系统相册不可写时返回 null，由界面提示改用分享。
  static Future<String?> saveToGallery(String path) async {
    try {
      return await _mediaChannel.invokeMethod<String>('saveToGallery', {
        'path': path,
      });
    } catch (_) {
      return null;
    }
  }

  /// 成对保存带水印版与无水印母版。任一份失败时原生侧回滚本次写入。
  static Future<List<String>?> savePairToGallery({
    required String watermarkedPath,
    required String sourcePath,
  }) async {
    try {
      final raw = await _mediaChannel.invokeMethod<List<Object?>>(
        'savePairToGallery',
        {
          'watermarkedPath': watermarkedPath,
          'sourcePath': sourcePath,
        },
      );
      final uris = raw?.whereType<String>().toList(growable: false) ?? const [];
      return uris.length == 2 ? uris : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteLocalFile(String path) async {
    if (path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败不阻断已完成保存；下次过期清理会继续处理。
    }
  }

  // ---- 定位 ----

  static Future<bool> hasLocationPermission() async {
    if (!isSupported) return false;
    try {
      return await _locationChannel.invokeMethod<bool>('hasPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 获取一次定位；无权限或超时返回 null，由调用方降级为「位置未获取」。
  static Future<LocationFix?> currentLocation({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!isSupported) return null;
    try {
      final raw = await _locationChannel.invokeMethod<Object?>('getLocation', {
        'timeoutMs': timeout.inMilliseconds,
      });
      return LocationFix.fromMap(raw);
    } catch (_) {
      return null;
    }
  }
}

/// 相机相关运行时权限状态。
class CameraPermissionState {
  final bool camera;
  final bool microphone;
  final bool location;
  final bool preciseLocation;

  const CameraPermissionState({
    required this.camera,
    required this.microphone,
    required this.location,
    required this.preciseLocation,
  });

  static const CameraPermissionState denied = CameraPermissionState(
    camera: false,
    microphone: false,
    location: false,
    preciseLocation: false,
  );

  static CameraPermissionState fromMap(Object? raw) {
    if (raw is! Map) return denied;
    bool flag(String key) => raw[key] == true;
    return CameraPermissionState(
      camera: flag('camera'),
      microphone: flag('microphone'),
      location: flag('location'),
      preciseLocation: flag('preciseLocation'),
    );
  }
}
