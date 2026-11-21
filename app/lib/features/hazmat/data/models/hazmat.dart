/// 危化品战术处置卡数据模型（对齐服务端 hazardous_chemicals 与内置离线种子库）
class HazmatItem {
  final String id;
  final String nameCn;
  final String nameEn;
  final List<String> aliases;
  final String unNumber;
  final String casNumber;
  final String dangerCategory;
  final String dangerSignColor;
  final String waterReactivity; // 'forbidden' | 'reactive' | 'normal'
  final String dangerSummary;
  final String forbiddenAgents;
  final String extinguishingAgents;
  final String firefightingTips;
  final String protectiveLevel;
  final String isolationDistance;
  final String leakHandling;
  final String firstAid;
  final String appearance;
  final String flashPoint;
  final String explosionLimit;
  final String vaporDensity;
  final String notes;
  final bool active;
  final int createdAt;
  final int updatedAt;
  final String source; // 'seed' | 'server' | 'ai'

  const HazmatItem({
    required this.id,
    required this.nameCn,
    this.nameEn = '',
    this.aliases = const [],
    this.unNumber = '',
    this.casNumber = '',
    this.dangerCategory = '',
    this.dangerSignColor = '',
    this.waterReactivity = 'normal',
    this.dangerSummary = '',
    this.forbiddenAgents = '',
    this.extinguishingAgents = '',
    this.firefightingTips = '',
    this.protectiveLevel = '',
    this.isolationDistance = '',
    this.leakHandling = '',
    this.firstAid = '',
    this.appearance = '',
    this.flashPoint = '',
    this.explosionLimit = '',
    this.vaporDensity = '',
    this.notes = '',
    this.active = true,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.source = 'seed',
  });

  bool get isWaterForbidden => waterReactivity == 'forbidden';
  bool get isWaterReactive => waterReactivity == 'reactive';
  bool get isAiGenerated => source == 'ai';

  String get waterLabel {
    switch (waterReactivity) {
      case 'forbidden':
        return '严禁用水';
      case 'reactive':
        return '慎用/热剧反应';
      default:
        return '可用水冷却/控制';
    }
  }

  /// 基于相对蒸气密度（空气=1）提炼现场防积聚方位提示
  String get vaporDensityHint {
    final raw = vaporDensity.trim();
    if (raw.isEmpty) return '';
    if (raw.contains('轻于空气') && raw.contains('贴地')) {
      return raw;
    }
    final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(raw);
    if (match == null) return raw;
    final val = double.tryParse(match.group(0)!);
    if (val == null) return raw;
    if (val > 1.05) {
      return '$raw（重于空气，易沿地面/地沟积聚）';
    }
    if (val < 0.95) {
      return '$raw（轻于空气，易向高处扩散）';
    }
    return '$raw（与空气密度接近）';
  }

  HazmatItem copyWith({
    String? id,
    String? nameCn,
    String? nameEn,
    List<String>? aliases,
    String? unNumber,
    String? casNumber,
    String? dangerCategory,
    String? dangerSignColor,
    String? waterReactivity,
    String? dangerSummary,
    String? forbiddenAgents,
    String? extinguishingAgents,
    String? firefightingTips,
    String? protectiveLevel,
    String? isolationDistance,
    String? leakHandling,
    String? firstAid,
    String? appearance,
    String? flashPoint,
    String? explosionLimit,
    String? vaporDensity,
    String? notes,
    bool? active,
    int? createdAt,
    int? updatedAt,
    String? source,
  }) {
    return HazmatItem(
      id: id ?? this.id,
      nameCn: nameCn ?? this.nameCn,
      nameEn: nameEn ?? this.nameEn,
      aliases: aliases ?? this.aliases,
      unNumber: unNumber ?? this.unNumber,
      casNumber: casNumber ?? this.casNumber,
      dangerCategory: dangerCategory ?? this.dangerCategory,
      dangerSignColor: dangerSignColor ?? this.dangerSignColor,
      waterReactivity: waterReactivity ?? this.waterReactivity,
      dangerSummary: dangerSummary ?? this.dangerSummary,
      forbiddenAgents: forbiddenAgents ?? this.forbiddenAgents,
      extinguishingAgents: extinguishingAgents ?? this.extinguishingAgents,
      firefightingTips: firefightingTips ?? this.firefightingTips,
      protectiveLevel: protectiveLevel ?? this.protectiveLevel,
      isolationDistance: isolationDistance ?? this.isolationDistance,
      leakHandling: leakHandling ?? this.leakHandling,
      firstAid: firstAid ?? this.firstAid,
      appearance: appearance ?? this.appearance,
      flashPoint: flashPoint ?? this.flashPoint,
      explosionLimit: explosionLimit ?? this.explosionLimit,
      vaporDensity: vaporDensity ?? this.vaporDensity,
      notes: notes ?? this.notes,
      active: active ?? this.active,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      source: source ?? this.source,
    );
  }

