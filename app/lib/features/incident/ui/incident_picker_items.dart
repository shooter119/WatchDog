import 'package:flutter/foundation.dart';

import '../../../design_system/design_system.dart';
import '../data/models/external_incident.dart';
import '../data/models/incident.dart';
import 'widgets/incident_category_style.dart';

/// 警情选择页统一卡片数据项（合并自建进行中警情与外部接警记录）。
@immutable
class IncidentPickerItem {
  const IncidentPickerItem({
    required this.key,
    required this.category,
    required this.eventTitle,
    required this.districtTag,
    required this.locationText,
    required this.timeText,
    this.sortTimestampMs = 0,
    this.orderIndex = 0,
    required this.forceTags,
    required this.factHighlights,
    required this.searchCorpus,
    required this.badgeText,
    required this.isClaimed,
    required this.isCustom,
    required this.onTap,
  });

  final String key, eventTitle, districtTag, locationText, timeText;
  final String searchCorpus, badgeText;
  final int sortTimestampMs, orderIndex;
  final DsIncidentCategory category;
  final List<String> forceTags, factHighlights;
  final bool isClaimed, isCustom;
  final VoidCallback onTap;
}

final RegExp _districtPattern = RegExp(
  r'([\u4e00-\u9fa5]{2,6}?(?:区|县|县级市|旗|高新区|经开区|新区|保税区|示范区))',
);
final RegExp _unitKeywordPattern = RegExp(
  r'([\u4e00-\u9fa5]{2,6}?(?:区|县|县级市|旗|高新区|经开区|新区|示范区))(?:消防救援)?(?:大队|站|中队)?',
);

/// 格式化毫秒时间戳为紧凑可读时间（今日/昨日/月-日 时:分）。
String formatPickerTimestampMs(int timestampMs, {DateTime? now}) {
  if (timestampMs <= 0) return '';
  return IncidentCardViewModel.formatDateTime(
    DateTime.fromMillisecondsSinceEpoch(timestampMs),
    now: now,
  );
}

/// 解析外部警情的属地行政区标签。
String resolveExternalDistrict(ExternalIncident ext) {
  final rawDist = ext.districtName.trim();
  if (rawDist.isNotEmpty &&
      rawDist != '市辖区' &&
      rawDist != '本级' &&
      rawDist != '市辖县') {
    return rawDist;
  }
  for (final src in <String>[ext.crimeAddress, ext.brigadeName, ext.squadronName]) {
    if (src.isEmpty) continue;
    final match = _districtPattern.firstMatch(src);
    if (match != null) return match.group(1)!;
  }
  return ext.detachmentName.trim().isNotEmpty ? ext.detachmentName.trim() : '本辖区';
}

/// 按用户所属大队进行辖区强隔离匹配，同时放行跨区增援。
bool matchesExternalUnit(ExternalIncident ext, String? userUnitName) {
  if (userUnitName == null || userUnitName.trim().isEmpty) return true;
  final unit = userUnitName.trim();
  if (unit.contains('支队') || unit.contains('总队') || unit.contains('指挥中心')) {
    return true;
  }
  final cleaned = unit
      .replaceFirst(RegExp(r'^[\u4e00-\u9fa5]{2,5}(?:省|自治区)'), '')
      .replaceFirst(
        RegExp(r'^[\u4e00-\u9fa5]{2,5}市(?=[\u4e00-\u9fa5]{1,6}(?:区|县|旗|市))'),
        '',
      );
  final kw = _unitKeywordPattern.firstMatch(cleaned)?.group(1);
  if (kw == null || kw.isEmpty) return true;

  return resolveExternalDistrict(ext).contains(kw) ||
      ext.locationDisplay.contains(kw) ||
      ext.brigadeName.contains(kw) ||
      ext.squadronName.contains(kw) ||
      ext.districtName.contains(kw) ||
      ext.crimeAddress.contains(kw) ||
      ext.dispatchedForces.any((f) => f.stationName.contains(kw)) ||
      ext.incidentDescribe.contains(kw);
}

