import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import 'op_log_service.dart';

/// 后台诊断日志：捕获 Flutter/Dart 未处理异常，滚动保存在本机并择机上报。
///
/// 诊断日志不进入 App 界面。写文件和上报均为 best effort，任何异常都不能
/// 反过来影响主业务链路。上报复用 /api/logs，需在 App 已加入警情后进行。
class DiagnosticLogService {
  DiagnosticLogService._();

  static final DiagnosticLogService instance = DiagnosticLogService._();

  static const int maxLogFileBytes = 1024 * 1024;
  static const int maxPendingFileBytes = 512 * 1024;
  static const int maxPendingEvents = 100;
  // Keep the serialized payload below the backend's per-log size limit while
  // retaining enough context to identify the failing code path.
  static const int maxErrorChars = 1000;
  static const int maxStackChars = 4000;
  static const int maxContextChars = 500;
  static const String _fallbackKey = 'diagnostic_log_fallback_v1';

  Future<void>? _initFuture;
  Future<void> _writeQueue = Future<void>.value();
  Directory? _directory;
  String _appVersion = 'unknown';
  String _page = 'unknown';
  bool _uploading = false;
  int _sequence = 0;

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initInternal();
    _initFuture = future;
    return future;
  }

  Future<void> _initInternal() async {
    try {
      _directory = await getApplicationSupportDirectory();
    } catch (_) {
      _directory = null;
      return;
    }

    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // 版本信息属于辅助字段，插件不可用时不影响日志落盘。
    }

    try {
      final fallback = await _readFallback();
      for (final event in fallback) {
        await _appendEvent(event);
      }
      if (fallback.isNotEmpty) await _clearFallback();
    } catch (_) {
      // 已有日志回放失败时保留原文件，下一次启动继续尝试。
    }
  }

  /// 设置最近一次已知页面，异常日志中只记录页面名，不记录页面内容。
  void setPage(String page) {
    final clean = page.trim();
    if (clean.isNotEmpty) _page = clean;
  }

  /// 记录 Flutter framework 异常（典型红屏来源）。
  void recordFlutterError(FlutterErrorDetails details) {
    final context = details.context?.toDescription();
    _record(
      error: details.exception,
      stack: details.stack,
      source: 'flutter_error',
      context: context,
      library: details.library,
    );
  }

  /// 记录未被业务捕获的异步异常或 Zone 异常。
  void recordUncaught(
    Object error,
    StackTrace stack, {
    String source = 'uncaught',
  }) {
    _record(error: error, stack: stack, source: source);
  }

  void _record({
    required Object error,
    StackTrace? stack,
    required String source,
    String? context,
    String? library,
  }) {
    final event = buildEvent(
      error: error,
      stack: stack,
      source: source,
      page: _page,
      appVersion: _appVersion,
      context: context,
      library: library,
      sequence: _sequence++,
      breadcrumbs: OpLogService.instance.logs
          .take(8)
          .map(
            (item) => <String, dynamic>{
              'stage': item.stage,
              'level': item.level,
            },
          )
          .toList(growable: false),
    );
    _enqueueWrite(() async {
      try {
        await init();
        if (_directory == null) {
          await _saveFallback(event);
          return;
        }
        await _appendEvent(event);
      } catch (_) {
        await _saveFallback(event);
      }
    });
  }

  /// 供单测和异常处理器共用的纯 payload 构造函数。
  @visibleForTesting
  static Map<String, dynamic> buildEvent({
    required Object error,
    StackTrace? stack,
    required String source,
    required String page,
    required String appVersion,
    String? context,
    String? library,
    int? sequence,
    List<Map<String, dynamic>> breadcrumbs = const [],
    int? timestamp,
  }) {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final suffix = sequence ?? ts;
    final errorText = _redact(error.toString());
    final stackText = stack == null ? '' : _redact(stack.toString());
    final data = <String, dynamic>{
      'source': _truncate(source, maxContextChars),
      'app_version': _truncate(appVersion, maxContextChars),
      'page': _truncate(page, maxContextChars),
      'error': _truncate(errorText, maxErrorChars),
      if (stackText.isNotEmpty) 'stack': _truncate(stackText, maxStackChars),
      if (context != null && context.trim().isNotEmpty)
        'context': _truncate(_redact(context), maxContextChars),
      if (library != null && library.trim().isNotEmpty)
        'library': _truncate(_redact(library), maxContextChars),
      if (breadcrumbs.isNotEmpty) 'breadcrumbs': breadcrumbs,
    };
    return {
      'ts': ts,
      'op_id': 'diag-$ts-$suffix',
      'stage': 'diagnostic_error',
      'level': 'error',
      'msg': _truncate(errorText, maxErrorChars),
      'data': data,
    };
  }

  /// 仅在已有警情的 ApiClient 上报；没有网络或警情时保留本地待传文件。
  Future<void> flush({ApiClient? api}) async {
    if (_uploading || api == null) return;
    _uploading = true;
    try {
      await init();
      await _writeQueue;
      final file = _pendingFile;
      if (file == null || !await file.exists()) return;
      final events = await _readEvents(file);
      if (events.isEmpty) {
        try {
          await file.delete();
        } catch (_) {}
        return;
      }
      final batch = events.take(maxPendingEvents).toList();
      await api.sendLogs(batch);
      // 发送期间仍可能有新诊断事件追加到 pending 文件；成功后只删除
      // 本次快照对应的 op_id，避免覆盖并发写入的故障信息。
      final uploadedIds = batch
          .map((event) => event['op_id']?.toString())
          .whereType<String>()
          .toSet();
      await _enqueueWrite(() async {
        final current = await _readEvents(file);
        final remaining = <Map<String, dynamic>>[];
        final pendingIds = Set<String>.from(uploadedIds);
        for (final event in current) {
          final id = event['op_id']?.toString();
          if (id != null && pendingIds.remove(id)) continue;
          remaining.add(event);
        }
        if (remaining.isEmpty) {
          try {
            await file.delete();
          } catch (_) {}
        } else {
          await file.writeAsString(
            '${remaining.map(jsonEncode).join('\n')}\n',
            flush: true,
          );
        }
      });
    } catch (_) {
      // 诊断上传失败不能影响 App；待传文件留到下一次启动/同步重试。
    } finally {
      _uploading = false;
    }
  }

  File? get _logFile => _directory == null
      ? null
      : File('${_directory!.path}/watchdog_diagnostics.jsonl');

  File? get _pendingFile => _directory == null
      ? null
      : File('${_directory!.path}/watchdog_diagnostics_pending.jsonl');

  Future<void> _enqueueWrite(Future<void> Function() task) {
    final scheduled = _writeQueue.then<void>((_) => task());
    _writeQueue = scheduled.catchError((_) {});
    return scheduled;
  }

  Future<void> _appendEvent(Map<String, dynamic> event) async {
    final logFile = _logFile;
    final pendingFile = _pendingFile;
    if (logFile == null || pendingFile == null) throw StateError('诊断日志目录不可用');
    await logFile.parent.create(recursive: true);
    final line = '${jsonEncode(event)}\n';
    await logFile.writeAsString(line, mode: FileMode.append, flush: true);
    await pendingFile.writeAsString(line, mode: FileMode.append, flush: true);
    await _rotateIfNeeded(logFile, maxLogFileBytes);
    await _trimPending(pendingFile);
  }

  Future<void> _rotateIfNeeded(File file, int maxBytes) async {
    if (!await file.exists() || await file.length() <= maxBytes) return;
    final rotated = File('${file.path}.1');
    if (await rotated.exists()) await rotated.delete();
    await file.rename(rotated.path);
  }

  Future<void> _trimPending(File file) async {
    if (!await file.exists()) return;
    final lines = await file.readAsLines();
    if (lines.length <= maxPendingEvents &&
        await file.length() <= maxPendingFileBytes) {
      return;
    }
    final kept = lines.length > maxPendingEvents
        ? lines.sublist(lines.length - maxPendingEvents)
        : List<String>.from(lines);
    while (kept.length > 1 &&
        utf8.encode('${kept.join('\n')}\n').length > maxPendingFileBytes) {
      kept.removeAt(0);
    }
    await file.writeAsString(
      kept.isEmpty ? '' : '${kept.join('\n')}\n',
      flush: true,
    );
  }

  Future<List<Map<String, dynamic>>> _readEvents(File file) async {
    final result = <Map<String, dynamic>>[];
    for (final line in await file.readAsLines()) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) result.add(decoded);
      } catch (_) {
        // 跳过损坏的单行，避免阻塞后续诊断日志上报。
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> _readFallback() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_fallbackKey);
      if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _saveFallback(Map<String, dynamic> event) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final events = await _readFallback();
      events.add(event);
      final kept = events.length > 10
          ? events.sublist(events.length - 10)
          : events;
      await sp.setString(_fallbackKey, jsonEncode(kept));
    } catch (_) {}
  }

  Future<void> _clearFallback() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_fallbackKey);
    } catch (_) {}
  }

  static String _truncate(String value, int maxChars) =>
      value.length <= maxChars ? value : '${value.substring(0, maxChars)}…';

  static String _redact(String value) {
    var clean = value;
    final secretPattern = RegExp(
      r'(api[_-]?token|authorization|access[_-]?token|password|secret)(\s*[:=]\s*)(?:bearer\s+)?[^\s,;]+',
      caseSensitive: false,
    );
    clean = clean.replaceAllMapped(secretPattern, (match) {
      return '${match.group(1)}${match.group(2)}[REDACTED]';
    });
    // 异常文本常只有“Bearer <token>”而没有键名，也必须在最终落盘前清理。
    clean = clean.replaceAll(
      RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    return clean;
  }
}
