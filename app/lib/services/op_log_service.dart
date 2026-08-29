import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// 一条操作日志（语音录入全链路中的一步）
class OpLogEntry {
  final int ts;
  final String opId;
  final String stage;
  final String level; // info / warn / error
  final String msg;
  final Map<String, dynamic>? data;

  const OpLogEntry({
    required this.ts,
    required this.opId,
    required this.stage,
    required this.level,
    required this.msg,
    this.data,
  });

  Map<String, dynamic> toJson() => {
    'ts': ts,
    'op_id': opId,
    'stage': stage,
    'level': level,
    'msg': msg,
    if (data != null) 'data': data,
  };

  factory OpLogEntry.fromJson(Map<String, dynamic> json) => OpLogEntry(
    ts: (json['ts'] as num?)?.toInt() ?? 0,
    opId: (json['op_id'] as String?) ?? '',
    stage: (json['stage'] as String?) ?? '',
    level: (json['level'] as String?) ?? 'info',
    msg: (json['msg'] as String?) ?? '',
    data: json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : null,
  );
}

/// 操作日志服务：本地记录（供设置页查看）+ 批量上传服务器（供开发者调试）
class OpLogService {
  OpLogService._();
  static final OpLogService instance = OpLogService._();

  static const _kLogs = 'op_logs_v1';
  static const _kDeviceId = 'device_id';
  static const _kSyncEnabled = 'op_logs_sync_enabled';
  static const int maxLocal = 200; // 本地最多保留的操作步数
  static const int maxPending = 100; // 待上传缓冲上限

  final List<OpLogEntry> _logs = [];
  final List<OpLogEntry> _pending = [];
  bool _loaded = false;
  bool _uploading = false;
  bool _syncEnabled = true;
  String? _deviceId;
  String? _lastSyncError;
  int? _lastSyncedAt;
  Future<void> _persistTail = Future<void>.value();
  bool _persistScheduled = false;
  Future<void>? _initFuture;
  SharedPreferences? _preferences;

  /// 本地日志（新→旧），供日志页展示
  List<OpLogEntry> get logs => List.unmodifiable(_logs.reversed);

