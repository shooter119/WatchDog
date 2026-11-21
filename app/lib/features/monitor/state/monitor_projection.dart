import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/models/calc_config.dart';
import '../data/models/entry.dart';

/// 现场监控风险汇总快照（不可变值对象）。
@immutable
class MonitorRiskSummary {
  const MonitorRiskSummary({
    required this.totalActive,
    required this.timeoutCount,
    required this.alarmCount,
    required this.cautionCount,
    required this.safeCount,
    required this.earliestEntry,
    required this.worstStatus,
  });

  final int totalActive;
  final int timeoutCount;
  final int alarmCount;
  final int cautionCount;
  final int safeCount;
  final Entry? earliestEntry;
  final String worstStatus;

  int get dangerCount => timeoutCount + alarmCount + cautionCount;
}

/// 危险等级优先级：超时(0) > 告警(1) > 注意(2) > 安全(3)。
int monitorSeverityOf(String status) => switch (status) {
  'timeout' => 0,
  'alarm' => 1,
  'warn' => 2,
  _ => 3,
};

/// 计算指定时刻下的人员状态（`timeout` / `alarm` / `warn` / `normal`）。
String monitorStatusOf(Entry entry, CalcConfig config, {int? nowMs}) {
  if (nowMs == null) {
    return entry.statusAt(warnMin: config.warnMin, alarmMin: config.alarmMin);
  }
  final remaining = entry.isActive ? entry.exitAt - nowMs : 0;
  if (remaining < 0) return 'timeout';
  if (remaining <= config.alarmMin * 60000) return 'alarm';
  if (remaining <= config.warnMin * 60000) return 'warn';
  return 'normal';
}

/// 格式化压力读数（整数去 `.0`，小数保留 1 位）。
String formatMonitorPressure(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

/// 统计当前在场人员的风险计数分布与最早到期人员。
MonitorRiskSummary computeMonitorRiskSummary({
  required Iterable<Entry> entries,
  required CalcConfig calcConfig,
  required int nowMs,
}) {
  var timeoutCount = 0;
  var alarmCount = 0;
  var cautionCount = 0;
  var safeCount = 0;
  Entry? earliest;
  var worst = 'normal';

  for (final e in entries.where((item) => item.isActive)) {
    final s = monitorStatusOf(e, calcConfig, nowMs: nowMs);
    switch (s) {
      case 'timeout':
        timeoutCount++;
      case 'alarm':
        alarmCount++;
      case 'warn':
        cautionCount++;
      default:
        safeCount++;
    }
    if (monitorSeverityOf(s) < monitorSeverityOf(worst)) worst = s;
    if (earliest == null || e.exitAt < earliest.exitAt) earliest = e;
  }

  return MonitorRiskSummary(
    totalActive: timeoutCount + alarmCount + cautionCount + safeCount,
    timeoutCount: timeoutCount,
    alarmCount: alarmCount,
    cautionCount: cautionCount,
    safeCount: safeCount,
    earliestEntry: earliest,
    worstStatus: worst,
  );
}

/// 将仍在本地待补传的人员操作（`entry` / `pressure` / `exit`）投影叠加到服务端快照。
/// 返回新列表，不修改传入集合，便于同步逻辑与回归测试复用。
List<Entry> projectOfflineMonitorOperations({
  required Iterable<Map<String, Object?>> rows,
  required List<Entry> entries,
  required CalcConfig calcConfig,
}) {
  var projected = List<Entry>.of(entries);
  for (final row in rows) {
    try {
      final rawPayload = row['payload'];
      if (rawPayload is! String) continue;
      final decoded = jsonDecode(rawPayload);
      if (decoded is! Map) continue;
      final payload = Map<String, dynamic>.from(decoded);
      final occurredAt = (row['occurred_at'] as num?)?.toInt() ?? 0;
      if (occurredAt <= 0) continue;

      switch (row['type']?.toString()) {
        case 'entry':
          final id = payload['entry_id']?.toString();
          final name = payload['name']?.toString();
          final pressure = _parseNumber(payload['pressure_mpa']);
          if (id == null ||
              id.isEmpty ||
              name == null ||
              name.isEmpty ||
              pressure == null ||
              pressure <= 0) {
            continue;
          }
          final vol =
              _parseNumber(payload['volume_l']) ?? calcConfig.cylinderVolL;
          final cons =
              _parseNumber(payload['consumption_lpm']) ??
              calcConfig.consumptionLpm;
          final dur = calcConfig
              .durationMinFor(
                pressure,
                cylinderVolL: vol,
                consumptionLpm: cons,
              )
              .round();
          final entry = Entry(
            id: id,
            name: name,
            pressureMpa: pressure,
            durationMin: dur,
            entryAt: occurredAt,
            exitAt: occurredAt + dur * 60000,
            source: 'offline',
            rawText: payload['raw_text']?.toString(),
            cylinderVolL: vol,
            consumptionLpm: cons,
          );
          projected = [entry, ...projected.where((item) => item.id != id)];
        case 'pressure':
          final id = payload['entry_id']?.toString();
          final pressure = _parseNumber(payload['pressure_mpa']);
          if (id == null || id.isEmpty || pressure == null || pressure <= 0) {
            continue;
          }
          final index = projected.indexWhere((item) => item.id == id);
          if (index < 0) continue;
          final cur = projected[index];
          final vol =
              _parseNumber(payload['volume_l']) ??
              cur.cylinderVolL ??
              calcConfig.cylinderVolL;
          final cons =
              _parseNumber(payload['consumption_lpm']) ??
              cur.consumptionLpm ??
              calcConfig.consumptionLpm;
          final dur = calcConfig
              .durationMinFor(
                pressure,
                cylinderVolL: vol,
                consumptionLpm: cons,
              )
              .round();
          projected = [
            for (final item in projected)
              item.id == id
                  ? item.copyWith(
                      pressureMpa: pressure,
                      durationMin: dur,
                      exitAt: occurredAt + dur * 60000,
                      cylinderVolL: vol,
                      consumptionLpm: cons,
                    )
                  : item,
          ];
        case 'exit':
          final id = payload['entry_id']?.toString();
          if (id == null || id.isEmpty) continue;
          projected = [
            for (final item in projected)
              item.id == id ? item.copyWith(exitedAt: occurredAt) : item,
          ];
      }
    } catch (_) {
      // 单条损坏记录不阻断其余合法离线操作投影。
    }
  }
  return projected;
}

double? _parseNumber(Object? value) =>
    value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
