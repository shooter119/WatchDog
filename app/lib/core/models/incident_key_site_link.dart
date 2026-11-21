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
