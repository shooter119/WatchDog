import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/external_incident.dart';
import '../data/models/incident.dart';
import 'widgets/incident_category_chip.dart';
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
final RegExp _warningHighlightPattern = RegExp(r'被困|伤|危|泄漏|燃气|煤气|爆炸');

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

/// 合并自建活跃警情与外部接警记录，执行辖区隔离、终态防误标与全文检索过滤。
List<IncidentPickerItem> buildIncidentPickerItems({
  required List<Incident> activeIncidents,
  required List<ExternalIncident> externalIncidents,
  required String? userUnitName,
  required String searchKeyword,
  required void Function(Incident incident) onSelectLocal,
  required void Function(ExternalIncident incident) onClaimExternal,
  DateTime? now,
}) {
  final customItems = <IncidentPickerItem>[];
  for (final inc in activeIncidents) {
    final hasExt = inc.info['external_id'] != null ||
        externalIncidents.any(
          (e) => e.incidentNumber == inc.number || e.claimedIncidentId == inc.id,
        );
    if (hasExt) continue;

    final cardData = IncidentCardViewModel.fromIncident(inc, now: now);
    final cleanedLoc = cardData.hasRealLocation ? cardData.locationText : '';
    final terminalLabel =
        cardData.officialStatus.isNotEmpty ? cardData.officialStatus : '已归队';
    final fallbackLoc = cardData.isTerminalStatus
        ? terminalLabel
        : (inc.unresolvedActiveCount > 0
              ? '${inc.unresolvedActiveCount}人处置中'
              : '内部自建现场');
    final locationText = cleanedLoc.isNotEmpty ? cleanedLoc : fallbackLoc;
    final highlights = cardData.isTerminalStatus && cleanedLoc.isNotEmpty
        ? <String>[terminalLabel]
        : const <String>[];

    customItems.add(
      IncidentPickerItem(
        key: 'custom_${inc.id}',
        category: cardData.category,
        eventTitle: inc.displayName,
        districtTag: '自建',
        locationText: locationText,
        timeText: formatPickerTimestampMs(inc.createdAt, now: now),
        forceTags: const <String>[],
        factHighlights: highlights,
        searchCorpus: <String>[inc.number, locationText, ...highlights]
            .where((e) => e.trim().isNotEmpty)
            .join(' '),
        badgeText: '进入',
        isClaimed: true,
        isCustom: true,
        onTap: () => onSelectLocal(inc),
      ),
    );
  }

  final externalItems = <IncidentPickerItem>[];
  for (final ext in externalIncidents) {
    if (!matchesExternalUnit(ext, userUnitName)) continue;

    Incident? matched;
    for (final local in activeIncidents) {
      if (local.id == ext.claimedIncidentId ||
          local.number == ext.incidentNumber ||
          local.info['external_id'] == ext.externalId) {
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
        timeText: formatPickerTimestampMs(ext.registerTime, now: now),
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

  final allItems = <IncidentPickerItem>[...customItems, ...externalItems];
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

/// Design System v3.0 警情选择卡片（三层信息架构：事件主标题 / 辖区地点时间 / 力量与状态胶囊）。
class IncidentPickerCard extends StatelessWidget {
  const IncidentPickerCard({super.key, required this.item, this.enabled = true});

  final IncidentPickerItem item;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final hasExtraChips =
        item.forceTags.isNotEmpty || item.factHighlights.isNotEmpty;
    final cautionPair = colors.statusColors(DsStatus.caution);
    final districtBg = item.isCustom ? cautionPair.pillBg : colors.surfaceMuted;
    final districtFg = item.isCustom ? cautionPair.text : colors.textSecondary;

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md + 2,
        vertical: DsSpacing.md,
      ),
      onTap: enabled ? item.onTap : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              IncidentCategoryIconBadge(
                key: Key('ext-category-badge-${item.key}-${item.category.name}'),
                category: item.category,
                size: 38,
                iconSize: 20,
              ),
              const SizedBox(width: DsSpacing.sm + 2),
              Expanded(
                child: IncidentAntiOrphanText(
                  text: item.eventTitle,
                  style: typo.title.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              Container(
                key: Key('picker-enter-pill-${item.key}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.sm,
                  vertical: DsSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: colors.brand.withValues(alpha: 0.12),
                  borderRadius: DsRadius.borderPill,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      item.badgeText,
                      style: typo.micro.copyWith(
                        color: colors.brandText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: DsSizes.iconSm,
                      color: colors.brandText,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          Row(
            children: <Widget>[
              if (item.districtTag.isNotEmpty)
                Container(
                  key: Key('picker-district-tag-${item.key}'),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: districtBg,
                    borderRadius: DsRadius.borderSm,
                  ),
                  child: Text(
                    item.districtTag,
                    style: typo.micro.copyWith(
                      color: districtFg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        item.locationText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.caption.copyWith(color: colors.textSecondary),
                      ),
                    ),
                    if (item.timeText.isNotEmpty)
                      Flexible(
                        flex: 0,
                        child: Text(
                          ' · ${item.timeText}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.captionTabular.copyWith(
                            color: colors.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (hasExtraChips) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            Wrap(
              key: Key('ext-forces-wrap-${item.key}'),
              spacing: 6,
              runSpacing: DsSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final forceTag in item.forceTags)
                  Container(
                    constraints: const BoxConstraints(minHeight: 26),
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.sm,
                      vertical: DsSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: DsRadius.borderPill,
                      border: Border.all(color: colors.border, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.local_shipping_outlined,
                          size: DsSizes.iconSm,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: DsSpacing.xs),
                        Flexible(
                          child: Text(
                            forceTag,
                            style: typo.micro.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final highlight in item.factHighlights)
                  _buildHighlightPill(highlight),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHighlightPill(String highlight) {
    if (highlight == '处置中') {
      return StatusPill(
        status: DsStatus.safe,
        label: highlight,
        icon: Icons.play_circle_outline_rounded,
      );
    }
    if (_warningHighlightPattern.hasMatch(highlight)) {
      return StatusPill(
        status: DsStatus.caution,
        label: highlight,
        icon: Icons.warning_amber_rounded,
      );
    }
    if (IncidentCardViewModel.isTerminalOfficialStatus(highlight)) {
      return StatusPill(
        status: DsStatus.neutral,
        label: highlight,
        icon: Icons.check_circle_outline_rounded,
      );
    }
    return StatusPill(
      status: DsStatus.neutral,
      label: highlight,
      icon: Icons.info_outline_rounded,
    );
  }
}