bool _matchesExternalIncident(Incident local, ExternalIncident ext) {
  final claimedId = (ext.claimedIncidentId ?? '').trim();
  if (claimedId.isNotEmpty && local.id == claimedId) return true;

  final localExtId = (local.info['external_id']?.toString() ?? '').trim();
  final extId = ext.externalId.trim();
  if (localExtId.isNotEmpty && extId.isNotEmpty && localExtId == extId) {
    return true;
  }

  final extNumber = ext.incidentNumber.trim();
  if (extNumber.isNotEmpty) {
    final localExtNumber =
        (local.info['external_incident_number']?.toString() ?? '').trim();
    if (localExtNumber.isNotEmpty && localExtNumber == extNumber) {
      return true;
    }
    if (local.number.trim() == extNumber) {
      return true;
    }
  }
  return false;
}

int _resolveLocalIncidentSortTimeMs(Incident inc) {
  final rawReceivedAt = (inc.info['received_at']?.toString() ?? '').trim();
  if (rawReceivedAt.isNotEmpty) {
    final parsed = DateTime.tryParse(rawReceivedAt);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
    final asInt = int.tryParse(rawReceivedAt);
    if (asInt != null && asInt > 0) return asInt;
  }
  return inc.createdAt;
}

/// 合并自建活跃警情与外部接警记录，执行辖区隔离、多维去重、终态防误标、统一时间倒序与全文检索过滤。
List<IncidentPickerItem> buildIncidentPickerItems({
  required List<Incident> activeIncidents,
  required List<ExternalIncident> externalIncidents,
  required String? userUnitName,
  required String searchKeyword,
  required void Function(Incident incident) onSelectLocal,
  required void Function(ExternalIncident incident) onClaimExternal,
  DateTime? now,
}) {
  final localOnlyItems = <IncidentPickerItem>[];
  var orderCursor = 0;
  for (final inc in activeIncidents) {
    final hasExt = externalIncidents.any(
      (e) => _matchesExternalIncident(inc, e),
    );
    if (hasExt) continue;

    final isExternalBacked =
        (inc.info['external_id']?.toString() ?? '').trim().isNotEmpty ||
        (inc.info['external_incident_number']?.toString() ?? '')
            .trim()
            .isNotEmpty ||
        (inc.info['external_source']?.toString() ?? '').trim().isNotEmpty;
    final cardData = IncidentCardViewModel.fromIncident(inc, now: now);
    final cleanedLoc = cardData.hasRealLocation ? cardData.locationText : '';
    final terminalLabel =
        cardData.officialStatus.isNotEmpty ? cardData.officialStatus : '已归队';
    final fallbackLoc = cardData.isTerminalStatus
        ? terminalLabel
        : (inc.unresolvedActiveCount > 0
              ? '${inc.unresolvedActiveCount}人处置中'
              : (isExternalBacked ? '派警现场' : '内部自建现场'));
    final locationText = cleanedLoc.isNotEmpty ? cleanedLoc : fallbackLoc;
    final highlights = <String>[
      if (cardData.isTerminalStatus && cleanedLoc.isNotEmpty)
        terminalLabel
      else if (!cardData.isTerminalStatus && isExternalBacked)
        '处置中',
    ];
    final sortTimeMs = _resolveLocalIncidentSortTimeMs(inc);
    final externalDistrict =
        (inc.info['administrative_area']?.toString() ?? '').trim();
    final districtTag = isExternalBacked
        ? (externalDistrict.isNotEmpty ? externalDistrict : '派警')
        : '自建';

    localOnlyItems.add(
      IncidentPickerItem(
        key: 'custom_${inc.id}',
        category: cardData.category,
        eventTitle: inc.displayName,
        districtTag: districtTag,
        locationText: locationText,
        timeText: formatPickerTimestampMs(sortTimeMs, now: now),
        sortTimestampMs: sortTimeMs,
        orderIndex: orderCursor++,
        forceTags: const <String>[],
        factHighlights: highlights,
        searchCorpus: <String>[inc.number, locationText, ...highlights]
            .where((e) => e.trim().isNotEmpty)
            .join(' '),
        badgeText: '进入',
        isClaimed: true,
        isCustom: !isExternalBacked,
        onTap: () => onSelectLocal(inc),
      ),
    );
  }

  final externalItems = <IncidentPickerItem>[];
  for (final ext in externalIncidents) {
    if (!matchesExternalUnit(ext, userUnitName)) continue;

    Incident? matched;
    for (final local in activeIncidents) {
      if (_matchesExternalIncident(local, ext)) {
        matched = local;
        break;
      }
    }

    final isClaimed = ext.claimed || matched != null;
    final eventTitle = ext.effectiveEventTitle;
    final forceTags = ext.compactForceTags;
    final sanitized = IncidentCardViewModel.sanitizeOfficialStatus(ext.officialStatus);
    final officialStatus = sanitized.isNotEmpty
        ? sanitized
        : IncidentCardViewModel.sanitizeOfficialStatus(ext.incidentStatus);
    final matchedData =
        matched != null ? IncidentCardViewModel.fromIncident(matched, now: now) : null;
    final effectiveOfficial =
        officialStatus.isNotEmpty ? officialStatus : (matchedData?.officialStatus ?? '');
    final isReturned =
        IncidentCardViewModel.isTerminalOfficialStatus(effectiveOfficial) ||
        (matchedData?.isTerminalStatus ?? false);

    final highlights = <String>[];
    final candidates = ext.factHighlights.isNotEmpty
        ? ext.factHighlights
        : <String>[
            if (ext.incidentLevel.trim().isNotEmpty) ext.incidentLevel.trim(),
            if (effectiveOfficial.isNotEmpty) effectiveOfficial,
          ];
    for (final raw in candidates) {
      final item = raw.trim();
      if (item.isEmpty || item == '其他' || item == '处置中') continue;
      if (isReturned && item.contains('处置')) continue;
      if (eventTitle.contains(item) || highlights.contains(item)) continue;
      highlights.add(item);
      if (highlights.length >= 3) break;
    }

    if (isReturned) {
      highlights.removeWhere((t) => t.contains('处置'));
      final terminalLabel = (effectiveOfficial.isNotEmpty && !effectiveOfficial.contains('处置'))
          ? effectiveOfficial
          : (matchedData != null &&
                    matchedData.officialStatus.isNotEmpty &&
                    !matchedData.officialStatus.contains('处置'))
                ? matchedData.officialStatus
                : '已归队';
      highlights
        ..remove(terminalLabel)
        ..insert(0, terminalLabel);
    } else if (isClaimed) {
      highlights
        ..remove('处置中')
        ..insert(0, '处置中');
    }

    final matchedIncident = matched;
    final sortTimeMs = ext.registerTime > 0
        ? ext.registerTime
        : (matchedIncident != null
              ? _resolveLocalIncidentSortTimeMs(matchedIncident)
              : 0);
    externalItems.add(
      IncidentPickerItem(
        key: 'ext_${ext.externalId}',
        category: IncidentCategoryStyle.classify(
          disasterCategory: ext.disasterCategory,
          category: ext.incidentType,
          specificType:
              ext.specificType.isNotEmpty ? ext.specificType : ext.disposalObjectName,
          situation: ext.situationSummary,
          title: eventTitle,
        ),
        eventTitle: eventTitle,
        districtTag: resolveExternalDistrict(ext),
        locationText: ext.effectiveLocation,
        timeText: formatPickerTimestampMs(sortTimeMs, now: now),
        sortTimestampMs: sortTimeMs,
        orderIndex: orderCursor++,
        forceTags: forceTags,
        factHighlights: highlights,
        searchCorpus: <String>[
          ext.incidentNumber,
          ext.crimeAddress,
          ext.incidentType,
          ext.specificType,
          ext.disposalObjectName,
          ext.squadronName,
          ext.brigadeName,
          ext.incidentDescribe,
          ext.situationSummary,
          ...forceTags,
          ...highlights,
        ].where((e) => e.trim().isNotEmpty).join(' '),
        badgeText: '进入',
        isClaimed: isClaimed,
        isCustom: false,
        onTap: () => (isClaimed && matchedIncident != null)
            ? onSelectLocal(matchedIncident)
            : onClaimExternal(ext),
      ),
    );
  }

  final allItems = <IncidentPickerItem>[...localOnlyItems, ...externalItems]
    ..sort((a, b) {
      final timeCmp = b.sortTimestampMs.compareTo(a.sortTimestampMs);
      if (timeCmp != 0) return timeCmp;
      return a.orderIndex.compareTo(b.orderIndex);
    });
  final query = searchKeyword.trim().toLowerCase();
  if (query.isEmpty) return allItems;
  return allItems.where((item) {
    return item.eventTitle.toLowerCase().contains(query) ||
        item.locationText.toLowerCase().contains(query) ||
        item.districtTag.toLowerCase().contains(query) ||
        item.searchCorpus.toLowerCase().contains(query) ||
        item.badgeText.toLowerCase().contains(query);
  }).toList();
}
