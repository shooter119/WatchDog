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

/// 火场随手记分类（与后端白名单一致）
/// 依据消防实战作战环节设计：接警出动→火情侦察→警戒→战斗展开→
/// 救人搜救/疏散→灭火(控制/堵截/强攻/总攻/合围)→破拆→排烟→供水→消除残火→战斗结束
class NoteCategory {
  static const String deploy = '部署';
  static const String rescue = '搜救';
  static const String water = '出水';
  static const String withdraw = '撤离';
  static const String abnormal = '异常';
  static const String other = '其他';

  static const List<String> all = [deploy, rescue, water, withdraw, abnormal, other];

  /// 颜色映射由主题层负责（app_theme.dart），此处仅定义分类
  /// 关键词按"异常>撤离>出水>搜救>部署"优先级匹配，先命中先归类
  static String fromText(String text) {
    final t = text.trim();
    // 异常（险情与危险事件，优先）
    if (t.contains('爆炸') || t.contains('爆燃') || t.contains('闪燃') || t.contains('轰燃') ||
        t.contains('回燃') || t.contains('复燃') || t.contains('阴燃') || t.contains('倒塌') ||
        t.contains('坍塌') || t.contains('泄漏') || t.contains('中毒') || t.contains('窒息') ||
        t.contains('触电') || t.contains('受伤') || t.contains('伤亡') || t.contains('坠落') ||
        t.contains('失控') || t.contains('蔓延') || t.contains('飞火') || t.contains('流淌火') ||
        t.contains('险情') || t.contains('异常') || t.contains('爆裂') || t.contains('带电') ||
        t.contains('坍塌危险')) {
      return abnormal;
    }
    // 撤离（战斗结束与收尾）
    if (t.contains('撤离') || t.contains('撤出') || t.contains('撤退') || t.contains('收队') ||
        t.contains('归队') || t.contains('收工') || t.contains('回撤') || t.contains('收操') ||
        t.contains('撤收') || t.contains('清理') || t.contains('残火') || t.contains('监护') ||
        t.contains('留守') || t.contains('移交') || t.contains('交接') || t.contains('结束') ||
        t.contains('收尾') || t.contains('战评') || t.contains('总结')) {
      return withdraw;
    }
    // 出水（射水灭火与控制火势）
    if (t.contains('出水') || t.contains('供水') || t.contains('送水') || t.contains('中继') ||
        t.contains('水带') || t.contains('水枪') || t.contains('水炮') || t.contains('泡沫') ||
        t.contains('干粉') || t.contains('灭火') || t.contains('扑灭') || t.contains('扑救') ||
        t.contains('冷却') || t.contains('降温') || t.contains('堵截') || t.contains('夹攻') ||
        t.contains('强攻') || t.contains('总攻') || t.contains('合围') || t.contains('突破') ||
        t.contains('掩护') || t.contains('控制火势') || t.contains('压制') || t.contains('水幕') ||
        t.contains('火势控制')) {
      return water;
    }
    // 搜救（救人、侦察、破拆排烟等救援作业）
    if (t.contains('搜救') || t.contains('搜寻') || t.contains('搜索') || t.contains('侦查') ||
        t.contains('侦察') || t.contains('侦检') || t.contains('探测') || t.contains('被困') ||
        t.contains('遇险') || t.contains('失联') || t.contains('救人') || t.contains('疏散') ||
        t.contains('转移') || t.contains('救出') || t.contains('抬出') || t.contains('登高') ||
        t.contains('破拆') || t.contains('排烟') || t.contains('通风') || t.contains('内攻') ||
        t.contains('开辟通道') || t.contains('查找火源')) {
      return rescue;
    }
    // 部署（接警出动、力量调度与战斗展开）
    if (        t.contains('出动') || t.contains('接警') || t.contains('调派') || t.contains('调度') ||
        t.contains('增援') || t.contains('到场') || t.contains('到达') || t.contains('进入') ||
        t.contains('集结') || t.contains('部署') || t.contains('展开') || t.contains('阵地') ||
        t.contains('警戒') || t.contains('封锁') || t.contains('隔离') || t.contains('指挥部') ||
        t.contains('集结点') || t.contains('战备') || t.contains('待命') || t.contains('保障') ||
        t.contains('协同') || t.contains('力量') || t.contains('指挥')) {
      return deploy;
    }
    return other;
  }
}

/// 火场随手记条目：语音/手动记录的时间节点，供复盘
class Note {
  final String id;
  final String text;
  final String category;
  final int createdAt;
  final int updatedAt;

  const Note({
    required this.id,
    required this.text,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        text: (json['text'] as String?) ?? '',
        category: (json['category'] as String?) ?? NoteCategory.other,
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
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

/// 语音输入意图（App 依据它路由到对应界面）
/// entry/exit → 语音页确认登记；note → 记入火场日志并跳日志页；
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
  })  : intent = intent != null && VoiceIntent.all.contains(intent)
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
        people.add(ParsePerson(name: name, pressureMpa: (json['pressure_mpa'] as num?)?.toDouble()));
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

/// 场景结束状态：本场景已被某设备结束任务（归档），携带服务端统一分配的新场景码
class SceneState {
  final int endedAt;
  final String? endedBy;
  final String? newScene;

  const SceneState({required this.endedAt, this.endedBy, this.newScene});
}

/// 智能体问答消息（user 提问 / assistant 回复）
class ChatMessage {  final String id;
  final String role; // user / assistant
  final String content;
  final int createdAt;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        role: (json['role'] as String?) ?? 'user',
        content: (json['content'] as String?) ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      );
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
