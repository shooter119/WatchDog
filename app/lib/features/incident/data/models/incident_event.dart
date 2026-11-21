class IncidentEvent {
  final String id;
  final String incidentId;
  final String type;
  final int occurredAt;
  final int recordedAt;
  final String? actorName;
  final String source;
  final String? clientOpId;
  final Map<String, dynamic> payload;
  final String? revisionOf;
  final String text;

  const IncidentEvent({
    required this.id,
    required this.incidentId,
    required this.type,
    required this.occurredAt,
    required this.recordedAt,
    this.actorName,
    required this.source,
    this.clientOpId,
    this.payload = const {},
    this.revisionOf,
    required this.text,
  });

  factory IncidentEvent.fromJson(Map<String, dynamic> json) => IncidentEvent(
    id: json['id']?.toString() ?? '',
    incidentId: json['incident_id']?.toString() ?? '',
    type: json['type']?.toString() ?? '',
    occurredAt: (json['occurred_at'] as num?)?.toInt() ?? 0,
    recordedAt: (json['recorded_at'] as num?)?.toInt() ?? 0,
    actorName: json['actor_name']?.toString(),
    source: json['source']?.toString() ?? 'online',
    clientOpId: json['client_op_id']?.toString(),
    payload: json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : const {},
    revisionOf: json['revision_of']?.toString(),
    text: json['text']?.toString() ?? '',
  );
}
