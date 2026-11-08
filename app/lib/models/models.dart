import 'key_sites.dart';

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

class Incident {
  final IncidentKeySiteLink? keySiteLink;
  final int keySiteLinkRevision;
  final String id;
  final Map<String, dynamic> info;
  final String number;
  final String? title;
  final String? suggestedTitle;
  final String status;
  final int createdAt;
  final int lastActivityAt;
  final int? archivedAt;
  final String? archivedBy;
  final bool autoArchived;
  final int unresolvedActiveCount;
  final int version;
  final int forceStationCount;
  final int vehicleCount;
  final int personnelCount;
  final int unknownVehicleStationCount;
  final int unknownPersonnelStationCount;

  const Incident({
    this.keySiteLink,
    this.keySiteLinkRevision = 0,
    required this.id,
    this.info = const {},
    required this.number,
    this.title,
    this.suggestedTitle,
    required this.status,
    required this.createdAt,
    required this.lastActivityAt,
    this.archivedAt,
    this.archivedBy,
    this.autoArchived = false,
    this.unresolvedActiveCount = 0,
    this.version = 1,
    this.forceStationCount = 0,
    this.vehicleCount = 0,
    this.personnelCount = 0,
    this.unknownVehicleStationCount = 0,
    this.unknownPersonnelStationCount = 0,
  });

  String get displayName =>
      (title ?? '').trim().isEmpty ? number : title!.trim();
  bool get isActive => status == 'active';

  factory Incident.fromJson(Map<String, dynamic> json) => Incident(
    keySiteLink: json['key_site_link'] is Map
        ? IncidentKeySiteLink.fromJson(
            Map<String, dynamic>.from(json['key_site_link'] as Map),
          )
        : null,
    keySiteLinkRevision: (json['key_site_link_revision'] as num?)?.toInt() ?? 0,
    id: json['id']?.toString() ?? '',
    info: json['info'] is Map
        ? Map<String, dynamic>.from(json['info'] as Map)
        : const {},
    number: json['number']?.toString() ?? '',
    title: json['title']?.toString(),
    suggestedTitle: json['suggested_title']?.toString(),
    status: json['status']?.toString() ?? 'active',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    lastActivityAt: (json['last_activity_at'] as num?)?.toInt() ?? 0,
    archivedAt: (json['archived_at'] as num?)?.toInt(),
    archivedBy: json['archived_by']?.toString(),
    autoArchived: json['auto_archived'] == true || json['auto_archived'] == 1,
    unresolvedActiveCount:
        (json['unresolved_active_count'] as num?)?.toInt() ?? 0,
    version: (json['version'] as num?)?.toInt() ?? 1,
    forceStationCount: (json['force_station_count'] as num?)?.toInt() ?? 0,
    unknownVehicleStationCount:
        (json['unknown_vehicle_station_count'] as num?)?.toInt() ?? 0,
    unknownPersonnelStationCount:
        (json['unknown_personnel_station_count'] as num?)?.toInt() ?? 0,
    vehicleCount: json['vehicle_count'] as int? ?? 0,
    personnelCount: json['personnel_count'] as int? ?? 0,
  );
}

class ExternalIncident {
  final String externalId;
  final String incidentNumber;
  final String detachmentName;
  final String brigadeName;
  final String squadronName;
  final String districtName;
  final String incidentType;
  final String disposalObjectName;
  final String incidentLevel;
  final String incidentStatus;
  final String crimeAddress;
  final String incidentDescribe;
  final int registerTime;
  final String? latitude;
  final String? longitude;
  final bool claimed;
  final String? claimedIncidentId;
  final String? claimedIncidentNumber;
  final String? claimedIncidentTitle;

  const ExternalIncident({
    required this.externalId,
    required this.incidentNumber,
    this.detachmentName = '',
    this.brigadeName = '',
    this.squadronName = '',
    this.districtName = '',
    this.incidentType = '其他',
    this.disposalObjectName = '',
    this.incidentLevel = '',
    this.incidentStatus = '',
    required this.crimeAddress,
    this.incidentDescribe = '',
    required this.registerTime,
    this.latitude,
    this.longitude,
    this.claimed = false,
    this.claimedIncidentId,
    this.claimedIncidentNumber,
    this.claimedIncidentTitle,
  });

