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
    sortOrder: _integer(json['sort_order'], 0),
    version: _integer(json['version'], 1),
    // PostgreSQL returns BIGINT values through pg as strings.
    updatedAt: _integer(json['updated_at'], 0),
  );

  static int _integer(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
