import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const Set<String> _forbiddenDirs = <String>{
  'pages',
  'state',
  'services',
  'api',
  'models',
  'theme',
  'widgets',
};

final RegExp _directivePattern = RegExp(
  r'(?<![A-Za-z0-9_$.])\b(import|export|part(?:\s+of\b)?)\s*(?=")([^;]*);',
);

final RegExp _partOfLibraryNamePattern = RegExp(
  r'(?<![A-Za-z0-9_$.])\bpart\s+of\s+(?!")([^;]+);',
);

final RegExp _legacySymbolPattern = RegExp(
  r'\b(AppColors|AppPalette|AppTextStyles|AppSpacing|AppRadius|AppFonts)\b',
);

class _StringSpan {
  const _StringSpan({
    required this.start,
    required this.end,
    required this.value,
  });

  final int start;
  final int end;
  final String value;
}

class _DartLexResult {
  const _DartLexResult({
    required this.masked,
    required this.stringSpans,
  });

  final String masked;
  final Map<int, _StringSpan> stringSpans;
}

bool _isIdentStartNoDollar(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95;
}

bool _isIdentPart(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      code == 95 ||
      code == 36;
}

bool _isHexDigit(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 70) ||
      (code >= 97 && code <= 102);
}

/// 词法级剥离 Dart 注释与非插值字符串字面量内容，同时保留原始偏移与 `\n` 行号。
///
/// - 注释 (`//...`、嵌套 `/* ... */`) 全部替换为空格（保留 `\n`）。
/// - 不含插值的字符串字面量（含 raw / 三引号）记录解码后的 [_StringSpan] 并在掩码串中
///   替换为等长 `"   "`（保留 `\n`），使内嵌的 `;`、`import`、`AppColors` 不干扰静态扫描。
/// - 含 `${...}` 或 `$ident` 插值的字符串会保留插值表达式代码，递归处理其中的嵌套字符串与注释。
class _DartLexer {
  _DartLexer(this._source);

  final String _source;
  final StringBuffer _out = StringBuffer();
  final Map<int, _StringSpan> _spans = <int, _StringSpan>{};
  int _i = 0;
  int _braceDepth = 0;

  int get _len => _source.length;

  _DartLexResult run() {
    _scanCode();
    return _DartLexResult(
      masked: _out.toString(),
      stringSpans: _spans,
    );
  }

  void _writeMaskedSlice(int start, int end) {
    for (var k = start; k < end; k++) {
      _out.write(_source[k] == '\n' ? '\n' : ' ');
    }
  }

  void _writeQuotedMask(int start, int end) {
    _out.write('"');
    _writeMaskedSlice(start + 1, end - 1);
    _out.write('"');
  }

  void _scanCode({int? stopAtBraceDepth}) {
    while (_i < _len) {
      final c = _source[_i];
      final next = _i + 1 < _len ? _source[_i + 1] : '';

      if (stopAtBraceDepth != null) {
        if (c == '{') {
          _braceDepth++;
          _out.write('{');
          _i++;
          continue;
        }
        if (c == '}') {
          if (_braceDepth == stopAtBraceDepth) {
            _braceDepth--;
            _out.write(' ');
            _i++;
            return;
          }
          _braceDepth--;
          _out.write('}');
          _i++;
          continue;
        }
      }

      // 1. 单行注释（Dart 将 \n 与孤立 \r 均视为行结束符）
      if (c == '/' && next == '/') {
        _out.write('  ');
        _i += 2;
        while (_i < _len && _source[_i] != '\n' && _source[_i] != '\r') {
          _out.write(' ');
          _i++;
        }
        continue;
      }

      // 2. 多行注释（支持 Dart 嵌套 /* ... */）
      if (c == '/' && next == '*') {
        var depth = 1;
        _out.write('  ');
        _i += 2;
        while (_i < _len && depth > 0) {
          if (_source[_i] == '\n') {
            _out.write('\n');
            _i++;
          } else if (_source[_i] == '/' &&
              _i + 1 < _len &&
              _source[_i + 1] == '*') {
            depth++;
            _out.write('  ');
            _i += 2;
          } else if (_source[_i] == '*' &&
              _i + 1 < _len &&
              _source[_i + 1] == '/') {
            depth--;
            _out.write('  ');
            _i += 2;
          } else {
            _out.write(' ');
            _i++;
          }
        }
        continue;
      }

      // 3. Raw 字符串: r'...' / r"..." / r'''...''' / r"""..."""
      if (c == 'r' &&
          (next == "'" || next == '"') &&
          (_i == 0 || !_isIdentPart(_source[_i - 1]))) {
        _scanRawString(next);
        continue;
      }

      // 4. 普通 / 插值字符串: '...' / "..." / '''...''' / """..."""
      if (c == "'" || c == '"') {
        _scanRegularString(c);
        continue;
      }

      _out.write(c);
      _i++;
    }
  }

  void _skipTripleQuoteLeadingNewline() {
    var j = _i;
    while (j < _len && (_source[j] == ' ' || _source[j] == '\t')) {
      j++;
    }
    if (j < _len) {
      if (_source[j] == '\r') {
        _i = (j + 1 < _len && _source[j + 1] == '\n') ? j + 2 : j + 1;
      } else if (_source[j] == '\n') {
        _i = j + 1;
      }
    }
  }

