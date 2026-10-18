import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 水印内容：拍摄开始时组装一次，原生侧在录制期间冻结不再变更。
class WatermarkPayload {
  final String unitName;
  final String incidentName;
  final String address;
  final String weather;
  final String actorName;
  final int timestampMs;

  const WatermarkPayload({
    this.unitName = '',
    this.incidentName = '',
    this.address = '',
    this.weather = '',
    this.actorName = '',
    this.timestampMs = 0,
  });

  WatermarkPayload copyWith({
    String? unitName,
    String? incidentName,
    String? address,
    String? weather,
    String? actorName,
    int? timestampMs,
  }) {
    return WatermarkPayload(
      unitName: unitName ?? this.unitName,
      incidentName: incidentName ?? this.incidentName,
      address: address ?? this.address,
      weather: weather ?? this.weather,
      actorName: actorName ?? this.actorName,
      timestampMs: timestampMs ?? this.timestampMs,
    );
  }

  Map<String, Object?> toMap() => {
        'unitName': unitName,
        'incidentName': incidentName,
        'address': address,
        'weather': weather,
        'actorName': actorName,
        'timestampMs': timestampMs == 0
            ? DateTime.now().millisecondsSinceEpoch
            : timestampMs,
      };
}

/// 录制事件：原生侧通过 EventChannel 推回的开始/结束/到达上限/错误。
class CameraRecordEvent {
  final String type;
  final String? path;
  final int? durationMs;
  final bool autoStopped;
  final String? code;
  final String? message;

  const CameraRecordEvent({
    required this.type,
    this.path,
    this.durationMs,
    this.autoStopped = false,
    this.code,
    this.message,
  });

  factory CameraRecordEvent.fromMap(Map<Object?, Object?> map) {
    return CameraRecordEvent(
      type: (map['type'] as String?) ?? 'unknown',
      path: map['path'] as String?,
      durationMs: (map['durationMs'] as num?)?.toInt(),
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
  static const MethodChannel _locationChannel =
      MethodChannel('watchdog/location');
  static const MethodChannel _mediaChannel = MethodChannel('watchdog/media');
  static const EventChannel _events = EventChannel('watchdog/camera_events');

  /// 单段视频上限：60 秒（产品约定），与原生侧默认值保持一致。
  static const Duration maxRecordingDuration = Duration(seconds: 60);
  static const String viewType = 'watchdog/camera_view';

  static bool get isSupported => Platform.isAndroid;

  static Stream<CameraRecordEvent>? _eventStream;

  /// 录制事件流；订阅前不会丢事件，因为原生侧只在有 sink 时发送。
  static Stream<CameraRecordEvent> get events {
    _eventStream ??= _events
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => CameraRecordEvent.fromMap(event as Map<Object?, Object?>));
    return _eventStream!;
  }

  static Future<String?> takePhoto() {
    return _channel.invokeMethod<String>('takePhoto');
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
    await _channel.invokeMethod<void>(
      'setMaxDuration',
      {'maxDurationMs': duration.inMilliseconds},
    );
  }

  static Future<bool> isRecording() async {
    return await _channel.invokeMethod<bool>('isRecording') ?? false;
  }

  // ---- 视频派生数据（全部本机处理，视频不出设备）----

  /// 抽取音轨并转为 16k 单声道 WAV，供本地 ASR 使用。失败返回 null。
  static Future<String?> extractAudioWav(String videoPath) async {
    try {
      return await _mediaChannel.invokeMethod<String>(
        'extractAudioWav',
        {'path': videoPath},
      );
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
  static Future<void> openWithSystem(String path) async {
    await _mediaChannel.invokeMethod<void>('openWithSystem', {'path': path});
  }

  // ---- 定位 ----

  static Future<bool> hasLocationPermission() async {
    if (!isSupported) return false;
    try {
      return await _locationChannel.invokeMethod<bool>('hasPermission') ?? false;
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
      final raw = await _locationChannel.invokeMethod<Object?>(
        'getLocation',
        {'timeoutMs': timeout.inMilliseconds},
      );
      return LocationFix.fromMap(raw);
    } catch (_) {
      return null;
    }
  }
}
