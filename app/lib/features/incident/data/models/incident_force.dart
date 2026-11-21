class IncidentForce {
  final String id;
  final String incidentId;
  final String? stationId;
  final String? unitStationId;
  final String? deploymentStatus;
  final String? informationSource;
  final String stationName;
  final int vehicleCount;
  final int personnelCount;
  final bool vehicleCountKnown;
  final bool personnelCountKnown;
  final int createdAt;
  final int updatedAt;
  final int version;

  const IncidentForce({
    required this.id,
    required this.incidentId,
    this.stationId,
    this.unitStationId,
    this.deploymentStatus,
    this.informationSource,
    required this.stationName,
    required this.vehicleCount,
    required this.personnelCount,
    this.vehicleCountKnown = true,
    this.personnelCountKnown = true,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
  });

  String get vehicleLabel => vehicleCountKnown ? '$vehicleCount车' : '车辆待补充';
  String get personnelLabel =>
      personnelCountKnown ? '$personnelCount人' : '人数待补充';
  String get quantityLabel => vehicleCountKnown && personnelCountKnown
      ? '$vehicleLabel$personnelLabel'
      : '$vehicleLabel $personnelLabel';

  factory IncidentForce.fromJson(Map<String, dynamic> json) => IncidentForce(
    id: json['id']?.toString() ?? '',
    incidentId: json['incident_id']?.toString() ?? '',
    stationId: json['station_id']?.toString(),
    unitStationId: json['unit_station_id']?.toString(),
    deploymentStatus: json['deployment_status']?.toString(),
    informationSource: json['information_source']?.toString(),
    vehicleCountKnown:
        json['vehicle_count_known'] != false &&
        json['vehicle_count_known'] != 0,
    personnelCountKnown:
        json['personnel_count_known'] != false &&
        json['personnel_count_known'] != 0,
    stationName: json['station_name']?.toString() ?? '',
    vehicleCount: (json['vehicle_count'] as num?)?.toInt() ?? 0,
    personnelCount: (json['personnel_count'] as num?)?.toInt() ?? 0,
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    version: (json['version'] as num?)?.toInt() ?? 1,
  );
}
