import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_widgets.dart';

/// 警情三大视觉分类：灭火、抢险、救助。
///
/// 空白自建警情默认归入 [IncidentCategory.fire]，可通过「警情调整」切换。
enum IncidentCategory {
  fire,
  rescue,
  aid;

  String get label => switch (this) {
    IncidentCategory.fire => '灭火',
    IncidentCategory.rescue => '抢险',
    IncidentCategory.aid => '救助',
  };

  String get defaultCategoryName => switch (this) {
    IncidentCategory.fire => '火灾扑救',
    IncidentCategory.rescue => '抢险救援',
    IncidentCategory.aid => '社会救助',
  };

  /// 运行期动态读取主题色，禁止固化为编译期常量或静态字段。
  Color get iconColor => switch (this) {
    IncidentCategory.fire => AppColors.incidentFire,
    IncidentCategory.rescue => AppColors.incidentRescue,
    IncidentCategory.aid => AppColors.incidentAid,
  };

  Color get textColor => switch (this) {
    IncidentCategory.fire => AppColors.incidentFireText,
    IncidentCategory.rescue => AppColors.incidentRescueText,
    IncidentCategory.aid => AppColors.incidentAidText,
  };

  Color get surfaceColor => switch (this) {
    IncidentCategory.fire => AppColors.incidentFireSurface,
    IncidentCategory.rescue => AppColors.incidentRescueSurface,
    IncidentCategory.aid => AppColors.incidentAidSurface,
  };

  static IncidentCategory classify({
    String category = '',
    String specificType = '',
    String situation = '',
    String title = '',
  }) {
    final primary = '$category $specificType'.trim();
    if (_containsAny(primary, const ['社会救助', '公务执勤', '安保'])) {
      return IncidentCategory.aid;
    }
    if (_containsAny(primary, const ['抢险救援', '反恐排爆'])) {
      return IncidentCategory.rescue;
    }
    if (_containsAny(primary, const ['火灾扑救', '灭火'])) {
      return IncidentCategory.fire;
    }

    final combined = '$primary $situation $title';
    if (_containsAny(combined, _aidKeywords)) {
      return IncidentCategory.aid;
    }
    if (_containsAny(combined, _rescueKeywords)) {
      return IncidentCategory.rescue;
    }
    if (_containsAny(combined, _fireKeywords)) {
      return IncidentCategory.fire;
    }
    return IncidentCategory.fire;
  }

  static bool _containsAny(String source, List<String> keywords) {
    for (final kw in keywords) {
      if (source.contains(kw)) return true;
    }
    return false;
  }

  static const _aidKeywords = <String>[
    '社会救助',
    '马蜂',
    '蜂窝',
    '戒指',
    '开门',
    '开锁',
    '电梯困人',
    '困电梯',
    '抓蛇',
    '捕蛇',
    '动物',
    '送水',
    '摘除',
    '取物',
    '公务执勤',
    '执勤',
    '安保',
    '帮扶',
    '求助',
  ];

  static const _rescueKeywords = <String>[
    '抢险',
    '救援',
    '车祸',
    '交通事故',
    '追尾',
    '翻车',
    '侧翻',
    '破拆',
    '坍塌',
    '倒塌',
    '泄漏',
    '漏油',
    '危化',
    '溺水',
    '落水',
    '水域',
    '山岳',
    '排涝',
    '内涝',
    '滑坡',
    '泥石流',
    '台风',
    '地震',
    '塌方',
    '坠井',
    '被卡',
    '卡手',
    '反恐',
    '排爆',
  ];

  static const _fireKeywords = <String>['火', '燃', '烟', '爆', '扑救'];
}

/// 警情三大类 SVG 矢量徽标组件（零第三方运行时依赖，几何与 assets/icons/*.svg 保持一致）。
class IncidentCategoryBadge extends StatelessWidget {
  final IncidentCategory category;
  final double size;
  final double iconSize;

