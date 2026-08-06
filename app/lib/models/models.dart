class Entry {
  final String id;
  final String name;
  final double? pressureMpa;
  final int durationMin;
  final int entryAt;
  final int exitAt;
  final int? exitedAt;
  final String source;
  final String? rawText;
  /// 实测耗气率 L/min（由两次压力报数差分得出，无采样时为 null）
  final double? consumptionActualLpm;

  Entry({
    required this.id,
    required this.name,
    this.pressureMpa,
    required this.durationMin,
    required this.entryAt,
    required this.exitAt,
    this.exitedAt,
    required this.source,
    this.rawText,
    this.consumptionActualLpm,
  });

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
        id: json['id'] as String,
        name: json['name'] as String,
        pressureMpa: (json['pressure_mpa'] as num?)?.toDouble(),
        durationMin: (json['duration_min'] as num?)?.toInt() ?? 0,
        entryAt: (json['entry_at'] as num).toInt(),
        exitAt: (json['exit_at'] as num).toInt(),
        exitedAt: (json['exited_at'] as num?)?.toInt(),
        source: (json['source'] as String?) ?? 'voice',
        rawText: json['raw_text'] as String?,
        consumptionActualLpm: (json['consumption_actual_lpm'] as num?)?.toDouble(),
      );
}

class Firefighter {
  final String id;
  final String name;
  Firefighter({required this.id, required this.name});
  factory Firefighter.fromJson(Map<String, dynamic> json) =>
      Firefighter(id: json['id'] as String, name: json['name'] as String);
}

class Hotword {
  final String id;
  final String word;
  Hotword({required this.id, required this.word});
  factory Hotword.fromJson(Map<String, dynamic> json) =>
      Hotword(id: json['id'] as String, word: json['word'] as String);
}

class ParsePerson {
  final String name;
  final double? pressureMpa;

  const ParsePerson({required this.name, this.pressureMpa});

  Map<String, dynamic> toJson() => {
        'name': name,
        if (pressureMpa != null) 'pressure_mpa': pressureMpa,
      };

  factory ParsePerson.fromJson(Map<String, dynamic> json) => ParsePerson(
        name: (json['name'] as String?) ?? '',
        pressureMpa: (json['pressure_mpa'] as num?)?.toDouble(),
      );
}

class ParseResult {
  final String action; // enter / exit / unknown
  final List<ParsePerson> people;
  final String note;

  ParseResult({
    required this.action,
    required this.people,
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
        'action': action,
        'people': people.map((p) => p.toJson()).toList(),
        'note': note,
      };

  ParseResult.single({
    required this.action,
    String? name,
    double? pressureMpa,
    this.note = '',
  }) : people = [
          if (name != null && name.trim().isNotEmpty)
            ParsePerson(name: name, pressureMpa: pressureMpa),
        ];

  factory ParseResult.fromJson(Map<String, dynamic> json) {
    final rawPeople = json['people'] as List?;
    final people = <ParsePerson>[];
    if (rawPeople != null) {
      for (final p in rawPeople) {
        final person = ParsePerson.fromJson(p as Map<String, dynamic>);
        if (person.name.trim().isNotEmpty) people.add(person);
      }
    } else {
      // 兼容旧格式（单人的 name/pressure_mpa 字段）
      final name = (json['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) {
        people.add(ParsePerson(name: name, pressureMpa: (json['pressure_mpa'] as num?)?.toDouble()));
      }
    }
    return ParseResult(
      action: (json['action'] as String?) ?? 'unknown',
      people: people,
      note: (json['note'] as String?) ?? '',
    );
  }
}

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
        consumptionLpm: ((json['calc']?['consumptionLpm']) ?? 40).toDouble(),
        warnMin: ((json['calc']?['warnMin']) ?? 10).toInt(),
        alarmMin: ((json['calc']?['alarmMin']) ?? 5).toInt(),
      );

  /// 可用时间（分钟） = 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  /// [cylinderVolL] 可指定单人气瓶容量（默认全局配置）
  double durationMinFor(double pressureMpa, {double? cylinderVolL}) =>
      (cylinderVolL ?? this.cylinderVolL) * pressureMpa * 10 / consumptionLpm;
}
