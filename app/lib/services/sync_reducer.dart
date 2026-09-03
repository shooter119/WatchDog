import '../models/models.dart';

class SyncEvent {
  final String stream;
  final String sequence;
  final String eventId;
  final String eventType;
  final String? incidentId;
  final String? aggregateId;
  final String? clientOpId;
  final int occurredAt;
  final Map<String, dynamic> payload;

  const SyncEvent({
    required this.stream,
    required this.sequence,
    required this.eventId,
    required this.eventType,
    this.incidentId,
    this.aggregateId,
    this.clientOpId,
    required this.occurredAt,
    required this.payload,
  });

  factory SyncEvent.fromJson(Map<String, dynamic> json) => SyncEvent(
    stream: json['stream']?.toString() ?? 'incident',
    sequence: json['sequence']?.toString() ?? '0',
    eventId: json['event_id']?.toString() ?? '',
    eventType: json['event_type']?.toString() ?? '',
    incidentId: json['incident_id']?.toString(),
    aggregateId: json['aggregate_id']?.toString(),
    clientOpId: json['client_op_id']?.toString(),
    occurredAt: int.tryParse(json['occurred_at']?.toString() ?? '') ?? 0,
    payload: json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : <String, dynamic>{},
  );
}

/// 事件去重与游标连续性检查。实体投影由 AppController 应用到现有页面模型，
/// 这里集中维护协议层的两个关键不变量。
class SyncReducer {
  final Set<String> _eventIds = <String>{};

  bool accept(SyncEvent event, {String? expectedCursor}) {
    if (event.eventId.isNotEmpty && _eventIds.contains(event.eventId)) return false;
    if (expectedCursor == null || expectedCursor.isEmpty) return true;
    final expected = BigInt.tryParse(expectedCursor);
    final actual = BigInt.tryParse(event.sequence);
    final continuous = expected == null || actual == null || actual == expected + BigInt.one;
    if (continuous && event.eventId.isNotEmpty) _eventIds.add(event.eventId);
    return continuous;
  }

  void clear() => _eventIds.clear();

  static bool isRosterEvent(String type) => type.startsWith('roster.');

  static List<Firefighter> rosterNames(Map<String, dynamic> snapshot) =>
      (snapshot['firefighters'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Firefighter.fromJson(Map<String, dynamic>.from(item)))
          .toList();

  static List<Hotword> rosterHotwords(Map<String, dynamic> snapshot) =>
      (snapshot['hotwords'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Hotword.fromJson(Map<String, dynamic>.from(item)))
          .toList();
}
