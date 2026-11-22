import 'package:flutter/foundation.dart';

/// 火场日志媒体附件上传状态。
enum NoteMediaUploadStatus {
  /// 已上传至服务端并与日志条目落库关联。
  synced,

  /// 正在本机持久队列等待联网上传。
  queued,

  /// 正在上传中。
  uploading,

  /// 永久失败或重试超限，等待用户手动重试或放弃。
  failed,
}

/// 火场日志照片或视频附件元数据。
@immutable
class NoteMediaAttachment {
  const NoteMediaAttachment({
    required this.id,
    required this.kind,
    this.mime = '',
    this.sizeBytes = 0,
    this.durationMs = 0,
    this.width = 0,
    this.height = 0,
    this.capturedAt = 0,
    this.address = '',
    this.weather = '',
    this.available = true,
    this.purgedAt,
    this.fileUrl = '',
    this.thumbUrl = '',
    this.localPath = '',
    this.localThumbPath = '',
    this.uploadStatus = NoteMediaUploadStatus.synced,
    this.uploadError = '',
    this.queueTaskId = '',
  });

  final String id;
  final String kind; // photo | video
  final String mime;
  final int sizeBytes;
  final int durationMs;
  final int width;
  final int height;
  final int capturedAt;
  final String address;
  final String weather;
  final bool available;
  final int? purgedAt;
  final String fileUrl;
  final String thumbUrl;
  final String localPath;
  final String localThumbPath;
  final NoteMediaUploadStatus uploadStatus;
  final String uploadError;
  final String queueTaskId;

  bool get isVideo => kind == 'video';
  bool get isPhoto => kind == 'photo';
  bool get isPendingUpload => uploadStatus != NoteMediaUploadStatus.synced;

  String get formattedDuration {
    if (!isVideo) return '';
    final totalSec = (durationMs / 1000).round().clamp(0, 3600);
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  factory NoteMediaAttachment.fromJson(Map<String, dynamic> json) {
    return NoteMediaAttachment(
      id: json['id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'photo',
      mime: json['mime']?.toString() ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      capturedAt: (json['captured_at'] as num?)?.toInt() ?? 0,
      address: json['address']?.toString() ?? '',
      weather: json['weather']?.toString() ?? '',
      available: json['available'] is bool ? json['available'] as bool : true,
      purgedAt: (json['purged_at'] as num?)?.toInt(),
      fileUrl: json['file_url']?.toString() ?? '',
      thumbUrl: json['thumb_url']?.toString() ?? '',
    );
  }
}
