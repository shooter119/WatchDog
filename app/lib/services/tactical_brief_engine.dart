import '../models/models.dart';

/// 空呼安全警戒级别
enum AirSafetyLevel {
  /// 无人员在场
  idle,

  /// 正常 (>10 分钟)
  normal,

  /// 预警 (<=10 且 >5 分钟)
  warning,

  /// 危险 (<=5 分钟)
  critical,
}

/// 空呼短板与在场安全摘要
class AirSafetySummary {
  final int activeCount;
  final String? shortestName;
  final int? shortestRemainingMin;
  final AirSafetyLevel level;

  const AirSafetySummary({
    required this.activeCount,
    this.shortestName,
    this.shortestRemainingMin,
    required this.level,
  });

  factory AirSafetySummary.idle() => const AirSafetySummary(
        activeCount: 0,
        level: AirSafetyLevel.idle,
      );

  bool get hasActive => activeCount > 0;
}

/// 五维战术情报汇总结构体
class TacticalIntelligenceSummary {
  /// 极端险情与结构风险（倒塌、爆炸、有毒、断电等）
  final List<String> hazards;

  /// 人命搜救与伤亡处置（搜救出人员、移交120、排查完毕等）
  final List<String> lifeSafety;

  /// 火势控制与灭火阵地（出水枪、堵截、排烟降温等）
  final List<String> suppression;

  /// 抢险破拆与技术处置（破拆、顶撑、关阀堵漏等）
  final List<String> technicalRescue;

  /// 外围警戒与供水保障（交警管制、消火栓供水等）
  final List<String> perimeterAndSupport;

  const TacticalIntelligenceSummary({
    this.hazards = const [],
    this.lifeSafety = const [],
    this.suppression = const [],
    this.technicalRescue = const [],
    this.perimeterAndSupport = const [],
  });

  bool get hasCriticalHazards => hazards.isNotEmpty;
  bool get hasRescueProgress => lifeSafety.isNotEmpty || technicalRescue.isNotEmpty;
  bool get isEmpty =>
      hazards.isEmpty &&
      lifeSafety.isEmpty &&
      suppression.isEmpty &&
      technicalRescue.isEmpty &&
      perimeterAndSupport.isEmpty;
}

/// 纯端侧战术事实聚合与公文速报生成引擎
class TacticalBriefEngine {
  TacticalBriefEngine._();

  static final RegExp _hazardRegex = RegExp(
    r'(倒塌|坍塌|倾斜|开裂|沉降|闪燃|轰燃|爆炸|爆燃|回燃|泄漏|毒气|腐蚀|断电|漏电|沸溢|喷溅|次生灾害|危险)',
    caseSensitive: false,
  );

  static final RegExp _lifeSafetyRegex = RegExp(
    r'(被困|呼救|救出|搜救出|疏散|受困|失联|伤亡|重伤|轻伤|送医|120|生命体征|安全转移|排查完毕)',
    caseSensitive: false,
  );

  static final RegExp _suppressionRegex = RegExp(
    r'(出水|水枪|阵地|内攻|火势控制|火势蔓延|堵截|排烟|降温|扑灭|控制火势)',
    caseSensitive: false,
  );

  static final RegExp _technicalRescueRegex = RegExp(
    r'(破拆|破障|顶撑|牵引|吊升|绳索|关阀|堵漏|稀释|洗消|排涝|清障)',
    caseSensitive: false,
  );

  static final RegExp _supportRegex = RegExp(
    r'(警戒|管制|交警|围观|排空|建立供水|不间断供水|消火栓|天然水源|运水供水)',
    caseSensitive: false,
  );

  /// 从在场人员列表中提取木桶最短板及安全摘要
  static AirSafetySummary extractAirSafetySummary(
    List<Entry> entries, {
    int? nowMillis,
  }) {
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final activeEntries = entries.where((e) => e.isActive).toList();

    if (activeEntries.isEmpty) {
      return AirSafetySummary.idle();
    }

    Entry? bottleneck;
    int minRemainingMin = 999999;

    for (final e in activeEntries) {
      final remMs = e.exitAt - now;
      final remMin = (remMs / 60000).ceil();
      final clampedMin = remMin < 0 ? 0 : remMin;

      if (bottleneck == null || clampedMin < minRemainingMin) {
        bottleneck = e;
        minRemainingMin = clampedMin;
      }
    }

    AirSafetyLevel level;
    if (minRemainingMin <= 5) {
      level = AirSafetyLevel.critical;
    } else if (minRemainingMin <= 10) {
      level = AirSafetyLevel.warning;
    } else {
      level = AirSafetyLevel.normal;
    }

    return AirSafetySummary(
      activeCount: activeEntries.length,
      shortestName: bottleneck?.name,
      shortestRemainingMin: minRemainingMin,
      level: level,
    );
  }

