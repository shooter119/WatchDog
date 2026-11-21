class Firefighter {
  final String id;
  final String name;
  final String source;
  final String? createdByMemberId;
  Firefighter({
    required this.id,
    required this.name,
    this.source = 'user',
    this.createdByMemberId,
  });
  factory Firefighter.fromJson(Map<String, dynamic> json) => Firefighter(
    id: json['id'] as String,
    name: json['name'] as String,
    source: (json['source'] as String?) ?? 'user',
    createdByMemberId: json['created_by_member_id'] as String?,
  );
}
