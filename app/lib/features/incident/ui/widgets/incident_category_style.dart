import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/incident.dart';
import '../../data/models/incident_force.dart';

/// DS v3.0 警情分类视觉色组（动态响应昼白/暗曜主题）。
@immutable
class IncidentCategoryPalette {
  const IncidentCategoryPalette({
    required this.fill,
    required this.text,
    required this.surface,
    required this.border,
  });

  final Color fill;
  final Color text;
  final Color surface;
  final Color border;
}

/// 警情三大类别（灭火 / 抢险 / 救助）的 DS v3.0 映射与智能归类工具。
///
/// 全面取代旧 `widgets/incident_category_badge.dart` 中的 `IncidentCategory`，
/// 与 M0 [DsIncidentCategory] 统一，严禁硬编码旧主题颜色。
class IncidentCategoryStyle {
  IncidentCategoryStyle._();

  static String labelOf(DsIncidentCategory category) => switch (category) {
    DsIncidentCategory.fire => '灭火',
    DsIncidentCategory.rescue => '抢险',
    DsIncidentCategory.aid => '救助',
  };

  static String defaultCategoryNameOf(DsIncidentCategory category) =>
      switch (category) {
        DsIncidentCategory.fire => '火灾扑救',
        DsIncidentCategory.rescue => '抢险救援',
        DsIncidentCategory.aid => '社会救助',
      };

  static IconData iconOf(DsIncidentCategory category) => switch (category) {
    DsIncidentCategory.fire => Icons.local_fire_department_rounded,
    DsIncidentCategory.rescue => Icons.handyman_rounded,
    DsIncidentCategory.aid => Icons.medical_services_outlined,
  };

  /// 按当前 [DsColors] 动态解析分类色板。
  static IncidentCategoryPalette paletteOf(
    DsIncidentCategory category,
    DsColors colors,
  ) {
    switch (category) {
      case DsIncidentCategory.fire:
        final pair = colors.statusColors(DsStatus.alarm);
        return IncidentCategoryPalette(
          fill: pair.fill,
          text: pair.text,
          surface: pair.pillBg,
          border: pair.fill.withValues(alpha: 0.28),
        );
      case DsIncidentCategory.rescue:
        final pair = colors.statusColors(DsStatus.caution);
        return IncidentCategoryPalette(
          fill: pair.fill,
          text: pair.text,
          surface: pair.pillBg,
          border: pair.fill.withValues(alpha: 0.30),
        );
      case DsIncidentCategory.aid:
        return IncidentCategoryPalette(
          fill: colors.brand,
          text: colors.brandText,
          surface: colors.brand.withValues(alpha: 0.12),
          border: colors.brand.withValues(alpha: 0.28),
        );
    }
  }

  /// 按显式字段 -> 主类别 -> 现场描述关键词归入火灾/抢险/救助，缺省归为火灾扑救。
  static DsIncidentCategory classify({
    String? disasterCategory,
    String category = '',
    String specificType = '',
    String situation = '',
    String title = '',
  }) {
    final explicit = (disasterCategory ?? '').trim().toLowerCase();
    if (explicit == 'fire') return DsIncidentCategory.fire;
    if (explicit == 'rescue') return DsIncidentCategory.rescue;
    if (explicit == 'aid') return DsIncidentCategory.aid;

    final primary = '$category $specificType'.trim();
    if (_containsAny(primary, const <String>['社会救助', '公务执勤', '安保'])) {
      return DsIncidentCategory.aid;
    }
    if (_containsAny(primary, const <String>['抢险救援', '反恐排爆'])) {
      return DsIncidentCategory.rescue;
    }
    if (_containsAny(primary, const <String>['火灾扑救', '灭火'])) {
      return DsIncidentCategory.fire;
    }

    final combined = '$primary $situation $title';
    if (_containsAny(combined, _aidKeywords)) return DsIncidentCategory.aid;
    if (_containsAny(combined, _rescueKeywords)) {
      return DsIncidentCategory.rescue;
    }
    if (_containsAny(combined, _fireKeywords)) return DsIncidentCategory.fire;
    return DsIncidentCategory.fire;
  }

