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

/// 语音输入意图（App 依据它路由到对应界面）
/// entry/exit → 警情处置页确认登记；note → 记入火场日志并跳日志页；
/// ask → 跳智能体问答页并发送；ignore → 环境音，丢弃并提示重新录入
class VoiceIntent {
  static const String entry = 'entry';
  static const String exit = 'exit';
  static const String note = 'note';
  static const String ask = 'ask';
  static const String ignore = 'ignore';

  static const List<String> all = [entry, exit, note, ask, ignore];

  static String normalize(String? v) => all.contains(v) ? v! : note;
}

class ParseResult {
  final String intent; // entry / exit / note / ask / ignore
  final String action; // enter / exit / unknown
  final List<ParsePerson> people;
  final String note;

  ParseResult({
    required this.action,
    required this.people,
    this.note = '',
    String? intent,
  }) : intent = intent != null && VoiceIntent.all.contains(intent)
           ? intent
           : _inferIntent(action, people);

  /// 兼容旧服务端（无 intent 字段）：按 action/people 推导，避免破坏进出场流程
  static String _inferIntent(String action, List<ParsePerson> people) {
    if (action == 'exit') return VoiceIntent.exit;
    if (action == 'enter' && people.isNotEmpty) return VoiceIntent.entry;
    return VoiceIntent.note;
  }

  Map<String, dynamic> toJson() => {
    'intent': intent,
    'action': action,
    'people': people.map((p) => p.toJson()).toList(),
    'note': note,
  };

  ParseResult.single({
    required this.action,
    String? name,
    double? pressureMpa,
    this.note = '',
    String? intent,
  }) : intent = intent != null && VoiceIntent.all.contains(intent)
           ? intent
           : _inferIntent(action, [
               if (name != null && name.trim().isNotEmpty)
                 ParsePerson(name: name, pressureMpa: pressureMpa),
             ]),
       people = [
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
        people.add(
          ParsePerson(
            name: name,
            pressureMpa: (json['pressure_mpa'] as num?)?.toDouble(),
          ),
        );
      }
    }
    return ParseResult(
      intent: (json['intent'] as String?) ?? '',
      action: (json['action'] as String?) ?? 'unknown',
      people: people,
      note: (json['note'] as String?) ?? '',
    );
  }
}
