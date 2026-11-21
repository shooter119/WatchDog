class Entry {
  final int version;
  final String id;
  final String name;
  final double? pressureMpa;
  final int durationMin;
  final int entryAt;
  final int exitAt;
  final int? exitedAt;
  final String source;
  final String? rawText;

  /// 创建该条记录时使用的气瓶容量与消耗率；旧服务端记录为空时回退全局配置。
  final double? cylinderVolL;
  final double? consumptionLpm;

  /// 实测耗气率 L/min（由两次压力报数差分得出，无采样时为 null）
  final double? consumptionActualLpm;

  Entry({
    this.version = 1,
    required this.id,
    required this.name,
    this.pressureMpa,
    required this.durationMin,
    required this.entryAt,
    required this.exitAt,
    this.exitedAt,
    required this.source,
    this.rawText,
    this.cylinderVolL,
    this.consumptionLpm,
    this.consumptionActualLpm,
  });

  Entry copyWith({
    int? version,
    int? exitedAt,
    double? pressureMpa,
    int? durationMin,
    int? exitAt,
    double? cylinderVolL,
    double? consumptionLpm,
  }) => Entry(
    version: version ?? this.version,
    id: id,
    name: name,
    pressureMpa: pressureMpa ?? this.pressureMpa,
    durationMin: durationMin ?? this.durationMin,
    entryAt: entryAt,
    exitAt: exitAt ?? this.exitAt,
    exitedAt: exitedAt ?? this.exitedAt,
    source: source,
    rawText: rawText,
    cylinderVolL: cylinderVolL ?? this.cylinderVolL,
    consumptionLpm: consumptionLpm ?? this.consumptionLpm,
    consumptionActualLpm: consumptionActualLpm,
  );

  bool get isActive => exitedAt == null;

  int get remainingMs {
    if (!isActive) return 0;
    return exitAt - DateTime.now().millisecondsSinceEpoch;
  }

  /// 状态: normal(>10min) / warn(<=10min) / alarm(<=5min) / timeout(<0)
  String statusAt({required int warnMin, required int alarmMin}) {
    final ms = remainingMs;
    final warn = warnMin * 60000;
    final alarm = alarmMin * 60000;
    if (ms < 0) return 'timeout';
    if (ms <= alarm) return 'alarm';
    if (ms <= warn) return 'warn';
    return 'normal';
  }

  factory Entry.fromJson(Map<String, dynamic> json) => Entry(
    version: (json['version'] as num?)?.toInt() ?? 1,
    id: json['id'] as String,
    name: json['name'] as String,
    pressureMpa: (json['pressure_mpa'] as num?)?.toDouble(),
    durationMin: (json['duration_min'] as num?)?.toInt() ?? 0,
    entryAt: (json['entry_at'] as num).toInt(),
    exitAt: (json['exit_at'] as num).toInt(),
    exitedAt: (json['exited_at'] as num?)?.toInt(),
    source: (json['source'] as String?) ?? 'voice',
    rawText: json['raw_text'] as String?,
    cylinderVolL: (json['cylinder_vol_l'] as num?)?.toDouble(),
    consumptionLpm: (json['consumption_lpm'] as num?)?.toDouble(),
    consumptionActualLpm: (json['consumption_actual_lpm'] as num?)?.toDouble(),
  );
}