  void _scanRawString(String quote) {
    final start = _i;
    final isTriple =
        _i + 3 < _len && _source[_i + 2] == quote && _source[_i + 3] == quote;
    final endQuote = isTriple ? '$quote$quote$quote' : quote;
    _i += 1 + endQuote.length;
    if (isTriple) {
      _skipTripleQuoteLeadingNewline();
    }

    final content = StringBuffer();
    var closed = false;
    while (_i < _len) {
      if (isTriple) {
        if (_source.startsWith(endQuote, _i)) {
          _i += 3;
          closed = true;
          break;
        }
        content.write(_source[_i]);
        _i++;
      } else {
        if (_source[_i] == quote) {
          _i++;
          closed = true;
          break;
        }
        if (_source[_i] == '\n' || _source[_i] == '\r') {
          break;
        }
        content.write(_source[_i]);
        _i++;
      }
    }

    final end = _i;
    if (closed && end - start >= 2) {
      _spans[start] = _StringSpan(
        start: start,
        end: end,
        value: content.toString(),
      );
      _writeQuotedMask(start, end);
    } else {
      _writeMaskedSlice(start, end);
    }
  }

  void _scanRegularString(String quote) {
    final start = _i;
    final isTriple =
        _i + 2 < _len && _source[_i + 1] == quote && _source[_i + 2] == quote;
    final endQuote = isTriple ? '$quote$quote$quote' : quote;
    _i += endQuote.length;
    if (isTriple) {
      _skipTripleQuoteLeadingNewline();
    }

    final decoded = StringBuffer();
    var hasInterpolation = false;
    var closed = false;

    while (_i < _len) {
      final ch = _source[_i];

      if (ch == r'\' && _i + 1 < _len) {
        final (decodedEscape, consumed) = _decodeEscapeAt(_i);
        if (hasInterpolation) {
          _writeMaskedSlice(_i, _i + consumed);
        } else {
          decoded.write(decodedEscape);
        }
        _i += consumed;
        continue;
      }

      if (ch == r'$' && _i + 1 < _len) {
        final next = _source[_i + 1];
        if (next == '{') {
          if (!hasInterpolation) {
            hasInterpolation = true;
            _writeMaskedSlice(start, _i);
          }
          _out.write('  ');
          _i += 2;
          _braceDepth++;
          _scanCode(stopAtBraceDepth: _braceDepth);
          continue;
        }
        if (_isIdentStartNoDollar(next)) {
          if (!hasInterpolation) {
            hasInterpolation = true;
            _writeMaskedSlice(start, _i);
          }
          _out.write(' ');
          _i++;
          while (_i < _len && _isIdentPart(_source[_i])) {
            _out.write(_source[_i]);
            _i++;
          }
          continue;
        }
      }

      if (isTriple) {
        if (_source.startsWith(endQuote, _i)) {
          if (hasInterpolation) {
            _writeMaskedSlice(_i, _i + 3);
          }
          _i += 3;
          closed = true;
          break;
        }
      } else {
        if (ch == quote) {
          if (hasInterpolation) {
            _out.write(' ');
          }
          _i++;
          closed = true;
          break;
        }
        if (ch == '\n' || ch == '\r') {
          break;
        }
      }

      if (hasInterpolation) {
        _out.write(ch == '\n' ? '\n' : ' ');
      } else {
        decoded.write(ch);
      }
      _i++;
    }

    final end = _i;
    if (!hasInterpolation) {
      if (closed && end - start >= 2) {
        _spans[start] = _StringSpan(
          start: start,
          end: end,
          value: decoded.toString(),
        );
        _writeQuotedMask(start, end);
      } else {
        _writeMaskedSlice(start, end);
      }
    }
  }

  (String, int) _decodeEscapeAt(int slashIndex) {
    final escaped = _source[slashIndex + 1];
    if (escaped == 'x') {
      if (slashIndex + 3 < _len &&
          _isHexDigit(_source[slashIndex + 2]) &&
          _isHexDigit(_source[slashIndex + 3])) {
        final code = int.parse(
          _source.substring(slashIndex + 2, slashIndex + 4),
          radix: 16,
        );
        return (String.fromCharCode(code), 4);
      }
      return ('x', 2);
    }

    if (escaped == 'u') {
      if (slashIndex + 2 < _len && _source[slashIndex + 2] == '{') {
        var j = slashIndex + 3;
        while (j < _len && _isHexDigit(_source[j])) {
          j++;
        }
        final hexLen = j - (slashIndex + 3);
        if (hexLen >= 1 && hexLen <= 6 && j < _len && _source[j] == '}') {
          final code = int.parse(
            _source.substring(slashIndex + 3, j),
            radix: 16,
          );
          if (code <= 0x10FFFF) {
            return (String.fromCharCode(code), (j + 1) - slashIndex);
          }
        }
        return ('u', 2);
      }
      if (slashIndex + 5 < _len &&
          _isHexDigit(_source[slashIndex + 2]) &&
          _isHexDigit(_source[slashIndex + 3]) &&
          _isHexDigit(_source[slashIndex + 4]) &&
          _isHexDigit(_source[slashIndex + 5])) {
        final code = int.parse(
          _source.substring(slashIndex + 2, slashIndex + 6),
          radix: 16,
        );
        return (String.fromCharCode(code), 6);
      }
      return ('u', 2);
    }

    return (_decodeSimpleEscape(escaped), 2);
  }

