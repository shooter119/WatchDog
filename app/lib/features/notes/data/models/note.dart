import 'note_category.dart';

/// 火场随手记条目：语音/手动记录的时间节点，供复盘
class Note {
  final String id;
  final String text;
  final String category;

  /// 发布者真实姓名（实名认证设置）；空 = 匿名
  final String author;
  final int createdAt;
  final int updatedAt;

  const Note({
    required this.id,
    required this.text,
    required this.category,
    this.author = '',
    required this.createdAt,
    required this.updatedAt,
  });

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    text: (json['text'] as String?) ?? '',
    category: (json['category'] as String?) ?? NoteCategory.other,
    author: (json['author'] as String?) ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
  );
}
