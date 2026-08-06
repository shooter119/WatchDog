import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
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
        data: json['data'] is Map<String, dynamic> ? json['data'] as Map<String, dynamic> : null,
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

  /// 本地日志（新→旧），供日志页展示
  List<OpLogEntry> get logs => List.unmodifiable(_logs.reversed);

  bool get syncing => _uploading;
  bool get syncEnabled => _syncEnabled;
  String? get lastSyncError => _lastSyncError;
  int? get lastSyncedAt => _lastSyncedAt;
  int get pendingCount => _pending.length;

  Future<void> init() async {
    final sp = await SharedPreferences.getInstance();
    _syncEnabled = sp.getBool(_kSyncEnabled) ?? true;
    // 用户识别码：优先 Android ID 加盐哈希（重装不变）；拿不到时回退已存/随机 ID
    final cached = sp.getString(_kDeviceId);
    _deviceId = (await _deviceIdFromAndroid()) ?? cached ?? _generateRandomId();
    if (_deviceId != null) await sp.setString(_kDeviceId, _deviceId!);
    if (!_loaded) {
      final raw = sp.getString(_kLogs);
      if (raw != null) {
        try {
          final list = jsonDecode(raw) as List;
          _logs.addAll(list.map((e) => OpLogEntry.fromJson(e as Map<String, dynamic>)));
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
  void record(String opId, String stage, String msg, {String level = 'info', Map<String, dynamic>? data}) {
    _logs.add(OpLogEntry(ts: DateTime.now().millisecondsSinceEpoch, opId: opId, stage: stage, level: level, msg: msg, data: data));
    if (_logs.length > maxLocal) _logs.removeRange(0, _logs.length - maxLocal);
    if (_syncEnabled) {
      _pending.add(_logs.last);
      if (_pending.length > maxPending) _pending.removeAt(0);
    }
    _persist();
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
      await api.sendLogs(_pending.map((e) => e.toJson()).toList());
      _pending.clear();
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

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLogs, jsonEncode(_logs.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// 用户识别码：ANDROID_ID（SSAID，零权限、同一签名下重装不变）加盐哈希
  /// 哈希后不可反推原始 ID；拿不到（异常/非 Android）时返回 null
  Future<String?> _deviceIdFromAndroid() async {
    if (!Platform.isAndroid) return null;
    try {
      const channel = MethodChannel('watchdog/screen');
      final androidId =
          await channel.invokeMethod<String>('androidId').timeout(const Duration(seconds: 2));
      if (androidId == null || androidId.isEmpty) return null;
      final digest = sha256.convert(utf8.encode('watchdog-user-v1:$androidId'));
      return 'dev-${digest.toString()}';
    } catch (_) {
      return null;
    }
  }

  String _generateRandomId() {
    final r = Random.secure();
    final hex = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'dev-$hex';
  }
}