  String get situationSummary {
    if (incidentDescribe.trim().isNotEmpty) return incidentDescribe.trim();
    if (disposalObjectName.isNotEmpty && disposalObjectName != '其他') {
      return '$incidentType($disposalObjectName)';
    }
    return incidentType;
  }

  factory ExternalIncident.fromJson(Map<String, dynamic> json) => ExternalIncident(
    externalId: json['external_id']?.toString() ?? '',
    incidentNumber: json['incident_number']?.toString() ?? '',
    detachmentName: json['detachment_name']?.toString() ?? '',
    brigadeName: json['brigade_name']?.toString() ?? '',
    squadronName: json['squadron_name']?.toString() ?? '',
    districtName: json['district_name']?.toString() ?? '',
    incidentType: json['incident_type']?.toString() ?? '其他',
    disposalObjectName: json['disposal_object_name']?.toString() ?? '',
    incidentLevel: json['incident_level']?.toString() ?? '',
    incidentStatus: json['incident_status']?.toString() ?? '',
    crimeAddress: json['crime_address']?.toString() ?? '',
    incidentDescribe: json['incident_describe']?.toString() ?? '',
    registerTime: (json['register_time'] as num?)?.toInt() ?? 0,
    latitude: json['latitude']?.toString(),
    longitude: json['longitude']?.toString(),
    claimed: json['claimed'] == true,
    claimedIncidentId: json['claimed_incident_id']?.toString(),
    claimedIncidentNumber: json['claimed_incident_number']?.toString(),
    claimedIncidentTitle: json['claimed_incident_title']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'external_id': externalId,
    'incident_number': incidentNumber,
    'detachment_name': detachmentName,
    'brigade_name': brigadeName,
    'squadron_name': squadronName,
    'district_name': districtName,
    'incident_type': incidentType,
    'disposal_object_name': disposalObjectName,
    'incident_level': incidentLevel,
    'incident_status': incidentStatus,
    'crime_address': crimeAddress,
    'incident_describe': incidentDescribe,
    'register_time': registerTime,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
    'claimed': claimed,
    if (claimedIncidentId != null) 'claimed_incident_id': claimedIncidentId,
    if (claimedIncidentNumber != null) 'claimed_incident_number': claimedIncidentNumber,
    if (claimedIncidentTitle != null) 'claimed_incident_title': claimedIncidentTitle,
  };
}

class IncidentForce {
  final String id;
  final String incidentId;
  final String? stationId;
  final String? unitStationId;
  final String? deploymentStatus;
  final String? informationSource;
  final String stationName;
  final int vehicleCount;
  final int personnelCount;
  final bool vehicleCountKnown;
  final bool personnelCountKnown;
  final int createdAt;
  final int updatedAt;
  final int version;

  const IncidentForce({
    required this.id,
    required this.incidentId,
    this.stationId,
    this.unitStationId,
    this.deploymentStatus,
    this.informationSource,
    required this.stationName,
    required this.vehicleCount,
    required this.personnelCount,
    this.vehicleCountKnown = true,
    this.personnelCountKnown = true,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
  });

  String get vehicleLabel => vehicleCountKnown ? '$vehicleCount车' : '车辆待补充';
  String get personnelLabel =>
      personnelCountKnown ? '$personnelCount人' : '人数待补充';
  String get quantityLabel => vehicleCountKnown && personnelCountKnown
      ? '$vehicleLabel$personnelLabel'
      : '$vehicleLabel $personnelLabel';

  factory IncidentForce.fromJson(Map<String, dynamic> json) => IncidentForce(
    id: json['id']?.toString() ?? '',
    incidentId: json['incident_id']?.toString() ?? '',
    stationId: json['station_id']?.toString(),
    unitStationId: json['unit_station_id']?.toString(),
    deploymentStatus: json['deployment_status']?.toString(),
    informationSource: json['information_source']?.toString(),
    vehicleCountKnown:
        json['vehicle_count_known'] != false &&
        json['vehicle_count_known'] != 0,
    personnelCountKnown:
        json['personnel_count_known'] != false &&
        json['personnel_count_known'] != 0,
    stationName: json['station_name']?.toString() ?? '',
    vehicleCount: (json['vehicle_count'] as num?)?.toInt() ?? 0,
    personnelCount: (json['personnel_count'] as num?)?.toInt() ?? 0,
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    version: (json['version'] as num?)?.toInt() ?? 1,
  );
}

