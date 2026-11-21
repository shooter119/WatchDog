/// 智能体问答消息（user 提问 / assistant 回复）
class ChatMessage {
  final String id;
  final String role; // user / assistant
  final String content;
  final int createdAt;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'created_at': createdAt,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    role: (json['role'] as String?) ?? 'user',
    content: (json['content'] as String?) ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
  );
}