  factory HazmatItem.fromJson(
    Map<String, dynamic> json, {
    String? defaultSource,
  }) {
    final rawAliases = json['aliases'];
    final aliases = <String>[];
    if (rawAliases is List) {
      for (final entry in rawAliases) {
        final s = entry?.toString().trim() ?? '';
        if (s.isNotEmpty) aliases.add(s);
      }
    } else if (rawAliases is String && rawAliases.trim().isNotEmpty) {
      for (final part in rawAliases.split(RegExp(r'[,，、;；\s]+'))) {
        final s = part.trim();
        if (s.isNotEmpty) aliases.add(s);
      }
    }

    final water = (json['water_reactivity'] ?? 'normal').toString().trim();
    final normalizedWater = (water == 'forbidden' || water == 'reactive')
        ? water
        : 'normal';

    return HazmatItem(
      id: (json['id'] ?? '').toString().trim(),
      nameCn: (json['name_cn'] ?? '').toString().trim(),
      nameEn: (json['name_en'] ?? '').toString().trim(),
      aliases: aliases,
      unNumber: _normalizeUn(json['un_number']),
      casNumber: (json['cas_number'] ?? '').toString().trim(),
      dangerCategory: (json['danger_category'] ?? '').toString().trim(),
      dangerSignColor: (json['danger_sign_color'] ?? '').toString().trim(),
      waterReactivity: normalizedWater,
      dangerSummary: (json['danger_summary'] ?? '').toString().trim(),
      forbiddenAgents: (json['forbidden_agents'] ?? '').toString().trim(),
      extinguishingAgents: (json['extinguishing_agents'] ?? '').toString().trim(),
      firefightingTips: (json['firefighting_tips'] ?? '').toString().trim(),
      protectiveLevel: (json['protective_level'] ?? '').toString().trim(),
      isolationDistance: (json['isolation_distance'] ?? '').toString().trim(),
      leakHandling: (json['leak_handling'] ?? '').toString().trim(),
      firstAid: (json['first_aid'] ?? '').toString().trim(),
      appearance: (json['appearance'] ?? '').toString().trim(),
      flashPoint: (json['flash_point'] ?? '').toString().trim(),
      explosionLimit: (json['explosion_limit'] ?? '').toString().trim(),
      vaporDensity: (json['vapor_density'] ?? '').toString().trim(),
      notes: (json['notes'] ?? '').toString().trim(),
      active: json['active'] == null ? true : json['active'] == true || json['active'] == 1,
      createdAt: _parseInt(json['created_at']),
      updatedAt: _parseInt(json['updated_at']),
      source: (json['source'] ?? defaultSource ?? 'seed').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name_cn': nameCn,
    'name_en': nameEn,
    'aliases': aliases,
    'un_number': unNumber,
    'cas_number': casNumber,
    'danger_category': dangerCategory,
    'danger_sign_color': dangerSignColor,
    'water_reactivity': waterReactivity,
    'danger_summary': dangerSummary,
    'forbidden_agents': forbiddenAgents,
    'extinguishing_agents': extinguishingAgents,
    'firefighting_tips': firefightingTips,
    'protective_level': protectiveLevel,
    'isolation_distance': isolationDistance,
    'leak_handling': leakHandling,
    'first_aid': firstAid,
    'appearance': appearance,
    'flash_point': flashPoint,
    'explosion_limit': explosionLimit,
    'vapor_density': vaporDensity,
    'notes': notes,
    'active': active,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'source': source,
  };

  /// 生成适合粘贴到救援调度/微信工作群的纯文本“电台复诵/处置要点”
  String formatShareText({String? aiDisclaimer}) {
    final lines = <String>[];
    final unTag = unNumber.isNotEmpty ? 'UN $unNumber ' : '';
    final catTag = dangerCategory.isNotEmpty ? '（$dangerCategory）' : '';
    lines.add('【危化品处置要点】$unTag$nameCn$catTag');

    if (isAiGenerated) {
      final disclaimer = (aiDisclaimer ?? '').trim().isNotEmpty
          ? aiDisclaimer!.trim()
          : 'AI 辅助提炼，请务必结合随车运单、SDS 与现场侦检核实';
      lines.add('⚠️ 提示：$disclaimer');
    }

    lines.add('遇水属性：$waterLabel');
    if (forbiddenAgents.isNotEmpty) {
      lines.add('绝对禁忌：$forbiddenAgents');
    }
    if (extinguishingAgents.isNotEmpty) {
      lines.add('推荐灭火/抑蒸：$extinguishingAgents');
    }
    if (protectiveLevel.isNotEmpty) {
      lines.add('防护等级：$protectiveLevel');
    }
    if (isolationDistance.isNotEmpty) {
      lines.add('隔离疏散：$isolationDistance');
    }
    if (firefightingTips.isNotEmpty) {
      lines.add('战术要点：$firefightingTips');
    }
    if (dangerSummary.isNotEmpty) {
      lines.add('核心风险：$dangerSummary');
    }
    if (leakHandling.isNotEmpty) {
      lines.add('泄漏处置：$leakHandling');
    }
    if (firstAid.isNotEmpty) {
      lines.add('现场急救：$firstAid');
    }
    return lines.join('\n');
  }

  static String _normalizeUn(dynamic raw) {
    final text = (raw ?? '').toString().trim();
    if (text.isEmpty) return '';
    final digits = text.replaceFirst(RegExp(r'^un[\s-]*', caseSensitive: false), '');
    return digits.trim();
  }

  static int _parseInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }
}

