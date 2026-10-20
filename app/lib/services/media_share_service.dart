import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

/// 统一媒体分享入口，便于组件测试精确断言分享文件与顺序。
class MediaShareService {
  MediaShareService._();

  @visibleForTesting
  static Future<ShareResult> Function(ShareParams params)? overrideShare;

  static Future<ShareResult> shareWatermarked(String path) {
    final params = ShareParams(files: [XFile(path)]);
    final override = overrideShare;
    if (override != null) return override(params);
    return SharePlus.instance.share(params);
  }
}
