class Hotword {
  final String id;
  final String word;
  final String source;
  final String? createdByMemberId;
  Hotword({
    required this.id,
    required this.word,
    this.source = 'user',
    this.createdByMemberId,
  });
  factory Hotword.fromJson(Map<String, dynamic> json) => Hotword(
    id: json['id'] as String,
    word: json['word'] as String,
    source: (json['source'] as String?) ?? 'user',
    createdByMemberId: json['created_by_member_id'] as String?,
  );
}
