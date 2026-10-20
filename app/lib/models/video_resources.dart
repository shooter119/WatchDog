class VideoResource {
  final String id;
  final String name;
  final String streamUrl;
  final String description;
  final bool active;
  final int sortOrder;
  final int version;
  final int updatedAt;

  const VideoResource({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.description = '',
    this.active = true,
    this.sortOrder = 0,
    this.version = 1,
    this.updatedAt = 0,
  });

  factory VideoResource.fromJson(Map<String, dynamic> json) => VideoResource(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    streamUrl: json['stream_url']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    active: json['active'] != false,
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    version: (json['version'] as num?)?.toInt() ?? 1,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
  );
}
