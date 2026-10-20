/// 仅保存服务端已发布快照；正文和附件不写入本地持久缓存。
class KeySiteSummary {
  final String id, name, shortName, address, district, type;
  final int version, publishedAt;
  const KeySiteSummary({
    required this.id,
    required this.name,
    required this.address,
    this.shortName = '',
    this.district = '',
    this.type = '',
    required this.version,
    this.publishedAt = 0,
  });
  factory KeySiteSummary.fromJson(Map<String, dynamic> json) => KeySiteSummary(
    id: json['id'].toString(),
    name: json['name']?.toString() ?? '',
    shortName: json['short_name']?.toString() ?? '',
    address: json['address']?.toString() ?? '',
    district: json['district']?.toString() ?? '',
    type: json['site_type']?.toString() ?? '',
    version: (json['published_version'] as num?)?.toInt() ?? 0,
    publishedAt: (json['published_at'] as num?)?.toInt() ?? 0,
  );
}

class KeySiteSource {
  final String attachmentId;
  final int page;
  final String paragraph;
  const KeySiteSource({
    required this.attachmentId,
    required this.page,
    this.paragraph = '',
  });
  factory KeySiteSource.fromJson(Map<String, dynamic> json) => KeySiteSource(
    attachmentId: json['attachmentId'].toString(),
    page: (json['page'] as num?)?.toInt() ?? 1,
    paragraph: json['paragraph']?.toString() ?? '',
  );
}

class KeySiteEntry {
  final String title, body;
  final Map<String, String> fields;
  final List<KeySiteSource> sources;
  const KeySiteEntry({
    required this.title,
    this.body = '',
    this.fields = const {},
    this.sources = const [],
  });
  factory KeySiteEntry.fromJson(Map<String, dynamic> json) => KeySiteEntry(
    title: json['title']?.toString() ?? '',
    body: json['body']?.toString() ?? '',
    fields: (json['fields'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
    ),
    sources: (json['sources'] as List? ?? [])
        .map((s) => KeySiteSource.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
  );
}

class KeySiteVersion {
  final String siteId;
  final int version, latestVersion, publishedAt;
  final bool active;
  final Map<String, dynamic> profile;
  final Map<String, List<KeySiteEntry>> content;
  final List<Map<String, dynamic>> attachments;
  const KeySiteVersion({
    required this.siteId,
    required this.version,
    required this.latestVersion,
    required this.publishedAt,
    required this.active,
    required this.profile,
    required this.content,
    required this.attachments,
  });
  String get name => profile['name']?.toString() ?? '';
  String get address => profile['address']?.toString() ?? '';
  factory KeySiteVersion.fromJson(Map<String, dynamic> json) => KeySiteVersion(
    siteId: json['site_id'].toString(),
    version: (json['version'] as num).toInt(),
    latestVersion: (json['latestVersion'] as num).toInt(),
    publishedAt: (json['published_at'] as num).toInt(),
    active: json['active'] == true,
    profile: Map<String, dynamic>.from(json['profile'] as Map),
    content: (json['content'] as Map).map(
      (key, entries) => MapEntry(
        key.toString(),
        (entries as List)
            .map(
              (entry) => KeySiteEntry.fromJson(
                Map<String, dynamic>.from(entry as Map),
              ),
            )
            .toList(),
      ),
    ),
    attachments: (json['attachments'] as List? ?? [])
        .map((a) => Map<String, dynamic>.from(a as Map))
        .toList(),
  );
}

class IncidentKeySiteLink {
  final String siteId, name, address, linkedBy, linkedByName;
  final int version, linkedAt;
  const IncidentKeySiteLink({
    required this.siteId,
    required this.name,
    required this.address,
    required this.version,
    required this.linkedBy,
    required this.linkedByName,
    required this.linkedAt,
  });
  factory IncidentKeySiteLink.fromJson(Map<String, dynamic> json) =>
      IncidentKeySiteLink(
        siteId: json['siteId'].toString(),
        name: json['name']?.toString() ?? '',
        address: json['address']?.toString() ?? '',
        version: (json['version'] as num).toInt(),
        linkedBy: json['linkedBy']?.toString() ?? '',
        linkedByName: json['linkedByName']?.toString() ?? '',
        linkedAt: (json['linkedAt'] as num?)?.toInt() ?? 0,
      );
}