class Station {
  final String id;
  final String name;
  const Station({required this.id, required this.name});
  factory Station.fromJson(Map<String, dynamic> json) => Station(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
  );
}

class IncidentEvent {
  final String id;
  final String incidentId;
  final String type;
  final int occurredAt;
  final int recordedAt;
  final String? actorName;
  final String source;
  final String? clientOpId;
  final Map<String, dynamic> payload;
  final String? revisionOf;
  final String text;

  const IncidentEvent({
    required this.id,
    required this.incidentId,
    required this.type,
    required this.occurredAt,
    required this.recordedAt,
    this.actorName,
    required this.source,
    this.clientOpId,
    this.payload = const {},
    this.revisionOf,
    required this.text,
  });

  factory IncidentEvent.fromJson(Map<String, dynamic> json) => IncidentEvent(
    id: json['id']?.toString() ?? '',
    incidentId: json['incident_id']?.toString() ?? '',
    type: json['type']?.toString() ?? '',
    occurredAt: (json['occurred_at'] as num?)?.toInt() ?? 0,
    recordedAt: (json['recorded_at'] as num?)?.toInt() ?? 0,
    actorName: json['actor_name']?.toString(),
    source: json['source']?.toString() ?? 'online',
    clientOpId: json['client_op_id']?.toString(),
    payload: json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : const {},
    revisionOf: json['revision_of']?.toString(),
    text: json['text']?.toString() ?? '',
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

  static const List<String> all = [
    deploy,
    rescue,
    water,
    withdraw,
    abnormal,
    other,
  ];

  /// 颜色映射由主题层负责（app_theme.dart），此处仅定义分类
  /// 关键词按"异常>撤离>出水>搜救>部署"优先级匹配，先命中先归类
  static String fromText(String text) {
    final t = text.trim();
    // 异常（险情与危险事件，优先）
    if (t.contains('爆炸') ||
        t.contains('爆燃') ||
        t.contains('闪燃') ||
        t.contains('轰燃') ||
        t.contains('回燃') ||
        t.contains('复燃') ||
        t.contains('阴燃') ||
        t.contains('倒塌') ||
        t.contains('坍塌') ||
        t.contains('泄漏') ||
        t.contains('中毒') ||
        t.contains('窒息') ||
        t.contains('触电') ||
        t.contains('受伤') ||
        t.contains('伤亡') ||
        t.contains('坠落') ||
        t.contains('失控') ||
        t.contains('蔓延') ||
        t.contains('飞火') ||
        t.contains('流淌火') ||
        t.contains('险情') ||
        t.contains('异常') ||
        t.contains('爆裂') ||
        t.contains('带电') ||
        t.contains('坍塌危险')) {
      return abnormal;
    }
    // 撤离（战斗结束与收尾）
    if (t.contains('撤离') ||
        t.contains('撤出') ||
        t.contains('撤退') ||
        t.contains('收队') ||
        t.contains('归队') ||
        t.contains('收工') ||
        t.contains('回撤') ||
        t.contains('收操') ||
        t.contains('撤收') ||
        t.contains('清理') ||
        t.contains('残火') ||
        t.contains('监护') ||
        t.contains('留守') ||
        t.contains('移交') ||
        t.contains('交接') ||
        t.contains('结束') ||
        t.contains('收尾') ||
        t.contains('战评') ||
        t.contains('总结')) {
      return withdraw;
    }
    // 出水（射水灭火与控制火势）
    if (t.contains('出水') ||
        t.contains('供水') ||
        t.contains('送水') ||
        t.contains('中继') ||
        t.contains('水带') ||
        t.contains('水枪') ||
        t.contains('水炮') ||
        t.contains('泡沫') ||
        t.contains('干粉') ||
        t.contains('灭火') ||
        t.contains('扑灭') ||
        t.contains('扑救') ||
        t.contains('冷却') ||
        t.contains('降温') ||
        t.contains('堵截') ||
        t.contains('夹攻') ||
        t.contains('强攻') ||
        t.contains('总攻') ||
        t.contains('合围') ||
        t.contains('突破') ||
        t.contains('掩护') ||
        t.contains('控制火势') ||
        t.contains('压制') ||
        t.contains('水幕') ||
        t.contains('火势控制')) {
      return water;
    }
    // 搜救（救人、侦察、破拆排烟等救援作业）
    if (t.contains('搜救') ||
        t.contains('搜寻') ||
        t.contains('搜索') ||
        t.contains('侦查') ||
        t.contains('侦察') ||
        t.contains('侦检') ||
        t.contains('探测') ||
        t.contains('被困') ||
        t.contains('遇险') ||
        t.contains('失联') ||
        t.contains('救人') ||
        t.contains('疏散') ||
        t.contains('转移') ||
        t.contains('救出') ||
        t.contains('抬出') ||
        t.contains('登高') ||
        t.contains('破拆') ||
        t.contains('排烟') ||
        t.contains('通风') ||
        t.contains('内攻') ||
        t.contains('开辟通道') ||
        t.contains('查找火源')) {
      return rescue;
    }
    // 部署（接警出动、力量调度与战斗展开）
    if (t.contains('出动') ||
        t.contains('接警') ||
        t.contains('调派') ||
        t.contains('调度') ||
        t.contains('增援') ||
        t.contains('到场') ||
        t.contains('到达') ||
        t.contains('进入') ||
        t.contains('集结') ||
        t.contains('部署') ||
        t.contains('展开') ||
        t.contains('阵地') ||
        t.contains('警戒') ||
        t.contains('封锁') ||
        t.contains('隔离') ||
        t.contains('指挥部') ||
        t.contains('集结点') ||
        t.contains('战备') ||
        t.contains('待命') ||
        t.contains('保障') ||
        t.contains('协同') ||
        t.contains('力量') ||
        t.contains('指挥')) {
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

  /// 发布者真实姓名（实名认证设置）；空 = 匿名
  final String author;
  final int createdAt;
  final int updatedAt;

  const Note({
    required this.id,
    required this.text,
    required this.category,
    this.author = '',
    required this.createdAt,
    required this.updatedAt,
  });

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    text: (json['text'] as String?) ?? '',
    category: (json['category'] as String?) ?? NoteCategory.other,
    author: (json['author'] as String?) ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
  );
}

class Firefighter {
  final String id;
  final String name;
  final String source;
  final String? createdByMemberId;
  Firefighter({
    required this.id,
    required this.name,
    this.source = 'user',
    this.createdByMemberId,
  });
  factory Firefighter.fromJson(Map<String, dynamic> json) => Firefighter(
    id: json['id'] as String,
    name: json['name'] as String,
    source: (json['source'] as String?) ?? 'user',
    createdByMemberId: json['created_by_member_id'] as String?,
  );
}

class Hotword {
  final String id;
  final String word;
  final String source;
  final String? createdByMemberId;
  Hotword({
    required this.id,
    required this.word,
    this.source = 'user',
    this.createdByMemberId,
  });
  factory Hotword.fromJson(Map<String, dynamic> json) => Hotword(
    id: json['id'] as String,
    word: json['word'] as String,
    source: (json['source'] as String?) ?? 'user',
    createdByMemberId: json['created_by_member_id'] as String?,
  );
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

/// 智能体问答消息（user 提问 / assistant 回复）
class ChatMessage {
  final String id;
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'created_at': createdAt,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    role: (json['role'] as String?) ?? 'user',
    content: (json['content'] as String?) ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
  );
}

class VisionAnalysis {
  final String relevance;
  final String category;
  final double confidence;
  final List<String> facts;
  final List<String> risks;
  final List<String> toConfirm;
  final List<String> suggestions;
  final String disclaimer;

  const VisionAnalysis({
    required this.relevance,
    required this.category,
    required this.confidence,
    required this.facts,
    required this.risks,
    required this.toConfirm,
    required this.suggestions,
    required this.disclaimer,
  });

  factory VisionAnalysis.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) => (json[key] as List? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.trim().isNotEmpty)
        .toList(growable: false);
    final rawConfidence = (json['confidence'] as num?)?.toDouble() ?? 0;
    return VisionAnalysis(
      relevance: json['relevance']?.toString() ?? 'uncertain',
      category: json['category']?.toString() ?? 'unknown',
      confidence: rawConfidence.clamp(0, 1).toDouble(),
      facts: list('facts'),
      risks: list('risks'),
      toConfirm: list('to_confirm'),
      suggestions: list('suggestions'),
      disclaimer: json['disclaimer']?.toString() ?? '以上为图片辅助分析，不替代现场专业判断',
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

/// 水印相机使用的地址与天气（服务端代理高德，Key 不下发客户端）。
class AmapLocation {
  final double lat;
  final double lon;
  final String coordinate;

  const AmapLocation({
    required this.lat,
    required this.lon,
    this.coordinate = 'gcj02',
  });

  static AmapLocation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lon = (raw['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return AmapLocation(
      lat: lat,
      lon: lon,
      coordinate: raw['coordinate']?.toString() ?? 'gcj02',
    );
  }
}

class WeatherInfo {
  final String? address;
  final String? city;
  final String? weatherText;
  final String? temperature;
  final String? humidity;
  final String? line;
  final AmapLocation? amapLocation;
  final bool coordinateDegraded;
  final bool degraded;

  const WeatherInfo({
    this.address,
    this.city,
    this.weatherText,
    this.temperature,
    this.humidity,
    this.line,
    this.amapLocation,
    this.coordinateDegraded = false,
    this.degraded = false,
  });

  static const WeatherInfo empty = WeatherInfo(degraded: true);

  factory WeatherInfo.fromJson(Map<String, dynamic> json) {
    final weather = json['weather'];
    final map = weather is Map ? weather : const <String, dynamic>{};
    return WeatherInfo(
      address: (json['address'] as String?)?.trim(),
      city: (json['city'] as String?)?.trim(),
      weatherText: (map['text'] as String?)?.trim(),
      temperature: map['temperature']?.toString(),
      humidity: map['humidity']?.toString(),
      line: (json['line'] as String?)?.trim(),
      amapLocation: AmapLocation.fromJson(json['amapLocation']),
      coordinateDegraded: json['coordinateDegraded'] == true,
      degraded: json['degraded'] == true,
    );
  }
}

class RouteEndpointInfo {
  final String queryAddress;
  final String formattedAddress;
  final String province;
  final String city;
  final String district;
  final String adcode;
  final AmapLocation? location;

  const RouteEndpointInfo({
    required this.queryAddress,
    required this.formattedAddress,
    this.province = '',
    this.city = '',
    this.district = '',
    this.adcode = '',
    this.location,
  });

  String get displayAddress =>
      formattedAddress.trim().isNotEmpty ? formattedAddress.trim() : queryAddress.trim();

  static RouteEndpointInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteEndpointInfo(
      queryAddress: json['queryAddress']?.toString().trim() ?? '',
      formattedAddress: json['formattedAddress']?.toString().trim() ?? '',
      province: json['province']?.toString().trim() ?? '',
      city: json['city']?.toString().trim() ?? '',
      district: json['district']?.toString().trim() ?? '',
      adcode: json['adcode']?.toString().trim() ?? '',
      location: AmapLocation.fromJson(json['location']),
    );
  }
}

class RouteOriginInfo {
  final String address;
  final AmapLocation? location;
  final bool coordinateDegraded;

  const RouteOriginInfo({
    this.address = '',
    this.location,
    this.coordinateDegraded = false,
  });

  static RouteOriginInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteOriginInfo(
      address: json['address']?.toString().trim() ?? '',
      location: AmapLocation.fromJson(json['location']),
      coordinateDegraded: json['coordinateDegraded'] == true,
    );
  }
}

class RouteWeatherLive {
  final String text;
  final String temperature;
  final String humidity;
  final String windDirection;
  final String windPower;
  final String observedAt;
  final String city;

