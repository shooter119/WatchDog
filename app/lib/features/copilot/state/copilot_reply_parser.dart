/// AI 回复正文与追问按钮的拆分结果。
class ChatReplyParts {
  final String body;
  final List<String> followUps;
  final bool isLegacy;

  const ChatReplyParts({
    required this.body,
    required this.followUps,
    this.isLegacy = false,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ChatReplyParts) return false;
    if (other.body != body ||
        other.isLegacy != isLegacy ||
        other.followUps.length != followUps.length) {
      return false;
    }
    for (var i = 0; i < followUps.length; i++) {
      if (other.followUps[i] != followUps[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(body, isLegacy, Object.hashAll(followUps));
}

final RegExp _ltTailRe = RegExp(r'<+[^<\n]*$');
final RegExp _whitespaceRe = RegExp(r'\s+');
final RegExp _legacyTailRe = RegExp(
  r'(?:^|\n)\s*\*{0,2}(?:关|关键|追|关键追|追问|关键追问)\*{0,2}[：:]?\s*$',
);
final RegExp _followUpsDelimiterRe = RegExp(
  r'<{2,3}\s*FOLLOW_UPS\s*>{2,3}',
  caseSensitive: false,
);
final RegExp _legacyDelimiterRe = RegExp(
  r'\*{0,2}(关键)?\s*追问\*{0,2}\s*[：:]\s*\*{0,2}',
);
final RegExp _lineBreakRe = RegExp(r'\r?\n');
final RegExp _listPrefixRe = RegExp(r'^(?:[-•*]+|\d+[.、）)])\s*');
final RegExp _boldEdgeRe = RegExp(r'^\*{1,2}|\*{1,2}$');
final RegExp _quoteEdgeRe = RegExp(r'^[「『"“”‘’]+|[」』"“”‘’]+$');

/// 流式阶段扣留可能是 `<<<FOLLOW_UPS>>>` 或旧版 `追问：` / `关键追问：` 的不完整尾部前缀，
/// 防止跨分片截断时在气泡中闪现协议标记；普通小于号（如 `<10MPa`）不会被误扣留。
String holdbackStreamingTail(String content) {
  final ltMatch = _ltTailRe.firstMatch(content);
  if (ltMatch != null && content.length - ltMatch.start <= 24) {
    final compact = ltMatch
        .group(0)!
        .replaceAll(_whitespaceRe, '')
        .toUpperCase();
    if ('<<<FOLLOW_UPS>>>'.startsWith(compact) ||
        '<<FOLLOW_UPS>>'.startsWith(compact)) {
      return content.substring(0, ltMatch.start).trimRight();
    }
  }
  final m = _legacyTailRe.firstMatch(content);
  if (m != null) {
    return content.substring(0, m.start).trimRight();
  }
  return content;
}

/// 解析 AI 回复正文与独立追问按钮：
/// 1) 新协议以 `<<<FOLLOW_UPS>>>` 分隔（流式期间彻底隐藏标记及尾部内容，并扣留不完整前缀）；
/// 2) 向下兼容旧版历史中的 `追问：` / `关键追问：` 格式。
ChatReplyParts parseAssistantReply(String content, {bool streaming = false}) {
  final delimiterMatch = _followUpsDelimiterRe.firstMatch(content);
  if (delimiterMatch != null) {
    final rawBody = content.substring(0, delimiterMatch.start);
    final body = streaming ? rawBody.trimRight() : rawBody.trim();
    if (streaming) {
      return ChatReplyParts(body: body, followUps: const [], isLegacy: false);
    }
    final seen = <String>{};
    final followUps = <String>[];
    final rest = content.substring(delimiterMatch.end);
    for (final rawLine in rest.split(_lineBreakRe)) {
      var q = rawLine.trim();
      q = q.replaceFirst(_listPrefixRe, '').trim();
      q = q
          .replaceAll(_boldEdgeRe, '')
          .replaceAll(_quoteEdgeRe, '')
          .trim();
      if (q.isEmpty || q.length > 40 || !seen.add(q)) continue;
      followUps.add(q);
      if (followUps.length >= 3) break;
    }
    return ChatReplyParts(body: body, followUps: followUps, isLegacy: false);
  }

  final matches = _legacyDelimiterRe.allMatches(content).toList();
  if (matches.isNotEmpty) {
    final m = matches.last;
    final rawBody = content.substring(0, m.start);
    final body = streaming ? rawBody.trimRight() : rawBody.trim();
    if (streaming) {
      return ChatReplyParts(body: body, followUps: const [], isLegacy: true);
    }
    final rest = content.substring(m.end).trim();
    if (rest.isEmpty) {
      return ChatReplyParts(
        body: content,
        followUps: const [],
        isLegacy: true,
      );
    }
    final seen = <String>{};
    final followUps = <String>[];
    for (final rawLine in rest.split(_lineBreakRe)) {
      var q = rawLine.trim();
      q = q.replaceFirst(_listPrefixRe, '').trim();
      q = q.replaceAll(_boldEdgeRe, '').trim();
      if (q.isEmpty || !seen.add(q)) continue;
      followUps.add(q);
      if (followUps.length >= 3) break;
    }
    if (followUps.isEmpty) {
      return ChatReplyParts(
        body: content,
        followUps: const [],
        isLegacy: true,
      );
    }
    return ChatReplyParts(body: body, followUps: followUps, isLegacy: true);
  }

  if (streaming) {
    return ChatReplyParts(
      body: holdbackStreamingTail(content),
      followUps: const [],
      isLegacy: false,
    );
  }
  return ChatReplyParts(body: content, followUps: const [], isLegacy: false);
}

/// 提取纯净回复正文（用于剪贴板复制，剔除 `<<<FOLLOW_UPS>>>` 与旧版追问标记）。
String extractCleanAssistantBody(String content) =>
    parseAssistantReply(content, streaming: false).body;
