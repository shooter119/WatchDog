import '../../../core/network/network.dart';
import 'models/video_resource.dart';

class VideoRepository {
  final ApiHttpTransport _transport;

  const VideoRepository(this._transport);

  Future<Map<String, dynamic>> videoResourceAccess() =>
      _transport.requestJsonMap('/api/video-resources/access');

  Future<List<VideoResource>> fetchVideoResources({
    bool includeInactive = false,
  }) async {
    final data = await _transport.requestJsonMap(
      '/api/video-resources${includeInactive ? '?include_inactive=1' : ''}',
    );
    return (data['resources'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => VideoResource.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<VideoResource> addVideoResource({
    required String name,
    required String streamUrl,
    String description = '',
    bool active = true,
  }) async {
    final data = await _transport.requestJsonMap(
      '/api/video-resources',
      method: 'POST',
      body: {
        'name': name.trim(),
        'stream_url': streamUrl.trim(),
        'description': description.trim(),
        'active': active,
      },
    );
    return VideoResource.fromJson(data);
  }

  Future<VideoResource> updateVideoResource(
    String id, {
    required int expectedVersion,
    String? name,
    String? streamUrl,
    String? description,
    bool? active,
  }) async {
    final data = await _transport.requestJsonMap(
      '/api/video-resources/${Uri.encodeComponent(id)}',
      method: 'PATCH',
      body: {
        'expected_version': expectedVersion,
        if (name != null) 'name': name.trim(),
        if (streamUrl != null) 'stream_url': streamUrl.trim(),
        if (description != null) 'description': description.trim(),
        if (active != null) 'active': active,
      },
    );
    return VideoResource.fromJson(data);
  }
}