  const RouteWeatherLive({
    this.text = '',
    this.temperature = '',
    this.humidity = '',
    this.windDirection = '',
    this.windPower = '',
    this.observedAt = '',
    this.city = '',
  });

  String get windLabel {
    final dir = windDirection.trim();
    final power = windPower.trim();
    final parts = <String>[];
    if (dir.isNotEmpty) {
      parts.add(dir.endsWith('风') || dir.contains('风向') ? dir : '$dir风');
    }
    if (power.isNotEmpty) {
      parts.add(power.endsWith('级') ? power : '$power级');
    }
    return parts.join(' · ');
  }

  static RouteWeatherLive? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteWeatherLive(
      text: json['text']?.toString().trim() ?? '',
      temperature: json['temperature']?.toString().trim() ?? '',
      humidity: json['humidity']?.toString().trim() ?? '',
      windDirection: json['windDirection']?.toString().trim() ?? '',
      windPower: json['windPower']?.toString().trim() ?? '',
      observedAt: json['observedAt']?.toString().trim() ?? '',
      city: json['city']?.toString().trim() ?? '',
    );
  }
}

class RouteWeatherForecast {
  final String date;
  final String dayWeather;
  final String nightWeather;
  final String dayTemp;
  final String nightTemp;
  final String dayWind;
  final String nightWind;
  final String dayPower;
  final String nightPower;

