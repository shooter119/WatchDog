import '../../../../core/models/incident_key_site_link.dart';

class Incident {
  final IncidentKeySiteLink? keySiteLink;
  final int keySiteLinkRevision;
  final String id;
  final Map<String, dynamic> info;
  final String number;
  final String? title;
  final String? suggestedTitle;
  final String status;
  final int createdAt;
  final int lastActivityAt;
  final int? archivedAt;
  final String? archivedBy;
  final bool autoArchived;
  final int unresolvedActiveCount;
  final int version;
  final int forceStationCount;
  final int vehicleCount;
  final int personnelCount;
  final int unknownVehicleStationCount;
  final int unknownPersonnelStationCount;

  const Incident({
    this.keySiteLink,
    this.keySiteLinkRevision = 0,
    required this.id,
    this.info = const {},
    required this.number,
    this.title,
    this.suggestedTitle,
    required this.status,
    required this.createdAt,
    required this.lastActivityAt,
    this.archivedAt,
    this.archivedBy,
    this.autoArchived = false,
    this.unresolvedActiveCount = 0,
    this.version = 1,
    this.forceStationCount = 0,
    this.vehicleCount = 0,
    this.personnelCount = 0,
    this.unknownVehicleStationCount = 0,
    this.unknownPersonnelStationCount = 0,
  });

  String get displayName =>
      (title ?? '').trim().isEmpty ? number : title!.trim();
  bool get isActive => status == 'active';

  String get effectiveLocation {
    for (final key in [
      'location',
      'address',
      'location_display',
      'crime_address',
    ]) {
      final val = (info[key]?.toString() ?? '').trim();
      if (val.isNotEmpty && val != '地点待补充' && val != 'null') {
        return val;
      }
    }
    return '';
  }

  factory Incident.fromJson(Map<String, dynamic> json) => Incident(
    keySiteLink: json['key_site_link'] is Map
        ? IncidentKeySiteLink.fromJson(
            Map<String, dynamic>.from(json['key_site_link'] as Map),
          )
        : null,
    keySiteLinkRevision: (json['key_site_link_revision'] as num?)?.toInt() ?? 0,
    id: json['id']?.toString() ?? '',
    info: json['info'] is Map
        ? Map<String, dynamic>.from(json['info'] as Map)
        : const {},
    number: json['number']?.toString() ?? '',
    title: json['title']?.toString(),
    suggestedTitle: json['suggested_title']?.toString(),
    status: json['status']?.toString() ?? 'active',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    lastActivityAt: (json['last_activity_at'] as num?)?.toInt() ?? 0,
    archivedAt: (json['archived_at'] as num?)?.toInt(),
    archivedBy: json['archived_by']?.toString(),
    autoArchived: json['auto_archived'] == true || json['auto_archived'] == 1,
    unresolvedActiveCount:
        (json['unresolved_active_count'] as num?)?.toInt() ?? 0,
    version: (json['version'] as num?)?.toInt() ?? 1,
    forceStationCount: (json['force_station_count'] as num?)?.toInt() ?? 0,
    unknownVehicleStationCount:
        (json['unknown_vehicle_station_count'] as num?)?.toInt() ?? 0,
    unknownPersonnelStationCount:
        (json['unknown_personnel_station_count'] as num?)?.toInt() ?? 0,
    vehicleCount: json['vehicle_count'] as int? ?? 0,
    personnelCount: json['personnel_count'] as int? ?? 0,
  );
}