  /// 从火场日志中提取五维高权重战术情报
  static TacticalIntelligenceSummary extractIntelligence(List<Note> notes) {
    if (notes.isEmpty) return const TacticalIntelligenceSummary();

    final hazards = <String>[];
    final lifeSafety = <String>[];
    final suppression = <String>[];
    final technicalRescue = <String>[];
    final support = <String>[];

    // 逆序遍历日志（最新的优先）
    for (final n in notes.reversed) {
      final text = n.text.trim();
      if (text.isEmpty) continue;

      // 过滤系统自动进出场流水
      if (_isTelemetryNote(text)) continue;

      // A. 极端险情与结构风险 (权重 100)
      if (_hazardRegex.hasMatch(text)) {
        if (hazards.length < 2 && !hazards.contains(text)) {
          hazards.add(text);
        }
        continue;
      }

      // B. 人命搜救与人员伤亡 (权重 90)
      if (_lifeSafetyRegex.hasMatch(text) || n.category == '搜救') {
        if (lifeSafety.length < 2 && !lifeSafety.contains(text)) {
          lifeSafety.add(text);
        }
        continue;
      }

      // C. 火势控制与灭火阵地 (权重 70)
      if (_suppressionRegex.hasMatch(text) || n.category == '出水') {
        if (suppression.length < 2 && !suppression.contains(text)) {
          suppression.add(text);
        }
        continue;
      }

      // D. 抢险破拆与技术处置 (权重 70)
      if (_technicalRescueRegex.hasMatch(text) || n.category == '破拆') {
        if (technicalRescue.length < 2 && !technicalRescue.contains(text)) {
          technicalRescue.add(text);
        }
        continue;
      }

      // E. 外围警戒与供水 (权重 50)
      if (_supportRegex.hasMatch(text) || n.category == '供水') {
        if (support.length < 2 && !support.contains(text)) {
          support.add(text);
        }
        continue;
      }
    }

    return TacticalIntelligenceSummary(
      hazards: hazards,
      lifeSafety: lifeSafety,
      suppression: suppression,
      technicalRescue: technicalRescue,
      perimeterAndSupport: support,
    );
  }

  /// 逆序提取最新实质性战术进展（兼顾旧接口）
  static String? extractTacticalProgress(List<Note> notes) {
    final intel = extractIntelligence(notes);
    if (intel.hazards.isNotEmpty) return intel.hazards.first;
    if (intel.lifeSafety.isNotEmpty) return intel.lifeSafety.first;
    if (intel.suppression.isNotEmpty) return intel.suppression.first;
    if (intel.technicalRescue.isNotEmpty) return intel.technicalRescue.first;
    if (intel.perimeterAndSupport.isNotEmpty) return intel.perimeterAndSupport.first;
    return null;
  }

  /// 精准提取事发地点（避免读错字段）
  static String extractLocation(Incident? incident) {
    if (incident == null) return '现场核实中';

    final loc = incident.info['location']?.toString().trim();
    if (loc != null && loc.isNotEmpty) return loc;

    final addr = incident.info['address']?.toString().trim();
    if (addr != null && addr.isNotEmpty) return addr;

    final title = incident.displayName.trim();
    if (title.isNotEmpty) return title;

    return '现场核实中';
  }