  const RouteWeatherForecast({
    this.date = '',
    this.dayWeather = '',
    this.nightWeather = '',
    this.dayTemp = '',
    this.nightTemp = '',
    this.dayWind = '',
    this.nightWind = '',
    this.dayPower = '',
    this.nightPower = '',
  });

  static RouteWeatherForecast? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return RouteWeatherForecast(
      date: json['date']?.toString().trim() ?? '',
      dayWeather: json['dayWeather']?.toString().trim() ?? '',
      nightWeather: json['nightWeather']?.toString().trim() ?? '',
      dayTemp: json['dayTemp']?.toString().trim() ?? '',
      nightTemp: json['nightTemp']?.toString().trim() ?? '',
      dayWind: json['dayWind']?.toString().trim() ?? '',
      nightWind: json['nightWind']?.toString().trim() ?? '',
      dayPower: json['dayPower']?.toString().trim() ?? '',
      nightPower: json['nightPower']?.toString().trim() ?? '',
    );
  }
}

class TrafficSummary {
  final int smoothMeters;
  final int slowMeters;
  final int jamMeters;
  final int severeJamMeters;
  final int unknownMeters;

  const TrafficSummary({
    this.smoothMeters = 0,
    this.slowMeters = 0,
    this.jamMeters = 0,
    this.severeJamMeters = 0,
    this.unknownMeters = 0,
  });