  bool get syncing => _uploading;
  bool get syncEnabled => _syncEnabled;
  String? get lastSyncError => _lastSyncError;
  int? get lastSyncedAt => _lastSyncedAt;
  int get pendingCount => _pending.length;

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initInternal();
    _initFuture = future;
    future.then<void>(
      (_) {
        if (identical(_initFuture, future)) _initFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_initFuture, future)) _initFuture = null;
      },
    );
    return future;
  }

  Future<void> _initInternal() async {
    final sp = await SharedPreferences.getInstance();
    if (_preferences != null && !identical(_preferences, sp)) {
      // 测试存储被替换、或宿主切换了偏好后端时，旧实例上的未完成写入
      // 不能继续阻塞新实例；同时重新从新实例加载本地日志。
      _persistScheduled = false;
      _persistTail = Future<void>.value();
      _logs.clear();
      _pending.clear();
      _loaded = false;
    }
    _preferences = sp;
    _syncEnabled = sp.getBool(_kSyncEnabled) ?? true;
    // 使用随机安装 ID，不读取 Android ID 等稳定硬件标识；重装后重新生成，
    // 降低跨应用、跨生命周期追踪风险。服务端只把它作为当前安装的关联句柄。
    final cached = sp.getString(_kDeviceId);
    _deviceId = cached ?? _generateRandomId();
    await sp.setString(_kDeviceId, _deviceId!);
    if (!_loaded) {
      final raw = sp.getString(_kLogs);
      if (raw != null) {
        try {
          final list = jsonDecode(raw) as List;
          _logs.addAll(
            list.map((e) => OpLogEntry.fromJson(e as Map<String, dynamic>)),
          );
        } catch (_) {}
      }
      _loaded = true;
    }
  }

  /// 设备唯一标识（首次生成后持久化），服务器据此区分设备
  Future<String> get deviceId async {
    if (_deviceId == null) await init();
    return _deviceId!;
  }

  /// 记录一步操作日志；本地始终保留，是否进待上传缓冲取决于同步开关
  void record(
    String opId,
    String stage,
    String msg, {
    String level = 'info',
    Map<String, dynamic>? data,
    bool sync = true,
  }) {
    _logs.add(
      OpLogEntry(
        ts: DateTime.now().millisecondsSinceEpoch,
        opId: opId,
        stage: stage,
        level: level,
        msg: _redact(msg),
        data: _safeData(data),
      ),
    );
    if (_logs.length > maxLocal) _logs.removeRange(0, _logs.length - maxLocal);
    if (_syncEnabled && sync) {
      _pending.add(_logs.last);
      if (_pending.length > maxPending) _pending.removeAt(0);
    }
    // record() 由多个异步业务链路 fire-and-forget 调用。短窗口合并快照，
    // 避免每一步都序列化并写入完整日志列表；真正写入仍串行化，防止
    // SharedPreferences 的完成顺序反转导致较旧日志覆盖较新日志。
    _schedulePersist();
  }

  /// 操作日志会在用户可见的日志页展示，也可能上传到服务端；不把语音原文、
  /// 问答正文或随手记正文写入诊断链路。保留长度和摘要足够定位同一请求。
  Map<String, dynamic>? _safeData(Map<String, dynamic>? data) {
    if (data == null) return null;
    final safe = <String, dynamic>{};
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      final normalizedKey = key
          .replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]}')
          .toLowerCase();
      final sensitive = RegExp(
        r'(^|_)(text|content|message|raw|token|authorization|access_token|password|secret|error|stack)(_|$)',
      ).hasMatch(normalizedKey);
      if (sensitive && value is String) {
        safe['${key}_length'] = value.length;
        safe['${key}_sha256'] = sha256.convert(utf8.encode(value)).toString();
      } else if (sensitive) {
        safe[key] = '[REDACTED]';
      } else if (value is Map) {
        safe[key] = _safeData(Map<String, dynamic>.from(value));
      } else if (value is List) {
        safe[key] = value
            .map((item) {
              if (item is Map) {
                return _safeData(Map<String, dynamic>.from(item));
              }
              if (item is String) return _redact(item);
              return item;
            })
            .toList(growable: false);
      } else if (value is String) {
        safe[key] = _redact(value);
      } else {
        safe[key] = value;
      }
    }
    return safe;
  }

  static String _redact(String value) {
    var clean = value;
    clean = clean.replaceAllMapped(
      RegExp(
        r'(api[_-]?token|authorization|access[_-]?token|password|secret)(\s*[:=]\s*)(?:bearer\s+)?[^\s,;]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
    );
    return clean.replaceAll(
      RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
  }

  /// 设置同步开关：关闭时丢弃待上传缓冲（本地日志保留）
  Future<void> setSyncEnabled(bool enabled) async {
    _syncEnabled = enabled;
    if (!enabled) _pending.clear();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kSyncEnabled, enabled);
  }

  /// 批量上传待上传缓冲到服务器；失败保留缓冲，下次再试
  Future<void> flush({ApiClient? api}) async {
    if (_uploading || _pending.isEmpty || api == null || !_syncEnabled) return;
    _uploading = true;
    try {
      final batch = List<OpLogEntry>.of(_pending);
      await api.sendLogs(batch.map((e) => e.toJson()).toList());
      // 上传期间可能有新日志进入 pending；只移除已确认的快照，不能
      // 用 clear() 把并发产生的日志一起丢掉。
      for (final entry in batch) {
        _pending.remove(entry);
      }
      _lastSyncedAt = DateTime.now().millisecondsSinceEpoch;
      _lastSyncError = null;
    } catch (e) {
      _lastSyncError = '$e';
    } finally {
      _uploading = false;
    }
  }

  /// 清空本地日志（含待上传缓冲）
  Future<void> clearLocal() async {
    _logs.clear();
    _pending.clear();
    await _persist();
  }

  /// 在退出单位、进入后台或测试收口前立即写入当前快照。
  Future<void> flushLocal() async {
    await _persist();
  }

  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    // 同一事件循环内的连续 record 调用只合并成一次序列化；使用微任务而非
    // 延迟定时器，避免页面/控制器销毁后留下未收口的后台定时器。
    scheduleMicrotask(() {
      _persistScheduled = false;
      unawaited(_persist());
    });
  }

  Future<void> _persist() {
    // 在排队时捕获不可变快照；否则前一个任务开始执行前，后续 clear/record
    // 会改变 _logs，最终无法保证队列顺序对应调用顺序。
    final encoded = jsonEncode(_logs.map((e) => e.toJson()).toList());
    final preferences = _preferences;
    final next = _persistTail.then<void>((_) async {
      try {
        final sp = preferences ?? await SharedPreferences.getInstance();
        await sp.setString(_kLogs, encoded);
      } catch (_) {}
    });
    _persistTail = next.catchError((Object _) {});
    return next;
  }

  String _generateRandomId() {
    final r = Random.secure();
    final hex = List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'dev-$hex';
  }
}
