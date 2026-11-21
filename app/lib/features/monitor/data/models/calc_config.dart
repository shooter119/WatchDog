class CalcConfig {
  final double cylinderVolL;
  final double fullPressureMpa;
  final double consumptionLpm;
  final int warnMin;
  final int alarmMin;

  CalcConfig({
    required this.cylinderVolL,
    required this.fullPressureMpa,
    required this.consumptionLpm,
    required this.warnMin,
    required this.alarmMin,
  });

  factory CalcConfig.fromJson(Map<String, dynamic> json) => CalcConfig(
    cylinderVolL: ((json['calc']?['cylinderVolL']) ?? 6.8).toDouble(),
    fullPressureMpa: ((json['calc']?['fullPressureMpa']) ?? 30).toDouble(),
    consumptionLpm: ((json['calc']?['consumptionLpm']) ?? 80).toDouble(),
    warnMin: ((json['calc']?['warnMin']) ?? 10).toInt(),
    alarmMin: ((json['calc']?['alarmMin']) ?? 5).toInt(),
  );

  /// 可用时间（分钟） = 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  /// [cylinderVolL] 可指定单人气瓶容量（默认全局配置）
  double durationMinFor(
    double pressureMpa, {
    double? cylinderVolL,
    double? consumptionLpm,
  }) =>
      (cylinderVolL ?? this.cylinderVolL) *
      pressureMpa *
      10 /
      (consumptionLpm ?? this.consumptionLpm);
}