  int get totalMeters =>
      smoothMeters + slowMeters + jamMeters + severeJamMeters + unknownMeters;

  factory TrafficSummary.fromJson(Object? raw) {
    if (raw is! Map) return const TrafficSummary();
    final json = Map<String, dynamic>.from(raw);
    return TrafficSummary(
      smoothMeters: (json['smoothMeters'] as num?)?.toInt() ?? 0,
      slowMeters: (json['slowMeters'] as num?)?.toInt() ?? 0,
      jamMeters: (json['jamMeters'] as num?)?.toInt() ?? 0,
      severeJamMeters: (json['severeJamMeters'] as num?)?.toInt() ?? 0,
      unknownMeters: (json['unknownMeters'] as num?)?.toInt() ?? 0,
    );
  }
}

class CongestedSegment {
  final String road;
  final String status;
  final int distanceMeters;

  const CongestedSegment({
    required this.road,
    required this.status,
    required this.distanceMeters,
  });

  factory CongestedSegment.fromJson(Map<String, dynamic> json) =>
      CongestedSegment(
        road: json['road']?.toString().trim() ?? '',
        status: json['status']?.toString().trim() ?? '',
        distanceMeters: (json['distanceMeters'] as num?)?.toInt() ?? 0,
      );
}

class RouteStepInfo {
  final String instruction;
  final String road;
  final int distanceMeters;
  final int durationSeconds;
  final String action;
  final String status;

  const RouteStepInfo({
    required this.instruction,
    this.road = '',
    this.distanceMeters = 0,
    this.durationSeconds = 0,
    this.action = '',
    this.status = '',
  });

  factory RouteStepInfo.fromJson(Map<String, dynamic> json) => RouteStepInfo(
    instruction: json['instruction']?.toString().trim() ?? '',
    road: json['road']?.toString().trim() ?? '',
    distanceMeters: (json['distanceMeters'] as num?)?.toInt() ?? 0,
    durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
    action: json['action']?.toString().trim() ?? '',
    status: json['status']?.toString().trim() ?? '',
  );
}

class DrivingRoutePlan {
  final String strategy;
  final int distanceMeters;
  final int durationSeconds;
  final int trafficLights;
  final int tolls;
  final int tollDistanceMeters;
  final String overallStatus;
  final List<String> roads;
  final TrafficSummary trafficSummary;
  final List<CongestedSegment> congestedSegments;
  final List<RouteStepInfo> steps;