  String _decodeSimpleEscape(String ch) {
    switch (ch) {
      case 'n':
        return '\n';
      case 'r':
        return '\r';
      case 't':
        return '\t';
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      case 'v':
        return '\v';
      default:
        return ch;
    }
  }
}

/// 扫描单个 Dart 源文件（以 `lib/` 为基准的相对路径 `relFromLib`），返回隔离违例列表。
List<String> scanDesignSystemSource(
  String displayPath,
  String relFromLib,
  String rawSource,
) {
  final lex = _DartLexer(rawSource).run();
  final masked = lex.masked;
  final violations = <String>[];

  // 1. 扫描 import / export / part / part of 指令 URI（支持相邻字符串拼接与条件导入）
  for (final match in _directivePattern.allMatches(masked)) {
    final lineNumber =
        '\n'.allMatches(masked.substring(0, match.start)).length + 1;
    final body = match.group(2) ?? '';
    final bodyStart = match.end - 1 - body.length;

    var parenDepth = 0;
    var rel = 0;
    StringBuffer? pendingUri;

    void flushPendingUri() {
      final buf = pendingUri;
      if (buf == null) return;
      pendingUri = null;
      _checkDirectiveUri(
        uri: buf.toString(),
        displayPath: displayPath,
        relFromLib: relFromLib,
        lineNumber: lineNumber,
        violations: violations,
      );
    }

    while (rel < body.length) {
      final ch = body[rel];
      if (ch == '(') {
        if (parenDepth == 0) flushPendingUri();
        parenDepth++;
        rel++;
        continue;
      }
      if (ch == ')') {
        if (parenDepth == 0) flushPendingUri();
        if (parenDepth > 0) parenDepth--;
        rel++;
        continue;
      }
      if (ch == '"') {
        final span = lex.stringSpans[bodyStart + rel];
        if (span != null) {
          if (parenDepth == 0) {
            (pendingUri ??= StringBuffer()).write(span.value);
          }
          rel = span.end - bodyStart;
          continue;
        }
      }
      if (parenDepth == 0 &&
          ch != ' ' &&
          ch != '\t' &&
          ch != '\n' &&
          ch != '\r') {
        flushPendingUri();
      }
      rel++;
    }
    flushPendingUri();
  }

  // 1b. 拦截非 URI 的库名形式 `part of <library_name>;`
  for (final match in _partOfLibraryNamePattern.allMatches(masked)) {
    final lineNumber =
        '\n'.allMatches(masked.substring(0, match.start)).length + 1;
    final libName = (match.group(1) ?? '').trim();
    violations.add(
      '$displayPath:$lineNumber 禁止使用基于库名的 part of 指令: $libName',
    );
  }

  // 2. 扫描掩码后的代码中的旧主题标识符引用（字符串字面量中的同名文本不会误报）
  final lines = masked.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final symMatch = _legacySymbolPattern.firstMatch(lines[i]);
    if (symMatch != null) {
      violations.add(
        '$displayPath:${i + 1} 禁止引用旧主题符号 ${symMatch.group(1)}',
      );
    }
  }

  return violations;
}