  static bool _containsAny(String source, List<String> keywords) {
    for (final kw in keywords) {
      if (source.contains(kw)) return true;
    }
    return false;
  }

  static const List<String> _aidKeywords = <String>[
    '社会救助', '马蜂', '蜂窝', '戒指', '开门', '开锁', '电梯困人', '困电梯',
    '抓蛇', '捕蛇', '动物', '送水', '摘除', '取物', '公务执勤', '执勤',
    '安保', '帮扶', '求助',
  ];

  static const List<String> _rescueKeywords = <String>[
    '抢险', '救援', '车祸', '交通事故', '追尾', '翻车', '侧翻', '破拆',
    '坍塌', '倒塌', '泄漏', '漏油', '危化', '溺水', '落水', '水域',
    '山岳', '排涝', '内涝', '滑坡', '泥石流', '台风', '地震', '塌方',
    '坠井', '被卡', '卡手', '反恐', '排爆',
  ];

  static const List<String> _fireKeywords = <String>[
    '火', '燃', '烟', '爆', '扑救',
  ];
}

/// 警情态势卡清洗视图模型：统一提取【事件、地点、时间】与终态判定。
@immutable
class IncidentCardViewModel {
  const IncidentCardViewModel({
    required this.category,
    required this.eventTitle,
    required this.locationText,
    required this.hasRealLocation,
    required this.timeText,
    required this.rawCategoryPill,
    required this.officialStatus,
    required this.isTerminalStatus,
    required this.extraTags,
    required this.extraNotes,
  });

  final DsIncidentCategory category;
  final String eventTitle;
  final String locationText;
  final bool hasRealLocation;
  final String timeText;
  final String rawCategoryPill;
  final String officialStatus;
  final bool isTerminalStatus;
  final List<String> extraTags;
  final List<String> extraNotes;

  static String sanitizeOfficialStatus(String raw) {
    final s = raw.trim();
    if (s.isEmpty || s == '其他' || s == '真警') return '';
    return s;
  }

  static bool isTerminalOfficialStatus(
    String status, {
    bool incidentActive = true,
  }) {
    if (!incidentActive) return true;
    final normalized = status.replaceAll(RegExp(r'\s+'), '').trim();
    if (normalized.isEmpty) return false;
    const exactTerms = <String>{
      '归队', '已归队', '结案', '已结案', '填报', '完成', '已完成',
      '结束', '注销', '作废', '虚警', '假警',
    };
    if (exactTerms.contains(normalized)) return true;
    return normalized.contains('归队') ||
        normalized.contains('结案') ||
        normalized.contains('填报');
  }

  static String cleanLocation(String raw) {
    var addr = raw.trim();
    if (addr.isEmpty) return '';
    addr = addr.replaceFirst(RegExp(r'^[\u4e00-\u9fa5]{2,5}(?:省|自治区)\s*'), '');
    addr = addr.replaceFirst(
      RegExp(r'^[\u4e00-\u9fa5]{2,5}市\s*(?=[\u4e00-\u9fa5]{2,5}(?:区|县|市))'),
      '',
    );
    addr = addr.replaceFirstMapped(
      RegExp(r'^([\u4e00-\u9fa5]{2,5}(?:区|县|市))\1'),
      (Match m) => m.group(1)!,
    );
    return addr.trim();
  }

  static String _cleanEventFragment(String raw) {
    var desc = raw.trim();
    if (desc.isEmpty) return '';
    desc = desc
        .replaceAll(RegExp(r'官方状态[:：][^，。；·\n]+'), '')
        .replaceAll(
          RegExp(r'[，,。；;·\s]*(?:暂)?无人员(?:被困|伤亡|受伤)[，,。；;·\s]*'),
          '，',
        )
        .replaceAll(RegExp(r'[，,。；;·\s]*人员被困情况不明[，,。；;·\s]*'), '，')
        .replaceAll(RegExp(r'[，,。；;·\s]*(?:群众|电话)?报警[，,。；;·\s]*'), '，')
        .replaceAll(RegExp(r'[，,。；;·\s]*110转警[，,。；;·\s]*'), '，')
        .replaceAll(RegExp(r'^[，,。；;·\s]+|[，,。；;·\s]+$'), '')
        .replaceAll(RegExp(r'，{2,}'), '，');
    if (desc.isEmpty) return '';
    if (desc.length <= 26) return desc;
    final first = desc
        .split(RegExp(r'[，。；;\n]'))
        .map((String s) => s.trim())
        .firstWhere((String s) => s.isNotEmpty, orElse: () => desc);
    return first.length > 24 ? '${first.substring(0, 23)}…' : first;
  }