  /// 格式化标准化纯文本战况速报（面向高级指挥员、纯客观、动态自适应脚手架）
  static String formatObjectiveBrief({
    required Incident? incident,
    required List<IncidentForce> forces,
    required List<Entry> entries,
    required List<Note> notes,
    DateTime? generatedAt,
  }) {
    final dt = generatedAt ?? DateTime.now();
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    final title = incident?.displayName.isNotEmpty == true
        ? incident!.displayName
        : '救援处置动态';

    final locationStr = extractLocation(incident);
    final intel = extractIntelligence(notes);
    final airSummary = extractAirSafetySummary(entries, nowMillis: dt.millisecondsSinceEpoch);

    final info = incident?.info ?? const {};
    final specificType = info['specific_type']?.toString() ?? '';
    final origCategory = info['original_category']?.toString() ?? '';
    final situation = info['situation']?.toString() ?? '';

    final bool isRescue = specificType.contains('抢险') ||
        origCategory.contains('抢险') ||
        situation.contains('抢险') ||
        specificType.contains('救助') ||
        origCategory.contains('救助');

    final bool hasActiveEntries = entries.any((e) => e.isActive);

    final buffer = StringBuffer();

    // 1. 公文抬头
    if (isRescue) {
      buffer.writeln('【抢险救援现场速报】$title（$timeStr）');
    } else {
      buffer.writeln('【火灾扑救战况速报】$title（$timeStr）');
    }
    buffer.writeln('事发地点：$locationStr');

    // 2. 顶层 3 秒态势速览 (Executive Summary)
    final execSummary = _buildExecutiveSummary(isRescue, intel, airSummary);
    if (execSummary.isNotEmpty) {
      buffer.writeln('【核心要事】$execSummary');
    }
    buffer.writeln();

    // 3. 动态脚手架分块：抢险救援且无在场内攻时，完全隐藏空呼安全板块
    if (isRescue && !hasActiveEntries) {
      // 分块一：力量到场与现场展开
      buffer.writeln('一、到场力量与救援展开');
      buffer.writeln(_buildForceSummary(incident, forces));
      final rescueDeploy = _buildDeploymentText(intel, isRescue: true);
      buffer.writeln(rescueDeploy);
      buffer.writeln();

      // 分块二：现场险情与风险控制
      buffer.writeln('二、现场险情与风险控制');
      buffer.writeln(_buildHazardsText(intel));
      buffer.writeln();

      // 分块三：人员搜救与转移送医
      buffer.writeln('三、人员搜救与送医转移');
      buffer.writeln(_buildCasualtyAndRescueText(intel));
    } else {
      // 灭火场景或含内攻作业场景
      // 分块一：力量到场与战术部署
      buffer.writeln('一、到场力量与战术部署');
      buffer.writeln(_buildForceSummary(incident, forces));
      final fireDeploy = _buildDeploymentText(intel, isRescue: false);
      buffer.writeln(fireDeploy);
      buffer.writeln();

      // 分块二：现场险情与结构安全
      buffer.writeln('二、现场险情与结构安全');
      buffer.writeln(_buildHazardsText(intel));
      buffer.writeln();

      // 分块三：搜救排查与人员伤亡
      buffer.writeln('三、搜救排查与人员伤亡');
      buffer.writeln(_buildCasualtyAndRescueText(intel));
      buffer.writeln();

      // 分块四：内攻作业与空呼安全
      buffer.writeln('四、内攻作业与空呼安全');
      buffer.writeln(_buildAirSafetyText(airSummary, entries));
    }

    return sanitizeBriefText(buffer.toString().trim());
  }

  static String _buildExecutiveSummary(
    bool isRescue,
    TacticalIntelligenceSummary intel,
    AirSafetySummary airSummary,
  ) {
    final parts = <String>[];

    // 搜救第一优先
    if (intel.lifeSafety.isNotEmpty) {
      parts.add(intel.lifeSafety.first);
    }

    // 险情第二优先
    if (intel.hazards.isNotEmpty) {
      parts.add('【警示】${intel.hazards.first}');
    }

    // 战术行动
    if (isRescue) {
      if (intel.technicalRescue.isNotEmpty) {
        parts.add(intel.technicalRescue.first);
      }
    } else {
      if (intel.suppression.isNotEmpty) {
        parts.add(intel.suppression.first);
      }
    }

    // 空呼告警
    if (airSummary.level == AirSafetyLevel.critical) {
      parts.add('内攻组最低气瓶不足5分钟需撤离');
    }

    if (parts.isEmpty) {
      return isRescue ? '现场救援作业正在全力推进中。' : '火场各项战术扑救工作有序展开。';
    }

    return '${parts.join('；')}。';
  }

