import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

import '../models/models.dart';

/// 辅助页的本机对话记录，不属于警情档案，也不上传服务器。
class ChatHistory {
  ChatHistory._();

  static const _key = 'assistant_chat_history_v1';
  static String _storageKey(String scope) => scope.isEmpty
      ? _key
      : 'assistant_chat_history_v2_${sha256.convert(utf8.encode(scope))}';
  static const maxMessages = 100;
  static Future<void> _mutationQueue = Future<void>.value();

  static Future<List<ChatMessage>> load({String scope = ''}) async {
    await _mutationQueue;
    return _loadRaw(scope);
  }

  static Future<List<ChatMessage>> _loadRaw(String scope) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_storageKey(scope));
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((item) => ChatMessage.fromJson(Map<String, dynamic>.from(item)))
          .where((message) => message.content.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _mutationQueue.then((_) => operation());
    // 某次本地 I/O 失败不能毒化后续清空/追加操作的队列。
    _mutationQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  static Future<void> _saveRaw(List<ChatMessage> messages, String scope) async {
    final kept = messages.length <= maxMessages
        ? messages
        : messages.sublist(messages.length - maxMessages);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _storageKey(scope),
      jsonEncode(kept.map((message) => message.toJson()).toList()),
    );
  }

  static Future<void> save(List<ChatMessage> messages, {String scope = ''}) =>
      _enqueue(() => _saveRaw(messages, scope));

  static Future<void> appendExchange({
    required String question,
    required String reply,
    required int createdAt,
    String scope = '',
  }) async {
    if (question.trim().isEmpty || reply.trim().isEmpty) return;
    await _enqueue(() async {
      final messages = await _loadRaw(scope);
      messages.addAll([
        ChatMessage(
          id: 'local-user-$createdAt',
          role: 'user',
          content: question.trim(),
          createdAt: createdAt,
        ),
        ChatMessage(
          id: 'local-assistant-$createdAt',
          role: 'assistant',
          content: reply.trim(),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      await _saveRaw(messages, scope);
    });
  }

  static Future<void> clear({String scope = ''}) => _enqueue(() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_storageKey(scope));
  });
}
