import 'package:flutter/foundation.dart';

import 'log_sanitizer.dart';

/// 控制台日志输出函数签名。
typedef AppLogSink = void Function(String line);

/// 统一脱敏日志入口。
///
/// - 所有输出均经 `LogSanitizer.redactText` 脱敏后再打印；
/// - 正式版（`kReleaseMode`）默认静默详细日志（`log`），`error` 仅输出单行脱敏摘要
///   且不打印原始堆栈，降低敏感信息经 logcat 泄露的风险。
abstract final class AppLogger {
  static AppLogSink? _sinkOverride;
  static bool? _releaseModeOverride;

  static bool get _isReleaseMode => _releaseModeOverride ?? kReleaseMode;

  static void _emit(String line) {
    final sink = _sinkOverride;
    if (sink != null) {
      sink(line);
      return;
    }
    debugPrint(line);
  }

  /// 输出调试/过程日志；正式版默认门控静默（除非显式设置 `verbose: false`）。
  static void log(String message, {String? tag, bool verbose = true}) {
    final releaseMode = _isReleaseMode;
    if (releaseMode && verbose) return;
    final cleanMessage = LogSanitizer.redactText(
      message,
      isReleaseMode: releaseMode,
    );
    _emit(_formatLine(cleanMessage, tag: tag));
  }

  /// 输出脱敏后的错误摘要；非正式版同时打印脱敏后的堆栈信息。
  static void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final releaseMode = _isReleaseMode;
    final cleanMessage = LogSanitizer.redactText(
      message,
      isReleaseMode: releaseMode,
    );
    final buffer = StringBuffer(_formatLine(cleanMessage, tag: tag, level: 'ERROR'));
    if (error != null) {
      final cleanError = LogSanitizer.redactText(
        error.toString(),
        isReleaseMode: releaseMode,
      );
      if (cleanError.isNotEmpty) {
        buffer.write(' | $cleanError');
      }
    }
    _emit(buffer.toString());
    if (!releaseMode && stackTrace != null) {
      final cleanStack = LogSanitizer.redactText(
        stackTrace.toString(),
        isReleaseMode: false,
      );
      if (cleanStack.isNotEmpty) {
        _emit(cleanStack);
      }
    }
  }

  static String _formatLine(String message, {String? tag, String? level}) {
    final cleanTag = tag?.trim();
    final prefix = StringBuffer('[WatchDog]');
    if (cleanTag != null && cleanTag.isNotEmpty) {
      prefix.write('[$cleanTag]');
    }
    if (level != null && level.isNotEmpty) {
      prefix.write('[$level]');
    }
    return '$prefix $message';
  }

  /// 仅供单元测试注入输出桩与运行模式开关。
  @visibleForTesting
  static void setTestOverrides({AppLogSink? sink, bool? isReleaseMode}) {
    _sinkOverride = sink;
    _releaseModeOverride = isReleaseMode;
  }

  /// 恢复默认输出桩与运行模式。
  @visibleForTesting
  static void resetTestOverrides() {
    _sinkOverride = null;
    _releaseModeOverride = null;
  }
}