  static String _compact(String value) =>
      value.replaceAll(RegExp(r'\s+'), '');

  static String formatDateTime(DateTime dt, {DateTime? now}) {
    final local = dt.toLocal();
    final ref = (now ?? DateTime.now()).toLocal();
    final isToday =
        local.year == ref.year &&
        local.month == ref.month &&
        local.day == ref.day;
    final yesterday = ref.subtract(const Duration(days: 1));
    final isYesterday =
        local.year == yesterday.year &&
        local.month == yesterday.month &&
        local.day == yesterday.day;

    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    if (isToday) return '今日 $h:$min';
    if (isYesterday) return '昨日 $h:$min';
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    if (local.year == ref.year) return '$m-$d $h:$min';
    return '${local.year}-$m-$d $h:$min';
  }

  static String formatIncidentTime(Incident incident, {DateTime? now}) {
    DateTime? dt;
    final rawReceived = (incident.info['received_at']?.toString() ?? '').trim();
    if (rawReceived.isNotEmpty) {
      dt = DateTime.tryParse(rawReceived)?.toLocal();
    }
    if (dt == null && incident.createdAt > 0) {
      dt = DateTime.fromMillisecondsSinceEpoch(incident.createdAt).toLocal();
    }
    if (dt == null) return '时间待补充';
    return formatDateTime(dt, now: now);
  }

  static String formatCompactForces(
    List<IncidentForce> forces, {
    String? dispatchSummary,
  }) {
    if (forces.isNotEmpty) {
      final parts = <String>[];
      for (final force in forces.take(2)) {
        final name = force.stationName.trim();
        if (name.isEmpty) continue;
        final counts = StringBuffer();
        if (force.vehicleCountKnown) counts.write('${force.vehicleCount}车');
        if (force.personnelCountKnown) counts.write('${force.personnelCount}人');
        parts.add(counts.isEmpty ? '$name 待补充' : '$name $counts');
      }
      if (parts.isNotEmpty) {
        if (forces.length > 2) {
          return '${parts.join(' · ')} 等${forces.length}支队';
        }
        return parts.join(' · ');
      }
    }
    return (dispatchSummary ?? '').trim();
  }

