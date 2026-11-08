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

/// 纯端侧战术事实聚合与公文速报生成引擎
class TacticalBriefEngine {
  TacticalBriefEngine._();

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

  /// 逆序提取最新实质性战术进展（过滤纯进退场刷屏流水）
  static String? extractTacticalProgress(List<Note> notes) {
    if (notes.isEmpty) return null;

    final reversed = notes.reversed.toList();
    for (final note in reversed) {
      final text = note.text.trim();
      if (text.isEmpty) continue;

      // 过滤系统自动进出场流水
      if (text.contains('进入救援现场') ||
          text.contains('撤离救援现场') ||
          text.contains('已退场') ||
          text.contains('退场')) {
        continue;
      }

      return text;
    }

    return null;
  }

  /// 格式化标准化纯文本火场速报（无 Markdown、无请示口吻、符合消防公文要求）
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
        : '灭火救援作战动态';

    final address = incident?.info['address']?.toString().trim();
    final objectLine = (address != null && address.isNotEmpty)
        ? '事发对象：$address'
        : '事发对象：现场核实中';

    // 一、力量到场与阵地部署
    final forceSummary = _buildForceSummary(incident, forces);
    final tacticalProgress = extractTacticalProgress(notes);
    final deploymentLine = tacticalProgress != null && tacticalProgress.isNotEmpty
        ? '现场部署：$tacticalProgress'
        : '现场部署：阵地展开就位，各项处置正在推进。';

    // 二、内攻人员及空呼管控
    final airSummary = extractAirSafetySummary(entries, nowMillis: dt.millisecondsSinceEpoch);
    final airSafetyText = _buildAirSafetyText(airSummary, entries);

    // 三、搜救排查与人员伤亡
    final searchProgress = _findCategoryProgress(notes, '搜救');
    final casualtyText = searchProgress != null && searchProgress.isNotEmpty
        ? '$searchProgress，暂无人员伤亡报告。'
        : '内攻搜救组正在持续排查，截至目前未发现被困人员，暂无人员伤亡。';

    final buffer = StringBuffer();
    buffer.writeln('【火场态势速报】$title（$timeStr）');
    buffer.writeln(objectLine);
    buffer.writeln();
    buffer.writeln('一、到场力量与战术部署');
    buffer.writeln(forceSummary);
    buffer.writeln(deploymentLine);
    buffer.writeln();
    buffer.writeln('二、内攻作业与空呼安全');
    buffer.writeln(airSafetyText);
    buffer.writeln();
    buffer.writeln('三、搜救排查与人员伤亡');
    buffer.writeln(casualtyText);

    return sanitizeBriefText(buffer.toString().trim());
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

    return '参战力量：首批出动力量已到场，力量正在展开。';
  }

  static String _buildAirSafetyText(
    AirSafetySummary summary,
    List<Entry> entries,
  ) {
    if (!summary.hasActive) {
      return '现场内攻人员：暂无在场内攻作业人员，外围阵地严密防范。';
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

  static String? _findCategoryProgress(List<Note> notes, String category) {
    if (notes.isEmpty) return null;
    for (final n in notes.reversed) {
      if (n.category == category && n.text.trim().isNotEmpty) {
        return n.text.trim();
      }
    }
    return null;
  }

  /// 遵循 AGENTS.md 脱敏规范，过滤敏感字段
  static String sanitizeBriefText(String text) {
    var result = text;
    // 隐藏特定密钥与验证码敏感串
    result = result.replaceAll(RegExp(r'(验证码|密码|token)[:：=]\s*[a-zA-Z0-9]+', caseSensitive: false), '验证码: ****');
    return result;
  }
}