  const DrivingRoutePlan({
    this.strategy = '',
    this.distanceMeters = 0,
    this.durationSeconds = 0,
    this.trafficLights = 0,
    this.tolls = 0,
    this.tollDistanceMeters = 0,
    this.overallStatus = '畅通',
    this.roads = const [],
    this.trafficSummary = const TrafficSummary(),
    this.congestedSegments = const [],
    this.steps = const [],
  });

  factory DrivingRoutePlan.fromJson(Map<String, dynamic> json) {
    final rawRoads = json['roads'] as List? ?? const [];
    final rawCongested = json['congestedSegments'] as List? ?? const [];
    final rawSteps = json['steps'] as List? ?? const [];
    return DrivingRoutePlan(
      strategy: json['strategy']?.toString().trim() ?? '',
      distanceMeters: (json['distanceMeters'] as num?)?.toInt() ??
          (json['distance'] as num?)?.toInt() ??
          0,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ??
          (json['duration'] as num?)?.toInt() ??
          0,
      trafficLights: (json['trafficLights'] as num?)?.toInt() ?? 0,
      tolls: (json['tolls'] as num?)?.round() ?? 0,
      tollDistanceMeters: (json['tollDistanceMeters'] as num?)?.toInt() ?? 0,
      overallStatus: json['overallStatus']?.toString().trim().isNotEmpty == true
          ? json['overallStatus'].toString().trim()
          : '畅通',
      roads: rawRoads
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      trafficSummary: TrafficSummary.fromJson(json['trafficSummary']),
      congestedSegments: rawCongested
          .whereType<Map>()
          .map((e) => CongestedSegment.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      steps: rawSteps
          .whereType<Map>()
          .map((e) => RouteStepInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }
}

class RouteDestinationCandidate {
  final String name;
  final String formattedAddress;
  final String province;
  final String city;
  final String district;
  final String adcode;
  final AmapLocation? location;

  const RouteDestinationCandidate({
    required this.name,
    required this.formattedAddress,
    this.province = '',
    this.city = '',
    this.district = '',
    this.adcode = '',
    this.location,
  });

  String get displayAddress =>
      formattedAddress.trim().isNotEmpty ? formattedAddress.trim() : name.trim();

  factory RouteDestinationCandidate.fromJson(Map<String, dynamic> json) {
    return RouteDestinationCandidate(
      name: (json['name']?.toString() ?? '').trim(),
      formattedAddress: (json['formattedAddress']?.toString() ?? '').trim(),
      province: (json['province']?.toString() ?? '').trim(),
      city: (json['city']?.toString() ?? '').trim(),
      district: (json['district']?.toString() ?? '').trim(),
      adcode: (json['adcode']?.toString() ?? '').trim(),
      location: AmapLocation.fromJson(json['location']),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'formattedAddress': formattedAddress,
    'province': province,
    'city': city,
    'district': district,
    'adcode': adcode,
    if (location != null)
      'location': {
        'lat': location!.lat,
        'lon': location!.lon,
        'coordinate': location!.coordinate,
      },
  };
}

class RouteTrafficInfo {
  final RouteEndpointInfo? destination;
  final RouteOriginInfo? origin;
  final RouteWeatherLive? weather;
  final String? weatherLine;
  final RouteWeatherForecast? forecast;
  final List<DrivingRoutePlan> routes;
  final bool routeAvailable;
  final bool degraded;
  final bool ambiguous;
  final List<RouteDestinationCandidate> candidates;

  const RouteTrafficInfo({
    this.destination,
    this.origin,
    this.weather,
    this.weatherLine,
    this.forecast,
    this.routes = const [],
    this.routeAvailable = false,
    this.degraded = false,
    this.ambiguous = false,
    this.candidates = const [],
  });

  Uri? get navigationUri {
    final loc = destination?.location;
    if (loc == null ||
        loc.coordinate.toLowerCase() != 'gcj02' ||
        !loc.lat.isFinite ||
        !loc.lon.isFinite) {
      return null;
    }
    return Uri.https('uri.amap.com', '/navigation', {
      'to': '${loc.lon.toStringAsFixed(6)},${loc.lat.toStringAsFixed(6)}',
    });
  }

  static String formatDuration(int durationSeconds) {
    final totalMinutes = durationSeconds <= 0
        ? 1
        : ((durationSeconds + 30) ~/ 60).clamp(1, 99999);
    if (totalMinutes < 60) {
      return '$totalMinutes 分钟';
    }
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    return mins == 0 ? '$hours小时' : '$hours小时$mins分';
  }

  static String formatDistance(int meters, {bool compactUnit = false}) {
    if (meters < 1000) {
      return compactUnit ? '$meters米' : '$meters 米';
    }
    final km = meters / 1000.0;
    return compactUnit
        ? '${km.toStringAsFixed(1)}公里'
        : '${km.toStringAsFixed(1)} 公里';
  }

  String toSummaryText({required String incidentName, int routeIndex = 0}) {
    final lines = <String>[];
    final cleanIncident = incidentName.trim();
    if (cleanIncident.isNotEmpty) {
      lines.add('警情：$cleanIncident');
    }
    final destAddr = destination?.displayAddress ?? '';
    if (destAddr.isNotEmpty) {
      lines.add('事发地点：$destAddr');
    }
    final originAddr = origin?.address.trim() ?? '';
    if (originAddr.isNotEmpty) {
      lines.add('出发位置：$originAddr');
    }
    if (routes.isNotEmpty) {
      final idx = routeIndex.clamp(0, routes.length - 1);
      final route = routes[idx];
      final durationText = formatDuration(route.durationSeconds);
      final distanceText = formatDistance(route.distanceMeters);
      lines.add(
        '预计行程：$durationText（$distanceText，红绿灯 ${route.trafficLights} 个）',
      );
      lines.add('整体路况：${route.overallStatus}');
      if (route.roads.isNotEmpty) {
        lines.add('途经道路：${route.roads.join(' → ')}');
      }
      if (route.congestedSegments.isNotEmpty) {
        final segText = route.congestedSegments
            .map(
              (s) =>
                  '${s.road} · ${s.status} ${formatDistance(s.distanceMeters, compactUnit: true)}',
            )
            .join('；');
        lines.add('拥堵提醒：$segText');
      } else {
        lines.add('拥堵提醒：当前路线全线畅通，无明显拥堵路段');
      }
    }
    final live = weather;
    if (live != null &&
        (live.text.isNotEmpty ||
            live.temperature.isNotEmpty ||
            live.windLabel.isNotEmpty)) {
      final weatherParts = <String>[
        if (live.text.isNotEmpty) live.text,
        if (live.temperature.isNotEmpty) '${live.temperature}℃',
        if (live.humidity.isNotEmpty) '湿度${live.humidity}%',
        if (live.windLabel.isNotEmpty) live.windLabel,
      ];
      lines.add('现场天气：${weatherParts.join(' · ')}');
    } else if ((weatherLine ?? '').trim().isNotEmpty) {
      lines.add('现场天气：${weatherLine!.trim()}');
    }
    final fc = forecast;
    if (fc != null &&
        (fc.dayWeather.isNotEmpty || fc.nightWeather.isNotEmpty)) {
      lines.add(
        '今日预报：白天${fc.dayWeather} ${fc.dayTemp}℃ / 夜间${fc.nightWeather} ${fc.nightTemp}℃',
      );
    }
    final nav = navigationUri;
    if (nav != null) {
      lines
        ..add('')
        ..add('高德驾车导航：')
        ..add(nav.toString());
    }
    return lines.join('\n');
  }

  factory RouteTrafficInfo.fromJson(Map<String, dynamic> json) {
    final rawRoutes = json['routes'] as List? ?? const [];
    final rawCandidates = json['candidates'] as List? ?? const [];
    return RouteTrafficInfo(
      destination: RouteEndpointInfo.fromJson(json['destination']),
      origin: RouteOriginInfo.fromJson(json['origin']),
      weather: RouteWeatherLive.fromJson(json['weather']),
      weatherLine: (json['weatherLine'] as String?)?.trim(),
      forecast: RouteWeatherForecast.fromJson(json['forecast']),
      routes: rawRoutes
          .whereType<Map>()
          .map((e) => DrivingRoutePlan.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      routeAvailable: json['routeAvailable'] == true,
      degraded: json['degraded'] == true,
      ambiguous: json['ambiguous'] == true,
      candidates: rawCandidates
          .whereType<Map>()
          .map((e) => RouteDestinationCandidate.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }
}