void _checkDirectiveUri({
  required String uri,
  required String displayPath,
  required String relFromLib,
  required int lineNumber,
  required List<String> violations,
}) {
  if (uri.startsWith('dart:')) return;

  if (uri == 'package:watchdog' || uri.startsWith('package:watchdog/')) {
    if (uri == 'package:watchdog') {
      violations.add('$displayPath:$lineNumber 禁止跨层引入 $uri');
      return;
    }
    final target = uri.substring('package:watchdog/'.length);
    try {
      final base = Uri.parse('https://lib.local/root/lib/');
      final resolvedRaw = base.resolve(target);
      final decodedTarget = Uri.decodeFull(target).replaceAll(r'\', '/');
      final resolved = base.resolve(decodedTarget);
      final resolvedPath = resolved.path;
      final underLib = resolvedPath.startsWith('/root/lib/')
          ? resolvedPath.substring('/root/lib/'.length)
          : '';
      final firstSeg = underLib.isEmpty ? '' : underLib.split('/').first;
      if (resolvedRaw.hasQuery ||
          resolvedRaw.hasFragment ||
          resolved.hasQuery ||
          resolved.hasFragment ||
          resolvedRaw.path != resolvedPath ||
          !resolvedPath.startsWith('/root/lib/design_system/') ||
          _forbiddenDirs.contains(firstSeg) ||
          underLib == 'main.dart') {
        violations.add(
          '$displayPath:$lineNumber 禁止跨层引入 $uri -> $resolvedPath',
        );
      }
    } on FormatException {
      violations.add('$displayPath:$lineNumber 非法引入 URI $uri');
    }
    return;
  }

  if (uri.startsWith('package:')) {
    return;
  }

  try {
    final parsed = Uri.parse(uri);
    if (parsed.hasScheme) {
      violations.add('$displayPath:$lineNumber 禁止非标准引入 $uri');
      return;
    }
    final base = Uri.parse('https://lib.local/root/lib/$relFromLib');
    final decodedUri = Uri.decodeFull(uri).replaceAll(r'\', '/');
    final resolvedRaw = base.resolve(uri);
    final resolved = base.resolve(decodedUri);
    if (resolvedRaw.path != resolved.path ||
        !resolved.path.startsWith('/root/lib/design_system/')) {
      violations.add(
        '$displayPath:$lineNumber 禁止越界相对引入 $uri -> ${resolved.path}',
      );
    }
  } on FormatException {
    violations.add('$displayPath:$lineNumber 非法相对引入 $uri');
  }
}

String _stripYamlInlineComment(String value) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (ch == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (ch == '"' && !inSingle && (i == 0 || value[i - 1] != r'\')) {
      inDouble = !inDouble;
    } else if (ch == '#' && !inSingle && !inDouble) {
      if (i == 0 || value[i - 1] == ' ' || value[i - 1] == '\t') {
        return value.substring(0, i).trim();
      }
    }
  }
  return value.trim();
}

bool _hasDisallowedYamlPrefix(String text) {
  return text.startsWith('!') ||
      text.startsWith('&') ||
      text.startsWith('*') ||
      text.startsWith('%') ||
      text.startsWith('?') ||
      text.startsWith('{') ||
      text.startsWith('[');
}

(String, String)? _parseTopLevelYamlHeader(String line) {
  if (_hasDisallowedYamlPrefix(line)) {
    throw FormatException(
      'pubspec.yaml 禁止使用 YAML 标签、锚点、别名、指令或复杂流式顶级语法: $line',
    );
  }

  if (RegExp(r'^(?:---|\.\.\.)(?:$|[ \t#])').hasMatch(line)) {
    if (_stripYamlInlineComment(line.substring(3)).isNotEmpty) {
      throw FormatException('pubspec.yaml 文档分隔符同行不允许附加内容: $line');
    }
    return null;
  }

  if (line.startsWith("'")) {
    final buf = StringBuffer();
    var i = 1;
    var closed = false;
    while (i < line.length) {
      if (line[i] == "'") {
        if (i + 1 < line.length && line[i + 1] == "'") {
          buf.write("'");
          i += 2;
          continue;
        }
        closed = true;
        i++;
        break;
      }
      buf.write(line[i]);
      i++;
    }
    if (!closed) {
      throw FormatException('pubspec.yaml 存在未闭合的单引号顶级键: $line');
    }
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    if (i >= line.length || line[i] != ':') {
      throw FormatException('pubspec.yaml 单引号顶级键格式非法: $line');
    }
    return (buf.toString(), line.substring(i + 1));
  }

  if (line.startsWith('"')) {
    final buf = StringBuffer();
    var i = 1;
    var closed = false;
    while (i < line.length) {
      final ch = line[i];
      if (ch == r'\') {
        if (i + 1 >= line.length) {
          throw FormatException('pubspec.yaml 存在未闭合的双引号顶级键: $line');
        }
        final esc = line[i + 1];
        switch (esc) {
          case '"':
          case r'\':
          case '/':
          case ' ':
            buf.write(esc);
            i += 2;
          case 'n':
            buf.write('\n');
            i += 2;
          case 'r':
            buf.write('\r');
            i += 2;
          case 't':
            buf.write('\t');
            i += 2;
          case 'b':
            buf.write('\b');
            i += 2;
          case 'f':
            buf.write('\f');
            i += 2;
          case 'v':
            buf.write('\v');
            i += 2;
          case '0':
            buf.write('\x00');
            i += 2;
          case 'x':
            if (i + 3 < line.length &&
                _isHexDigit(line[i + 2]) &&
                _isHexDigit(line[i + 3])) {
              buf.writeCharCode(
                int.parse(line.substring(i + 2, i + 4), radix: 16),
              );
              i += 4;
            } else {
              throw FormatException('pubspec.yaml 双引号顶级键存在非法转义: $line');
            }
          case 'u':
            if (i + 5 < line.length &&
                _isHexDigit(line[i + 2]) &&
                _isHexDigit(line[i + 3]) &&
                _isHexDigit(line[i + 4]) &&
                _isHexDigit(line[i + 5])) {
              buf.writeCharCode(
                int.parse(line.substring(i + 2, i + 6), radix: 16),
              );
              i += 6;
            } else {
              throw FormatException('pubspec.yaml 双引号顶级键存在非法转义: $line');
            }
          case 'U':
            if (i + 9 < line.length &&
                List.generate(8, (k) => _isHexDigit(line[i + 2 + k]))
                    .every((ok) => ok)) {
              final code = int.parse(line.substring(i + 2, i + 10), radix: 16);
              if (code > 0x10FFFF) {
                throw FormatException('pubspec.yaml 双引号顶级键存在越界转义: $line');
              }
              buf.writeCharCode(code);
              i += 10;
            } else {
              throw FormatException('pubspec.yaml 双引号顶级键存在非法转义: $line');
            }
          default:
            throw FormatException('pubspec.yaml 双引号顶级键存在非法转义: $line');
        }
        continue;
      }
      if (ch == '"') {
        closed = true;
        i++;
        break;
      }
      buf.write(ch);
      i++;
    }
    if (!closed) {
      throw FormatException('pubspec.yaml 存在未闭合的双引号顶级键: $line');
    }
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    if (i >= line.length || line[i] != ':') {
      throw FormatException('pubspec.yaml 双引号顶级键格式非法: $line');
    }
    return (buf.toString(), line.substring(i + 1));
  }

  final topLevelHeader = RegExp(r'^([A-Za-z0-9_-]+)\s*:(.*)$');
  final topMatch = topLevelHeader.firstMatch(line);
  if (topMatch == null) return null;
  return (topMatch.group(1)!, topMatch.group(2)!);
}

/// 解析 `pubspec.yaml` 中指定顶级段的一级子键列表（支持引号顶级键、任意合法缩进与连字符键名，
/// 拒绝流式映射 `{...}`、畸形引号键、重复顶级段与非法缩进）。
Set<String> parsePubspecSectionKeys(List<String> lines, String sectionName) {
  final keys = <String>{};
  var inSection = false;
  var sectionCount = 0;
  int? childIndent;

  final childKeyPattern = RegExp(r'^([A-Za-z0-9_-]+)\s*:(.*)$');

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final isIndented = line.startsWith(' ') || line.startsWith('\t');
    if (!isIndented) {
      final header = _parseTopLevelYamlHeader(line);
      if (header != null && header.$1 == sectionName) {
        sectionCount++;
        if (sectionCount > 1) {
          throw FormatException('pubspec.yaml 存在重复的顶级段: $sectionName');
        }
        final trailing = _stripYamlInlineComment(header.$2);
        if (trailing.isNotEmpty) {
          throw FormatException(
            'pubspec.yaml $sectionName 不允许行内流式映射或非空段头值: $line',
          );
        }
        inSection = true;
        childIndent = null;
      } else {
        inSection = false;
        childIndent = null;
      }
      continue;
    }

    if (!inSection) continue;

    if (_hasDisallowedYamlPrefix(trimmed)) {
      throw FormatException(
        'pubspec.yaml $sectionName 禁止使用 YAML 标签、锚点、别名、指令或流式语法: $line',
      );
    }

    final leadingMatch = RegExp(r'^([ \t]+)').firstMatch(line);
    final leading = leadingMatch?.group(1) ?? '';
    if (leading.contains('\t')) {
      throw FormatException('pubspec.yaml $sectionName 禁止使用 Tab 缩进: $line');
    }

    final indent = leading.length;
    childIndent ??= indent;

    if (indent < childIndent) {
      throw FormatException(
        'pubspec.yaml $sectionName 存在不一致缩进 ($indent < $childIndent): $line',
      );
    }

    if (indent == childIndent) {
      final childMatch = childKeyPattern.firstMatch(trimmed);
      if (childMatch == null) {
        throw FormatException(
          'pubspec.yaml $sectionName 存在非法或不可解析子键: $line',
        );
      }
      keys.add(childMatch.group(1)!);
    }
  }

  return keys;
}

void main() {
  group('Design System v3.0 依赖隔离门禁', () {
    test('lib/design_system 下禁止引入业务代码或旧 theme 目录，且禁止引用旧主题类', () {
      final dsDir = Directory('lib/design_system');
      expect(
        dsDir.existsSync(),
        isTrue,
        reason: '请在 app/ 目录运行测试，当前未找到 lib/design_system',
      );

      final dartFiles = dsDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      expect(dartFiles, isNotEmpty, reason: 'lib/design_system 中应至少存在一个 Dart 文件');

      final violations = <String>[];
      for (final file in dartFiles) {
        final normPath = file.path.replaceAll(r'\', '/');
        final libIdx = normPath.indexOf('lib/');
        expect(libIdx, isNonNegative, reason: '非法文件路径: $normPath');
        final relFromLib = normPath.substring(libIdx + 'lib/'.length);
        violations.addAll(
          scanDesignSystemSource(normPath, relFromLib, file.readAsStringSync()),
        );
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('pubspec.yaml 保持零新增 pub 依赖、无新增 override 且不声明打包字体', () {
      final pubspecFile = File('pubspec.yaml');
      expect(pubspecFile.existsSync(), isTrue);
      final lines = pubspecFile.readAsLinesSync();

      final nameLine = lines.firstWhere(
        (l) => l.startsWith('name:'),
        orElse: () => '',
      );
      expect(nameLine.trim(), 'name: watchdog');

      const expectedDeps = <String>{
        'flutter',
        'record',
        'path_provider',
        'path',
        'http',
        'http_parser',
        'flutter_tts',
        'shared_preferences',
        'flutter_secure_storage',
        'sqflite',
        'audioplayers',
        'flutter_local_notifications',
        'timezone',
        'crypto',
        'convert',
        'sherpa_onnx',
        'flutter_markdown',
        'flutter_foreground_task',
        'package_info_plus',
        'remixicon',
        'image_picker',
        'share_plus',
        'image',
        'mobile_scanner',
        'url_launcher',
        'media_kit',
        'media_kit_libs_video',
        'media_kit_video',
      };
      const expectedDevDeps = <String>{
        'flutter_test',
        'flutter_lints',
        'sqflite_common_ffi',
      };
      const expectedOverrides = <String>{'package_info_plus'};

      expect(
        parsePubspecSectionKeys(lines, 'dependencies'),
        equals(expectedDeps),
      );
      expect(
        parsePubspecSectionKeys(lines, 'dev_dependencies'),
        equals(expectedDevDeps),
      );
      expect(
        parsePubspecSectionKeys(lines, 'dependency_overrides'),
        equals(expectedOverrides),
      );

      final flutterKeys = parsePubspecSectionKeys(lines, 'flutter');
      expect(flutterKeys, isNot(contains('fonts')));
    });
  });

  group('隔离扫描器与 YAML 解析器抗绕过自检', () {
    test('允许 design_system 内部相对与包内引入', () {
      const validSource = '''
library ds_btn;
import 'package:flutter/widgets.dart';
import '../theme/ds_theme.dart';
import 'package:watchdog/design_system/tokens/ds_colors.dart';

const doc = \'\'\'
import '../../pages/home_page.dart';
const fake = AppColors.red;
\'\'\';
const label = 'AppColors';
// import '../../state/app_controller.dart';
/* /* nested */ AppPalette */
''';
      expect(
        scanDesignSystemSource(
          'lib/design_system/components/x.dart',
          'design_system/components/x.dart',
          validSource,
        ),
        isEmpty,
      );
    });

    test('拦截 package:watchdog/design_system/../ 路径穿越绕过', () {
      final v1 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import 'package:watchdog/design_system/../pages/x.dart';",
      );
      expect(v1, hasLength(1));

      final v2 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import 'package:watchdog/design_system/../theme/app_palette.dart';",
      );
      expect(v2, hasLength(1));

      final v3 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import 'package:watchdog/design_system/%2e%2e/pages/x.dart';",
      );
      expect(v3, hasLength(1));
    });

    test('拦截同行多条指令 (; import / library; import) 与无空格指令', () {
      final v1 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import 'package:flutter/widgets.dart'; import '../../pages/home_page.dart';",
      );
      expect(v1, hasLength(1));

      final v2 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "library ds; import '../../pages/home_page.dart';",
      );
      expect(v2, hasLength(1));

      final v3 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import'../../theme/app_palette.dart';",
      );
      expect(v3, hasLength(1));
    });

    test("拦截条件导入中包含 ';' 字符串字面量的绕过", () {
      final v = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import '../tokens/ds_colors.dart' if (dart.library.io == ';') '../../pages/home_page.dart';",
      );
      expect(v, hasLength(1));
    });

    test(r"正确处理嵌套 ${...} 字符串插值，不吞没后续 AppColors / AppPalette", () {
      const trickySource = r'''
const s = 'a ${'/*'} b';
final x = AppColors.red;
final y = '${AppPalette.primary}';
''';
      final v = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        trickySource,
      );
      expect(v, hasLength(2));
      expect(v[0], contains('AppColors'));
      expect(v[1], contains('AppPalette'));
    });

    test('YAML 解析器拦截 4 空格缩进、连字符包名、流式映射与新增 dependency_overrides', () {
      final fourSpaceDeps = <String>[
        'dependencies:',
        '    flutter:',
        '        sdk: flutter',
        '    google-fonts: ^6.0.0',
      ];
      expect(
        parsePubspecSectionKeys(fourSpaceDeps, 'dependencies'),
        equals(<String>{'flutter', 'google-fonts'}),
      );

      final fourSpaceFonts = <String>[
        'flutter:',
        '    uses-material-design: true',
        '    fonts:',
        '      - family: CustomFont',
      ];
      expect(
        parsePubspecSectionKeys(fourSpaceFonts, 'flutter'),
        contains('fonts'),
      );

      final flowMapYaml = <String>[
        'dependencies: {flutter: {sdk: flutter}, evil: ^1.0.0}',
      ];
      expect(
        () => parsePubspecSectionKeys(flowMapYaml, 'dependencies'),
        throwsFormatException,
      );

      final extraOverride = <String>[
        'dependency_overrides:',
        '  package_info_plus:',
        '    path: third_party/package_info_plus',
        '  evil_pkg: ^1.0.0',
      ];
      expect(
        parsePubspecSectionKeys(extraOverride, 'dependency_overrides'),
        equals(<String>{'package_info_plus', 'evil_pkg'}),
      );
    });

    test('拦截指令 URI 相邻字符串字面量拼接绕过，并放行内部合法拼接', () {
      final v1 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import 'package:watchdog/design_system/' '../pages/home_page.dart';",
      );
      expect(v1, hasLength(1));

      final v2 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import 'package:watchdog/design_system/' /* c */ '../theme/app_palette.dart';",
      );
      expect(v2, hasLength(1));

      final v3 = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "import '../tokens/ds_colors.dart' if (dart.library.io) 'package:watchdog/design_system/' '../pages/home_page.dart';",
      );
      expect(v3, hasLength(1));

      final validAdjacent = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        '''
import 'package:flutter/' 'widgets.dart';
import '../tokens/' 'ds_colors.dart'
    if (dart.library.io) '../theme/' 'ds_theme.dart';
''',
      );
      expect(validAdjacent, isEmpty);
    });

    test(r'解码 \xHH / \uHHHH / \u{H...} 转义拦截越界 URI，且不解码 raw 字符串与安全处理畸形转义', () {
      final vHexRel = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        r"import '\x2e\x2e/\x2e\x2e/pages/home_page.dart';",
      );
      expect(vHexRel, hasLength(1));

      final vHexPkg = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        r"import 'package:watchdog/design_system/\x2e\x2e/pages/home_page.dart';",
      );
      expect(vHexPkg, hasLength(1));

      final vU4Rel = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        r"import '\u002e\u002e/\u002e\u002e/pages/home_page.dart';",
      );
      expect(vU4Rel, hasLength(1));

      final vUBracePkg = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        r"import 'package:watchdog/design_system/\u{2e}\u{2e}/pages/home_page.dart';",
      );
      expect(vUBracePkg, hasLength(1));

      final interpWithEscapes = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "const a = 1;\nconst s = 'p \\x2e \\u002e \\u{2e} \$a q';\nfinal c = AppColors.red;",
      );
      expect(interpWithEscapes, hasLength(1));
      expect(interpWithEscapes.single, contains(':3 '));

      final rawLex = _DartLexer(r"const s = r'\x2e\u002e\u{2e}';").run();
      expect(rawLex.stringSpans.values.single.value, r'\x2e\u002e\u{2e}');

      final malformed = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        r"const bad = '\x2z \u12 \u{} \u{110000}';",
      );
      expect(malformed, isEmpty);
    });

    test('拦截越界 URI 与库名形式的 part of 指令，并放行内部 part / part of', () {
      final vPartOfRel = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "part of '../../pages/host_lib.dart';",
      );
      expect(vPartOfRel, hasLength(1));

      final vPartOfPkg = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "part of 'package:watchdog/pages/host_lib.dart';",
      );
      expect(vPartOfPkg, hasLength(1));

      final vPartOfLibName = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        'part of host_lib;',
      );
      expect(vPartOfLibName, hasLength(1));

      final vPartOfDottedLib = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        'part of app.pages.host_lib;',
      );
      expect(vPartOfDottedLib, hasLength(1));

      final validParts = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        '''
part '../tokens/ds_colors.dart';
part of '../design_system.dart';
part of 'package:watchdog/design_system/design_system.dart';
const partOf = 1;
const part = 2;
''',
      );
      expect(validParts, isEmpty);
    });

    test('按 Dart 规范剥离三引号多行字符串首行空白与换行，拦截拼接绕过且不误伤合法引入或转义', () {
      // 1. 包路径 + 三引号多行（''' / """ / r''' / r""" / [ \t]*\n / [ \t]*\r\n）
      final bypasses = <String>[
        "import 'package:watchdog/design_system/' '''\n../pages/home_page.dart''';",
        'import \'package:watchdog/design_system/\' """\n../theme/app_palette.dart""";',
        "import 'package:watchdog/design_system/' r'''\n../pages/home_page.dart''' as raw_p;",
        'import \'package:watchdog/design_system/\' r"""\r\n../theme/app_palette.dart""";',
        "import 'package:watchdog/design_system/' '''   \t\n../pages/home_page.dart''' as s1;",
        "import 'package:watchdog/design_system/' '''  \r\n../pages/home_page.dart''';",
        "export 'package:watchdog/design_system/' '''\n../theme/app_palette.dart''';",
        "import '../' '''\n../pages/home_page.dart''';",
        "part of 'package:watchdog/design_system/' '''\n../pages/host_lib.dart''';",
      ];
      for (final src in bypasses) {
        expect(
          scanDesignSystemSource(
            'lib/design_system/components/x.dart',
            'design_system/components/x.dart',
            src,
          ),
          hasLength(1),
          reason: '应当拦截三引号多行绕过: $src',
        );
      }

      // 2. 独立三引号合法包引入不得误报
      expect(
        scanDesignSystemSource(
          'lib/design_system/components/x.dart',
          'design_system/components/x.dart',
          "import '''\npackage:flutter/widgets.dart''';",
        ),
        isEmpty,
      );
      expect(
        scanDesignSystemSource(
          'lib/design_system/components/x.dart',
          'design_system/components/x.dart',
          'import r"""   \r\npackage:watchdog/design_system/tokens/ds_colors.dart""";',
        ),
        isEmpty,
      );

      // 3. 转义序列 \n / \x20 不得被当作字面首行空白换行剥离，无换行前导空格亦不得剥离
      final escapedNewlineLex = _DartLexer(r"const s = '''\nhello''';").run();
      expect(escapedNewlineLex.stringSpans.values.single.value, '\nhello');

      final escapedSpaceLex =
          _DartLexer("const s = '''\\x20\nhello''';").run();
      expect(escapedSpaceLex.stringSpans.values.single.value, ' \nhello');

      final rawEscapedLex = _DartLexer(r"const s = r'''\nhello''';").run();
      expect(rawEscapedLex.stringSpans.values.single.value, r'\nhello');

      final spacesWithoutNewline =
          _DartLexer("const s = '''   hello''';").run();
      expect(spacesWithoutNewline.stringSpans.values.single.value, '   hello');

      final doubleNewlineLex =
          _DartLexer("const s = '''\n\nhello''';").run();
      expect(doubleNewlineLex.stringSpans.values.single.value, '\nhello');

      // 4. 含插值的三引号多行字符串必须保留换行行号
      final interpMultiline = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "const a = 1;\nconst s = '''\n\$a\n''';\nfinal c = AppColors.red;",
      );
      expect(interpMultiline, hasLength(1));
      expect(interpMultiline.single, contains(':5 '));
    });

    test('YAML 解析器拦截带引号顶级键 ("flutter": / \'dependencies\':) 并对畸形引号键快速失败', () {
      expect(
        parsePubspecSectionKeys(
          <String>['"flutter":', '  fonts:', '    - family: BadFont'],
          'flutter',
        ),
        contains('fonts'),
      );
      expect(
        parsePubspecSectionKeys(
          <String>["'flutter':", '  fonts:', '    - family: BadFont'],
          'flutter',
        ),
        contains('fonts'),
      );
      expect(
        parsePubspecSectionKeys(
          <String>['"dependencies":', '  evil: ^1.0.0'],
          'dependencies',
        ),
        equals(<String>{'evil'}),
      );
      expect(
        parsePubspecSectionKeys(
          <String>["'dependencies':", '  evil: ^1.0.0'],
          'dependencies',
        ),
        equals(<String>{'evil'}),
      );
      expect(
        () => parsePubspecSectionKeys(
          <String>['flutter:', '  uses-material-design: true', '"flutter":', '  fonts:'],
          'flutter',
        ),
        throwsFormatException,
      );
      expect(
        () => parsePubspecSectionKeys(<String>['"flutter:', '  fonts:'], 'flutter'),
        throwsFormatException,
      );
      expect(
        () => parsePubspecSectionKeys(<String>["'flutter:", '  fonts:'], 'flutter'),
        throwsFormatException,
      );
      expect(
        () => parsePubspecSectionKeys(<String>['"flutter" extra:', '  fonts:'], 'flutter'),
        throwsFormatException,
      );
    });

    test(r'单行注释与单行字符串识别孤立 \r 与 \r\n 行结束符，拦截隐藏指令与旧符号', () {
      final crImport = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "// comment\rimport '../../pages/home_page.dart';",
      );
      expect(crImport, hasLength(1));

      final crDocLegacy = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        '/// doc\rfinal x = AppColors.red;',
      );
      expect(crDocLegacy, hasLength(1));

      final crlfImport = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "// comment\r\nimport '../../pages/home_page.dart';",
      );
      expect(crlfImport, hasLength(1));
      expect(crlfImport.single, contains(':2 '));

      final crlfDocLegacy = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        '/// doc\r\nfinal x = AppPalette.primary;',
      );
      expect(crlfDocLegacy, hasLength(1));
      expect(crlfDocLegacy.single, contains(':2 '));

      final crInInterp = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "const s = '\${ // comment }\r}';\nfinal x = AppColors.red;",
      );
      expect(crInInterp, hasLength(1));
      expect(crInInterp.single, contains(':2 '));

      final validCrComment = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "// comment\rimport '../tokens/ds_colors.dart';",
      );
      expect(validCrComment, isEmpty);

      final crUnclosedSingle = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "const s = 'unclosed\rimport '../../pages/home_page.dart';",
      );
      expect(crUnclosedSingle, hasLength(1));

      final crUnclosedRaw = scanDesignSystemSource(
        'lib/design_system/components/x.dart',
        'design_system/components/x.dart',
        "const s = r'unclosed\rfinal x = AppColors.red;",
      );
      expect(crUnclosedRaw, hasLength(1));
    });

    test('YAML 解析器对顶级与缩进标签/锚点/别名/指令快速失败，且正确处理 --- / ... 文档分隔符', () {
      final failCases = <(List<String>, String)>[
        (<String>['!!str flutter:', '  fonts:'], 'flutter'),
        (<String>['&f flutter:', '  fonts:'], 'flutter'),
        (<String>['!!str &f flutter:', '  fonts:'], 'flutter'),
        (<String>['!!str dependencies:', '  evil: ^1.0.0'], 'dependencies'),
        (<String>['&d dependencies:', '  evil: ^1.0.0'], 'dependencies'),
        (<String>['*alias:', '  fonts:'], 'flutter'),
        (<String>['%YAML 1.2', 'flutter:', '  fonts:'], 'flutter'),
        (<String>['%TAG !e! tag:example.com,2000:', 'dependencies:', '  evil: ^1.0.0'], 'dependencies'),
        (<String>['flutter:', '  !!str fonts:'], 'flutter'),
        (<String>['flutter:', '  &f fonts:'], 'flutter'),
        (<String>['flutter:', '  assets:', '    *alias'], 'flutter'),
        (<String>['--- !!str flutter:', '  fonts:'], 'flutter'),
        (<String>['--- {evil: 1}'], 'dependencies'),
      ];

      for (final (yamlLines, section) in failCases) {
        expect(
          () => parsePubspecSectionKeys(yamlLines, section),
          throwsFormatException,
          reason: '应当快速失败拒绝非标准 YAML 语法 ($section): $yamlLines',
        );
      }

      final multiDocLines = <String>[
        '--- # doc start',
        'dependencies:',
        '  evil: ^1.0.0',
        '...',
        '---',
        'flutter:',
        '  fonts:',
      ];
      expect(
        parsePubspecSectionKeys(multiDocLines, 'dependencies'),
        equals(<String>{'evil'}),
      );
      expect(
        parsePubspecSectionKeys(multiDocLines, 'flutter'),
        contains('fonts'),
      );
    });
  });
}