class HazmatSyncResult {
  final List<HazmatItem> items;
  final List<String> deletedIds;
  final int serverTime;

  const HazmatSyncResult({
    this.items = const [],
    this.deletedIds = const [],
    this.serverTime = 0,
  });

  factory HazmatSyncResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map(
              (m) => HazmatItem.fromJson(
                Map<String, dynamic>.from(m),
                defaultSource: 'server',
              ),
            )
            .toList()
        : <HazmatItem>[];
    final rawDeleted = json['deleted_ids'];
    final deletedIds = rawDeleted is List
        ? rawDeleted
            .map((e) => e?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty)
            .toList()
        : <String>[];
    final serverTimeRaw = json['server_time'];
    final serverTime = serverTimeRaw is num
        ? serverTimeRaw.toInt()
        : int.tryParse((serverTimeRaw ?? '0').toString()) ?? 0;
    return HazmatSyncResult(
      items: items,
      deletedIds: deletedIds,
      serverTime: serverTime,
    );
  }
}

class HazmatAiResult {
  final bool found;
  final String source;
  final String disclaimer;
  final String reason;
  final HazmatItem? item;

  const HazmatAiResult({
    required this.found,
    this.source = 'ai',
    this.disclaimer = '',
    this.reason = '',
    this.item,
  });

  factory HazmatAiResult.fromJson(Map<String, dynamic> json) {
    final found = json['found'] == true;
    final source = (json['source'] ?? 'ai').toString().trim();
    final disclaimer = (json['disclaimer'] ?? '').toString().trim();
    final reason = (json['reason'] ?? '').toString().trim();
    final rawItem = json['item'];
    final item = found && rawItem is Map
        ? HazmatItem.fromJson(
            Map<String, dynamic>.from(rawItem),
            defaultSource: source.isEmpty ? 'ai' : source,
          )
        : null;
    return HazmatAiResult(
      found: found && item != null,
      source: source,
      disclaimer: disclaimer,
      reason: reason,
      item: item,
    );
  }
}