  static String _buildDeploymentText(
    TacticalIntelligenceSummary intel, {
    required bool isRescue,
  }) {
    final actions = <String>[];

    if (isRescue) {
      if (intel.technicalRescue.isNotEmpty) {
        actions.addAll(intel.technicalRescue);
      }
      if (intel.perimeterAndSupport.isNotEmpty) {
        actions.addAll(intel.perimeterAndSupport);
      }
      if (actions.isEmpty) {
        return '现场作业：破拆救援与现场排查装备已就绪，救援全力展开。';
      }
      return '现场作业：${actions.join('；')}。';
    } else {
      if (intel.suppression.isNotEmpty) {
        actions.addAll(intel.suppression);
      }
      if (intel.perimeterAndSupport.isNotEmpty) {
        actions.addAll(intel.perimeterAndSupport);
      }
      if (actions.isEmpty) {
        return '战术部署：阵地展开就位，各项处置正在推进。';
      }
      return '战术部署：${actions.join('；')}。';
    }
  }

  static String _buildHazardsText(TacticalIntelligenceSummary intel) {
    if (intel.hazards.isNotEmpty) {
      return '【重点风险】${intel.hazards.join('；')}，现场已设立安全观察哨严密监控。';
    }
    return '现场勘查：现场未发现明显结构坍塌、闪爆及严重次生灾害隐患，安全态势可控。';
  }

  static String _buildCasualtyAndRescueText(TacticalIntelligenceSummary intel) {
    if (intel.lifeSafety.isNotEmpty) {
      return '搜救进展：${intel.lifeSafety.join('；')}。搜救组持续复核排查。';
    }
    return '搜救进展：搜救排查组正在持续排查，截至目前未收到人员伤亡报告。';
  }

  static String _buildForceSummary(
    Incident? incident,
    List<IncidentForce> forces,
  ) {
    if (forces.isNotEmpty) {
      final parts = <String>[];
      int totalVehicles = 0;
      int totalPersonnel = 0;

      for (final f in forces) {
        totalVehicles += f.vehicleCount;
        totalPersonnel += f.personnelCount;
        parts.add('${f.stationName} ${f.vehicleCount}车${f.personnelCount}人');
      }

      return '参战力量：共出动$totalVehicles辆消防车、$totalPersonnel名指战员（${parts.join('、')}），已全部到场展开。';
    }

    if (incident != null &&
        (incident.vehicleCount > 0 || incident.personnelCount > 0)) {
      return '参战力量：出动${incident.vehicleCount}辆消防车、${incident.personnelCount}名指战员，已到场展开。';
    }

    return '参战力量：首批出动力量已到场展开作业。';
  }

  static String _buildAirSafetyText(
    AirSafetySummary summary,
    List<Entry> entries,
  ) {
    if (!summary.hasActive) {
      return '现场内攻人员：暂无在场内攻作业人员，外围阵地严密防守。';
    }

    final activeEntries = entries.where((e) => e.isActive).toList();
    final names = activeEntries.map((e) => e.name).take(6).join('、');
    final nameSuffix = activeEntries.length > 6 ? '等' : '';

    final warningNote = summary.level == AirSafetyLevel.critical
        ? '【重点关注：最低可用时间不足5分钟，已进入紧急撤离告警】'
        : summary.level == AirSafetyLevel.warning
            ? '【注意：最低可用时间不足10分钟，安全员正在组织复核】'
            : '（空呼可用时间正常，安全员在场持续监测）';

    return '现场内攻人员：共${summary.activeCount}人在场（涉及：$names$nameSuffix）。当前在场组员最低气瓶可用时间为${summary.shortestRemainingMin}分钟（${summary.shortestName}），$warningNote。';
  }

  static bool _isTelemetryNote(String text) {
    return text.contains('进入救援现场') ||
        text.contains('撤离救援现场') ||
        text.contains('已退场') ||
        text.contains('退场');
  }

  /// 遵循 AGENTS.md 脱敏规范，过滤敏感字段
  static String sanitizeBriefText(String text) {
    var result = text;
    // 隐藏特定密钥与验证码敏感串
    result = result.replaceAll(
      RegExp(r'(验证码|密码|token)[:：=]\s*[a-zA-Z0-9]+', caseSensitive: false),
      '验证码: ****',
    );
    return result;
  }
}
