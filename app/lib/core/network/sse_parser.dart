import 'dart:convert';

/// SSE 事件：增量内容 / 错误 / 结束
class SseEvent {
  final String? content;
  final String? error;
  final bool done;

  const SseEvent.content(String this.content) : error = null, done = false;
  const SseEvent.error(String this.error) : content = null, done = false;
  const SseEvent.done() : content = null, error = null, done = true;
}

/// SSE 行解析：缓冲跨 chunk 的半行，产出完整事件（协议：`data: {...}` 行 + [DONE]）
class SseLineParser {
  String _buf = '';
  final List<SseEvent> _events = [];

  List<SseEvent> push(String chunk) {
    _events.clear();
    _buf += chunk;
    var idx = -1;
    while ((idx = _buf.indexOf('\n')) >= 0) {
      final line = _buf.substring(0, idx);
      _buf = _buf.substring(idx + 1);
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final data = trimmed.substring(5).trim();
      if (data == '[DONE]') {
        _events.add(const SseEvent.done());
        continue;
      }
      try {
        final m = jsonDecode(data) as Map<String, dynamic>;
        final error = m['error'] as String?;
        if (error != null) {
          _events.add(SseEvent.error(error));
        } else {
          final content = m['content'] as String?;
          if (content != null) _events.add(SseEvent.content(content));
        }
      } catch (_) {
        // 忽略无法解析的行（服务端可能发送 keep-alive）
      }
    }
    return _events;
  }
}
