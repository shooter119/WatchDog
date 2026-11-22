import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

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

  /// 上传带水印照片或视频，与文字/语音转文字合并生成一条火场日志。
  Future<Note> uploadNoteMedia({
    required String kind,
    required String filePath,
    String? thumbPath,
    String text = '',
    String? category,
    String? author,
    int durationMs = 0,
    int capturedAt = 0,
    String address = '',
    String weather = '',
    String mediaRef = '',
    bool syncObservation = false,
    String? opId,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _transport.uri('/api/notes/media'),
    );
    final reqHeaders = Map<String, String>.from(_transport.opHeaders(opId))
      ..remove('Content-Type');
    request.headers.addAll(reqHeaders);

    request.fields['kind'] = kind;
    request.fields['text'] = text;
    if (category != null && category.isNotEmpty) {
      request.fields['category'] = category;
    }
    if (author != null && author.isNotEmpty) {
      request.fields['author'] = author;
    }
    request.fields['duration_ms'] = '$durationMs';
    request.fields['captured_at'] = '$capturedAt';
    if (address.isNotEmpty) request.fields['address'] = address;
    if (weather.isNotEmpty) request.fields['weather'] = weather;
    if (mediaRef.isNotEmpty) request.fields['media_ref'] = mediaRef;
    if (syncObservation) request.fields['sync_observation'] = '1';

    final MediaType mediaType = kind == 'video'
        ? (filePath.toLowerCase().endsWith('.webm')
              ? MediaType('video', 'webm')
              : MediaType('video', 'mp4'))
        : (filePath.toLowerCase().endsWith('.png')
              ? MediaType('image', 'png')
              : MediaType('image', 'jpeg'));
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        filePath,
        contentType: mediaType,
      ),
    );
    if (thumbPath != null &&
        thumbPath.isNotEmpty &&
        File(thumbPath).existsSync()) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'thumb',
          thumbPath,
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    }

    final stream = await _transport.client
        .send(request)
        .timeout(const Duration(seconds: 120));
    final res = await http.Response.fromStream(
      stream,
    ).timeout(const Duration(seconds: 120));
    final body = _transport.decodeJson(res, fallback: '上传火场媒体失败');
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw _transport.apiException(res, body: body, fallback: '上传火场媒体失败');
    }
    if (body is! Map) {
      throw _transport.responseShapeException(res, '火场媒体响应格式异常');
    }
    return Note.fromJson(Map<String, dynamic>.from(body));
  }

  /// 将后端相对路径（如 `/api/note-media/<id>/file`）解析为完整请求地址。
  String mediaUrl(String relativePath) {
    final trimmed = relativePath.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final normalized = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return _transport.uri(normalized).toString();
  }

  /// 读取带认证信息的媒体请求头（供图片预览与视频播放器传入 HTTP headers）。
  Map<String, String> mediaAuthHeaders() {
    final copy = Map<String, String>.from(_transport.headers);
    copy.remove('Content-Type');
    return copy;
  }
}