  factory IncidentCardViewModel.fromIncident(
    Incident incident, {
    DateTime? now,
  }) {
    final info = incident.info;
    var rawCategory =
        (info['original_category']?.toString() ??
                info['level']?.toString() ??
                '')
            .trim();
    final explicitCategory = (info['disaster_category']?.toString() ?? '').trim();
    final rawEventSummary = (info['event_summary']?.toString() ?? '').trim();
    final specificType = (info['specific_type']?.toString() ?? '').trim();
    var officialStatus = sanitizeOfficialStatus(
      info['incident_status']?.toString() ?? '',
    );
    final situation = (info['situation']?.toString() ?? '').trim();
    final extraTags = <String>[];
    final extraNotes = <String>[];
    final situationEventParts = <String>[];

    final officialStatusReg = RegExp(r'^官方状态[:：]\s*(.+)$');
    if (situation.isNotEmpty) {
      for (final rawPart in situation.split('·')) {
        final part = rawPart.trim();
        if (part.isEmpty) continue;
        final match = officialStatusReg.firstMatch(part);
        if (match != null) {
          if (officialStatus.isEmpty) {
            officialStatus = sanitizeOfficialStatus(match.group(1)!);
          }
          continue;
        }
        situationEventParts.add(part);
        if (part == rawCategory) continue;
        if (rawCategory.isEmpty && part.length <= 16) {
          rawCategory = part;
        } else if (part.length <= 16) {
          extraTags.add(part);
        } else {
          extraNotes.add(part);
        }
      }
    }

    for (final factKey in const <String>[
      'trapped',
      'injured',
      'hazardous_materials',
    ]) {
      final val = (info[factKey]?.toString() ?? '').trim();
      if (val.isEmpty ||
          val == '无人员被困' ||
          val == '无人员伤亡' ||
          val == '无人员受伤' ||
          extraTags.contains(val) ||
          extraNotes.contains(val)) {
        continue;
      }
      if (val.length <= 16) {
        extraTags.add(val);
      } else {
        extraNotes.add(val);
      }
    }

    final rawTitle = (incident.title ?? '').trim();
    final rawLoc = <Object?>[
      info['location'],
      info['address'],
      info['location_display'],
      info['crime_address'],
    ]
        .map((Object? v) => (v?.toString() ?? '').trim())
        .firstWhere(
          (String v) => v.isNotEmpty && v != '地点待补充' && v != 'null',
          orElse: () => '',
        );
    final cleanedLoc = cleanLocation(rawLoc);
    final cleanedTitleAsLoc = cleanLocation(rawTitle);

    final compactLoc = _compact(cleanedLoc);
    final compactTitle = _compact(cleanedTitleAsLoc);
    final titleIsAddress =
        rawTitle.isNotEmpty &&
        cleanedLoc.isNotEmpty &&
        (compactLoc.contains(compactTitle) ||
            compactTitle.contains(compactLoc) ||
            _compact(rawLoc).contains(_compact(rawTitle)) ||
            _compact(rawTitle).contains(_compact(rawLoc)));

    final String resolvedLocation;
    final bool hasRealLocation;
    if (titleIsAddress) {
      resolvedLocation = compactLoc.length >= compactTitle.length
          ? cleanedLoc
          : cleanedTitleAsLoc;
      hasRealLocation = resolvedLocation.isNotEmpty;
    } else if (cleanedLoc.isNotEmpty) {
      resolvedLocation = cleanedLoc;
      hasRealLocation = true;
    } else {
      resolvedLocation = '地点待补充';
      hasRealLocation = false;
    }

    final String eventTitle;
    if (rawTitle.isNotEmpty && !titleIsAddress) {
      eventTitle = rawTitle;
    } else if (rawEventSummary.isNotEmpty &&
        _compact(rawEventSummary) != _compact(resolvedLocation)) {
      eventTitle = rawEventSummary;
    } else {
      final candidateFromSit = situationEventParts
          .map(_cleanEventFragment)
          .firstWhere(
            (String s) =>
                s.isNotEmpty &&
                _compact(s) != _compact(resolvedLocation) &&
                _compact(s) != _compact(rawCategory),
            orElse: () => '',
          );
      if (candidateFromSit.isNotEmpty) {
        eventTitle = candidateFromSit;
      } else if (rawCategory.isNotEmpty &&
          specificType.isNotEmpty &&
          specificType != '其他' &&
          !rawCategory.contains(specificType)) {
        eventTitle = '$rawCategory（$specificType）';
      } else if (specificType.isNotEmpty && specificType != '其他') {
        eventTitle = specificType;
      } else if (rawCategory.isNotEmpty) {
        eventTitle = rawCategory;
      } else {
        eventTitle = incident.displayName;
      }
    }

    extraNotes.removeWhere(
      (String note) =>
          _compact(_cleanEventFragment(note)) == _compact(eventTitle),
    );
    extraTags.removeWhere((String tag) => _compact(tag) == _compact(eventTitle));

    final category = IncidentCategoryStyle.classify(
      disasterCategory: explicitCategory,
      category: rawCategory,
      specificType: specificType,
      situation: situation,
      title: eventTitle,
    );

    return IncidentCardViewModel(
      category: category,
      eventTitle: eventTitle,
      locationText: resolvedLocation,
      hasRealLocation: hasRealLocation,
      timeText: formatIncidentTime(incident, now: now),
      rawCategoryPill: rawCategory,
      officialStatus: officialStatus,
      isTerminalStatus: isTerminalOfficialStatus(
        officialStatus,
        incidentActive: incident.isActive,
      ),
      extraTags: List<String>.unmodifiable(extraTags),
      extraNotes: List<String>.unmodifiable(extraNotes),
    );
  }
}