  const IncidentCategoryBadge({
    super.key,
    required this.category,
    this.size = 40,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = category.iconColor;
    final surfaceColor = category.surfaceColor;
    return Semantics(
      label: '${category.label}类警情',
      image: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: iconColor.withValues(alpha: 0.22),
            width: 1,
          ),
        ),
        child: SizedBox.square(
          dimension: iconSize,
          child: CustomPaint(
            painter: _IncidentCategorySvgPainter(
              category: category,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _IncidentCategorySvgPainter extends CustomPainter {
  final IncidentCategory category;
  final Color color;

  const _IncidentCategorySvgPainter({
    required this.category,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 24.0;
    final offset = Offset(
      (size.width - 24.0 * scale) / 2.0,
      (size.height - 24.0 * scale) / 2.0,
    );
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;

    final path = switch (category) {
      IncidentCategory.fire => _firePath(),
      IncidentCategory.rescue => _rescuePath(),
      IncidentCategory.aid => _aidPath(),
    };
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  static Path _firePath() {
    return Path()
      ..moveTo(12.3, 2.2)
      ..cubicTo(14.6, 4.7, 17.8, 8.0, 17.8, 12.7)
      ..cubicTo(17.8, 16.8, 15.1, 20.2, 12.0, 20.8)
      ..cubicTo(8.9, 20.2, 6.2, 16.8, 6.2, 12.7)
      ..cubicTo(6.2, 10.3, 7.1, 8.1, 8.4, 6.4)
      ..cubicTo(8.4, 7.9, 9.1, 9.2, 10.2, 9.9)
      ..cubicTo(9.8, 7.3, 10.6, 4.5, 12.3, 2.2)
      ..close()
      ..moveTo(12.1, 11.4)
      ..cubicTo(11.1, 12.9, 10.4, 14.1, 10.4, 15.3)
      ..cubicTo(10.4, 16.7, 11.1, 17.7, 12.0, 17.7)
      ..cubicTo(12.9, 17.7, 13.6, 16.7, 13.6, 15.3)
      ..cubicTo(13.6, 13.8, 12.9, 12.6, 12.1, 11.4)
      ..close();
  }

  static Path _rescuePath() {
    return Path()
      ..moveTo(12, 2.4)
      ..lineTo(19.8, 6.2)
      ..lineTo(19.8, 12.4)
      ..cubicTo(19.8, 16.8, 16.5, 19.9, 12, 21.4)
      ..cubicTo(7.5, 19.9, 4.2, 16.8, 4.2, 12.4)
      ..lineTo(4.2, 6.2)
      ..close()
      ..moveTo(13.1, 6.4)
      ..lineTo(8.4, 12.6)
      ..lineTo(11.7, 12.6)
      ..lineTo(10.7, 17.6)
      ..lineTo(15.6, 11.2)
      ..lineTo(12.2, 11.2)
      ..close();
  }

  static Path _aidPath() {
    return Path()
      ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 9.5))
      ..moveTo(10.6, 7.0)
      ..lineTo(10.6, 10.6)
      ..lineTo(7.0, 10.6)
      ..lineTo(7.0, 13.4)
      ..lineTo(10.6, 13.4)
      ..lineTo(10.6, 17.0)
      ..lineTo(13.4, 17.0)
      ..lineTo(13.4, 13.4)
      ..lineTo(17.0, 13.4)
      ..lineTo(17.0, 10.6)
      ..lineTo(13.4, 10.6)
      ..lineTo(13.4, 7.0)
      ..close();
  }

  @override
  bool shouldRepaint(covariant _IncidentCategorySvgPainter oldDelegate) {
    return oldDelegate.category != category || oldDelegate.color != color;
  }
}

/// 自适应防孤字文本组件：检测多行末行是否仅剩单个字符（如“村/号”孤字掉行），
/// 自动收窄单字宽度的排版边界使前字下移伴行，不篡改文本内容。
class AntiOrphanText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;

  const AntiOrphanText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final fontSize = style.fontSize ?? 14.0;
        if (!maxWidth.isFinite || maxWidth <= fontSize * 6) {
          return Text(
            text,
            style: style,
            maxLines: maxLines,
            overflow: overflow,
            softWrap: true,
          );
        }

        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        final effectiveWidth = _resolveAntiOrphanWidth(
          text: text,
          style: style,
          maxWidth: maxWidth,
          fontSize: fontSize,
          scaler: scaler,
          direction: direction,
          maxLines: maxLines,
        );

        final textWidget = Text(
          text,
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          softWrap: true,
        );
        if (effectiveWidth == null) return textWidget;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: effectiveWidth),
          child: textWidget,
        );
      },
    );
  }

  static double? _resolveAntiOrphanWidth({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required double fontSize,
    required TextScaler scaler,
    required TextDirection direction,
    int? maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: scaler,
      textDirection: direction,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);

    final metrics = painter.computeLineMetrics();
    if (metrics.length < 2) return null;

    final lastLineText = _lastLineText(painter, text, metrics.last);
    if (lastLineText.runes.length != 1) return null;

    final step = scaler.scale(fontSize) * 1.35;
    final candidateWidth = maxWidth - step;
    if (candidateWidth < scaler.scale(fontSize) * 4) return null;

    final adjustedPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: scaler,
      textDirection: direction,
      maxLines: maxLines,
    )..layout(maxWidth: candidateWidth);

    final adjustedMetrics = adjustedPainter.computeLineMetrics();
    if (adjustedMetrics.length < 2) return null;
    if (maxLines != null && adjustedMetrics.length > maxLines) return null;

    final adjustedLastLine = _lastLineText(
      adjustedPainter,
      text,
      adjustedMetrics.last,
    );
    if (adjustedLastLine.runes.length >= 2) {
      return candidateWidth;
    }
    return null;
  }

  static String _lastLineText(
    TextPainter painter,
    String text,
    LineMetrics lastMetric,
  ) {
    final pos = painter.getPositionForOffset(
      Offset(0, lastMetric.baseline),
    );
    final range = painter.getLineBoundary(pos);
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    return text.substring(start, end).trim();
  }
}

