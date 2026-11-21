import 'dart:convert';

import '../../../core/network/network.dart';
import 'models/note.dart';

class NotesRepository {
  final ApiHttpTransport _transport;

  const NotesRepository(this._transport);

  Future<List<Note>> fetchNotes() async {
    final res = await _transport.client
        .get(_transport.uri('/api/notes'), headers: _transport.headers)
        .timeout(const Duration(seconds: 10));
    final body = _transport.decodeJson(res, fallback: '获取日志失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '获取日志失败');
    }
    if (body is! List) {
      throw _transport.responseShapeException(res, '日志响应格式异常');
    }
    final list = body;
    return list.map((e) => Note.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Note> createNote({
    required String text,
    String? category,
    String? opId,
    String? author,
  }) async {
    final res = await _transport.client
        .post(
          _transport.uri('/api/notes'),
          headers: _transport.opHeaders(opId),
          body: jsonEncode({
            'text': text,
            if (category != null) 'category': category,
            // 实名作者：随请求直接提交（本地实名，不依赖服务器 user_settings 同步时序/场景匹配）
            if (author != null && author.isNotEmpty) 'author': author,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '记录日志失败');
    if (res.statusCode != 201) {
      throw _transport.apiException(res, body: body, fallback: '记录日志失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '日志响应格式异常');
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<Note> updateNote({
    required String id,
    String? text,
    String? category,
  }) async {
    final res = await _transport.client
        .patch(
          _transport.uri('/api/notes/$id'),
          headers: _transport.headers,
          body: jsonEncode({
            if (text != null) 'text': text,
            if (category != null) 'category': category,
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _transport.decodeJson(res, fallback: '编辑日志失败');
    if (res.statusCode != 200) {
      throw _transport.apiException(res, body: body, fallback: '编辑日志失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '日志响应格式异常');
    }
    return Note.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteNote(String id) async {
    final res = await _transport.client
        .delete(_transport.uri('/api/notes/$id'), headers: _transport.headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      final body = _transport.decodeJson(res, fallback: '删除日志失败');
      throw _transport.apiException(res, body: body, fallback: '删除日志失败');
    }
  }
}
