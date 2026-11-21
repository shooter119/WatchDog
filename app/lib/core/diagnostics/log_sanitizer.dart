import 'package:flutter/foundation.dart';

/// 集中式日志脱敏工具：统一掩码凭据、单位验证码、Bearer 令牌及正式版设备标识。
///
/// 位于 `core/diagnostics/`，零业务层依赖，供 `AppLogger`、`DiagnosticLogService`
/// 与 `OpLogService` 复用。
abstract final class LogSanitizer {
  /// 统一脱敏占位符。
  static const String redacted = '[REDACTED]';

  static const String _baseKeyPattern =
      r'x[_-]?api[_-]?token|api[_-]?token|session[_-]?token|access[_-]?token|'
      r'refresh[_-]?token|x[_-]?unit[_-]?code|unit[_-]?code|authorization|'
      r'password|(?:[a-z0-9]+[_-])?secret';

  static const String _deviceIdKeyPattern = r'x[_-]?device[_-]?id|device[_-]?id';

  static final _RedactionRuleSet _baseRules = _RedactionRuleSet(_baseKeyPattern);
  static final _RedactionRuleSet _deviceIdRules = _RedactionRuleSet(
    _deviceIdKeyPattern,
  );

  static final RegExp _standaloneBearerRe = RegExp(
    r'\bBearer\s+(?!\[REDACTED\])[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );

  static const Set<String> _baseSensitiveKeys = <String>{
    'authorization',
    'session_token',
    'api_token',
    'x_api_token',
    'access_token',
    'refresh_token',
    'unit_code',
    'x_unit_code',
    'password',
    'secret',
    'token',
  };

  static const Set<String> _deviceIdKeys = <String>{
    'device_id',
    'x_device_id',
  };

  /// 将键名统一规范为小写下划线形式（支持 camelCase、kebab-case 与缩写词）。
  static String normalizeKey(String key) {
    return key
        .trim()
        .replaceAllMapped(
          RegExp(r'([A-Z]+)([A-Z][a-z])'),
          (match) => '${match.group(1)}_${match.group(2)}',
        )
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)}_${match.group(2)}',
        )
        .replaceAll('-', '_')
        .toLowerCase();
  }

  /// 判断结构化字段名是否属于敏感凭据或（正式版下的）设备标识。
  static bool isSensitiveKey(String key, {bool isReleaseMode = kReleaseMode}) {
    final normalized = normalizeKey(key);
    if (_baseSensitiveKeys.contains(normalized)) return true;
    if (normalized.endsWith('_token') ||
        normalized.endsWith('_secret') ||
        normalized.endsWith('_password')) {
      return true;
    }
    if (isReleaseMode && _deviceIdKeys.contains(normalized)) return true;
    return false;
  }

  /// 对自由文本（异常信息、HTTP 头、URL 查询串、JSON 片段、堆栈等）执行脱敏。
  static String redactText(String value, {bool isReleaseMode = kReleaseMode}) {
    if (value.isEmpty) return value;
    var clean = _baseRules.apply(value);
    if (isReleaseMode) {
      clean = _deviceIdRules.apply(clean);
    }
    clean = clean.replaceAll(_standaloneBearerRe, 'Bearer $redacted');
    return clean;
  }

  /// 递归脱敏结构化 Map（返回新实例，不修改入参）。
  static Map<String, dynamic> redactMap(
    Map<String, dynamic> input, {
    bool isReleaseMode = kReleaseMode,
  }) {
    final sanitized = <String, dynamic>{};
    for (final entry in input.entries) {
      final key = entry.key;
      final value = entry.value;
      if (isSensitiveKey(key, isReleaseMode: isReleaseMode)) {
        sanitized[key] = value == null ? null : redacted;
      } else {
        sanitized[key] = _redactValue(value, isReleaseMode: isReleaseMode);
      }
    }
    return sanitized;
  }

  static dynamic _redactValue(dynamic value, {required bool isReleaseMode}) {
    if (value is String) {
      return redactText(value, isReleaseMode: isReleaseMode);
    }
    if (value is Map) {
      final normalized = <String, dynamic>{};
      value.forEach((k, v) {
        normalized[k.toString()] = v;
      });
      return redactMap(normalized, isReleaseMode: isReleaseMode);
    }
    if (value is List) {
      return value
          .map((item) => _redactValue(item, isReleaseMode: isReleaseMode))
          .toList(growable: false);
    }
    return value;
  }
}

class _RedactionRuleSet {
  _RedactionRuleSet(String keyPattern)
    : _doubleQuotedJsonRe = RegExp(
        '(?<![A-Za-z0-9_-])(")($keyPattern)(")(\\s*:\\s*)"(?:\\\\.|[^"\\\\])*"',
        caseSensitive: false,
      ),
      _singleQuotedJsonRe = RegExp(
        "(?<![A-Za-z0-9_-])(')($keyPattern)(')(\\s*:\\s*)'(?:\\\\.|[^'\\\\])*'",
        caseSensitive: false,
      ),
      _quotedKeyUnquotedValRe = RegExp(
        '''(?<![A-Za-z0-9_-])(["'])($keyPattern)\\1(\\s*:\\s*)(?!\\[REDACTED\\])(?:(?:bearer|basic)\\s+)?[^\\s,;&"'}\\])]+''',
        caseSensitive: false,
      ),
      _unquotedKeyQuotedValRe = RegExp(
        '''(?<![A-Za-z0-9_-])($keyPattern)(\\s*[:=]\\s*)(["'])(?:\\\\.|[^"'\\\\])*\\3''',
        caseSensitive: false,
      ),
      _unquotedKeyUnquotedValRe = RegExp(
        '''(?<![A-Za-z0-9_-])($keyPattern)(\\s*[:=]\\s*)(?!\\[REDACTED\\])(?:(?:bearer|basic)\\s+)?[^\\s,;&"'}\\])]+''',
        caseSensitive: false,
      );

  final RegExp _doubleQuotedJsonRe;
  final RegExp _singleQuotedJsonRe;
  final RegExp _quotedKeyUnquotedValRe;
  final RegExp _unquotedKeyQuotedValRe;
  final RegExp _unquotedKeyUnquotedValRe;

  String apply(String input) {
    var clean = input;
    clean = clean.replaceAllMapped(
      _doubleQuotedJsonRe,
      (m) => '${m[1]}${m[2]}${m[3]}${m[4]}"${LogSanitizer.redacted}"',
    );
    clean = clean.replaceAllMapped(
      _singleQuotedJsonRe,
      (m) => "${m[1]}${m[2]}${m[3]}${m[4]}'${LogSanitizer.redacted}'",
    );
    clean = clean.replaceAllMapped(
      _quotedKeyUnquotedValRe,
      (m) => '${m[1]}${m[2]}${m[1]}${m[3]}${LogSanitizer.redacted}',
    );
    clean = clean.replaceAllMapped(
      _unquotedKeyQuotedValRe,
      (m) => '${m[1]}${m[2]}${m[3]}${LogSanitizer.redacted}${m[3]}',
    );
    clean = clean.replaceAllMapped(
      _unquotedKeyUnquotedValRe,
      (m) => '${m[1]}${m[2]}${LogSanitizer.redacted}',
    );
    return clean;
  }
}