/// 首页警情卡二次清洗模型：统一提取【事件、地点、时间】三要素及展开态详情。
class IncidentCardData {
  final IncidentCategory category;
  final String eventTitle;
  final String locationText;
  final bool hasRealLocation;
  final String timeText;
  final String rawCategoryPill;
  final String officialStatus;
  final bool isTerminalStatus;
  final List<String> extraTags;
  final List<String> extraNotes;

  const IncidentCardData({
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
    const exactTerms = {
      '归队',
      '已归队',
      '结案',
      '已结案',
      '填报',
      '完成',
      '已完成',
      '结束',
      '注销',
      '作废',
      '虚警',
      '假警',
    };
    if (exactTerms.contains(normalized)) return true;
    return normalized.contains('归队') ||
        normalized.contains('结案') ||
        normalized.contains('填报');
  }

  static String cleanLocation(String raw) {
    var addr = raw.trim();
    if (addr.isEmpty) return '';
    // 剥离冗余省级/自治区前缀
    addr = addr.replaceFirst(RegExp(r'^[\u4e00-\u9fa5]{2,5}(?:省|自治区)\s*'), '');
    // 当后续已含区/县/县级市时，剥离冗余地级市前缀
    addr = addr.replaceFirst(
      RegExp(r'^[\u4e00-\u9fa5]{2,5}市\s*(?=[\u4e00-\u9fa5]{2,5}(?:区|县|市))'),
      '',
    );
    // 消除相邻重复叠加的区县前缀
    addr = addr.replaceFirstMapped(
      RegExp(r'^([\u4e00-\u9fa5]{2,5}(?:区|县|市))\1'),
      (m) => m.group(1)!,
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
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => desc);
    return first.length > 24 ? '${first.substring(0, 23)}…' : first;
  }

  static String _compact(String value) =>
      value.replaceAll(RegExp(r'\s+'), '');

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

    final ref = (now ?? DateTime.now()).toLocal();
    final isToday =
        dt.year == ref.year && dt.month == ref.month && dt.day == ref.day;
    final yesterday = ref.subtract(const Duration(days: 1));
    final isYesterday =
        dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day;

    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    if (isToday) return '今日 $h:$min';
    if (isYesterday) return '昨日 $h:$min';
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    if (dt.year == ref.year) return '$m-$d $h:$min';
    return '${dt.year}-$m-$d $h:$min';
  }

  factory IncidentCardData.fromIncident(Incident incident, {DateTime? now}) {
    final info = incident.info;
    var rawCategory =
        (info['original_category']?.toString() ??
                info['level']?.toString() ??
                '')
            .trim();
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

    final rawTitle = (incident.title ?? '').trim();
    final rawLoc = (info['location']?.toString() ?? '').trim();
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

    String resolvedLocation;
    bool hasRealLocation;
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

    String eventTitle;
    if (rawTitle.isNotEmpty && !titleIsAddress) {
      eventTitle = rawTitle;
    } else {
      final candidateFromSit = situationEventParts
          .map(_cleanEventFragment)
          .firstWhere(
            (s) =>
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

    // 避免展开态 extraNotes 重复展示已经作为事件标题的同一句话
    extraNotes.removeWhere(
      (note) => _compact(_cleanEventFragment(note)) == _compact(eventTitle),
    );
    extraTags.removeWhere((tag) => _compact(tag) == _compact(eventTitle));

    final category = IncidentCategory.classify(
      category: rawCategory,
      specificType: specificType,
      situation: situation,
      title: eventTitle,
    );

    return IncidentCardData(
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
      extraTags: extraTags,
      extraNotes: extraNotes,
    );
  }
}
