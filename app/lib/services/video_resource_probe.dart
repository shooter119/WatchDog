import 'dart:async';
import 'dart:io';

import '../models/video_resources.dart';

typedef VideoResourceAvailabilityChecker =
    Future<bool> Function(VideoResource resource);

class VideoResourceProbe {
  // The Commander gateway may spend about 15 seconds inviting the upstream
  // device. A shorter timeout marked otherwise reachable resources red.
  static const timeout = Duration(seconds: 20);

  /// Availability means the authorized stream endpoint answered successfully.
  /// It does not replace the real video-surface acceptance on a phone.
  static Future<bool> check(VideoResource resource) async {
    final uri = Uri.tryParse(resource.streamUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return false;
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 2);
    try {
      final request = await client.headUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final headResponse = await request.close().timeout(timeout);
      final headReachable = _isReachable(headResponse.statusCode);
      await _consumeResponse(headResponse);
      if (headReachable) return true;

      // Some FLV gateways reject HEAD even though the stream itself is live.
      // Try GET and stop after the response headers arrive.
      final get = await client.getUrl(uri).timeout(timeout);
      get.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await get.close().timeout(timeout);
      final reachable = _isReachable(response.statusCode);
      await _consumeResponse(response);
      return reachable;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static bool _isReachable(int statusCode) =>
      statusCode >= 200 && statusCode < 400;

  static Future<void> _consumeResponse(HttpClientResponse response) async {
    final subscription = response.listen((_) {});
    await subscription.cancel();
  }
}
