import 'note_category.dart';
import 'note_media.dart';

/// 火场随手记条目：语音/手动/水印相机拍摄记录的时间节点，供复盘
class Note {
  final String id;
  final String text;
  final String category;

  /// 发布者真实姓名（实名认证设置）；空 = 匿名
  final String author;
  final int createdAt;
  final int updatedAt;
  final List<NoteMediaAttachment> media;

  const Note({
    required this.id,
    required this.text,
    required this.category,
    this.author = '',
    required this.createdAt,
    required this.updatedAt,
    this.media = const <NoteMediaAttachment>[],
  });

  bool get hasMedia => media.isNotEmpty;
  bool get hasPendingMediaUpload => media.any((m) => m.isPendingUpload);

  Note copyWith({
    String? id,
    String? text,
    String? category,
    String? author,
    int? createdAt,
    int? updatedAt,
    List<NoteMediaAttachment>? media,
  }) => Note(
    id: id ?? this.id,
    text: text ?? this.text,
    category: category ?? this.category,
    author: author ?? this.author,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    media: media ?? this.media,
  );

  factory Note.fromJson(Map<String, dynamic> json) {
    final rawMedia = json['media'];
    final attachments = rawMedia is List
        ? rawMedia
              .whereType<Map>()
              .map(
                (item) => NoteMediaAttachment.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .toList(growable: false)
        : const <NoteMediaAttachment>[];
    return Note(
      id: json['id'] as String,
      text: (json['text'] as String?) ?? '',
      category: (json['category'] as String?) ?? NoteCategory.other,
      author: (json['author'] as String?) ?? '',
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      media: attachments,
    );
  }
}
