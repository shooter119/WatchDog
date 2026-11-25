class ExternalDispatchedForce {
  final String stationName;
  final int? vehicleCount;
  final int? personnelCount;
  final String deploymentStatus;

  const ExternalDispatchedForce({
    required this.stationName,
    this.vehicleCount,
    this.personnelCount,
    this.deploymentStatus = 'dispatched',
  });

  String get compactLabel {
    final name = stationName.trim();
    if (name.isEmpty) return '';
    final buf = StringBuffer(name);
    if (vehicleCount != null || personnelCount != null) {
      buf.write(' ');
      if (vehicleCount != null) buf.write('$vehicleCount车');
      if (personnelCount != null) buf.write('$personnelCount人');
    }
    return buf.toString();
  }

  factory ExternalDispatchedForce.fromJson(Map<String, dynamic> json) =>
      ExternalDispatchedForce(
        stationName: json['station_name']?.toString().trim() ?? '',
        vehicleCount: (json['vehicle_count'] as num?)?.toInt(),
        personnelCount: (json['personnel_count'] as num?)?.toInt(),
        deploymentStatus: json['deployment_status']?.toString() ?? 'dispatched',
      );

  Map<String, dynamic> toJson() => {
    'station_name': stationName,
    'vehicle_count': vehicleCount,
    'personnel_count': personnelCount,
    'deployment_status': deploymentStatus,
  };
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
  final String alarmPhone;
  final String alarmPersonPhone;
  final String alarmPersonName;
  final String alarmModeName;
  final String incidentNatureName;
  final String dispatchVehicle;
  final String dispatchOrganization;
  final String eventSummary;
  final String disasterCategory;
  final String specificType;
  final String locationDisplay;
  final String officialStatus;
  final String situationDetail;
  final String trapped;
  final String injured;
  final String hazardousMaterials;
  final String dispatchSummary;
  final List<ExternalDispatchedForce> dispatchedForces;
  final List<String> factHighlights;
  final String aiStatus;
  final String rawMergedText;
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
    this.alarmPhone = '',
    this.alarmPersonPhone = '',
    this.alarmPersonName = '',
    this.alarmModeName = '',
    this.incidentNatureName = '',
    this.dispatchVehicle = '',
    this.dispatchOrganization = '',
    this.eventSummary = '',
    this.disasterCategory = '',
    this.specificType = '',
    this.locationDisplay = '',
    this.officialStatus = '',
    this.situationDetail = '',
    this.trapped = '',
    this.injured = '',
    this.hazardousMaterials = '',
    this.dispatchSummary = '',
    this.dispatchedForces = const [],
    this.factHighlights = const [],
    this.aiStatus = '',
    this.rawMergedText = '',
    this.claimed = false,
    this.claimedIncidentId,
    this.claimedIncidentNumber,
    this.claimedIncidentTitle,
  });

  String get effectiveEventTitle {
    if (eventSummary.trim().isNotEmpty) return eventSummary.trim();
    final cleanedDescribe = _cleanFallbackDescribeTitle(
      incidentDescribe,
      crimeAddress,
      extraAddress: locationDisplay,
    );
    if (cleanedDescribe.isNotEmpty) return cleanedDescribe;
    if (disposalObjectName.trim().isNotEmpty &&
        disposalObjectName.trim() != '其他') {
      return incidentType.trim().isNotEmpty
          ? '${incidentType.trim()}（${disposalObjectName.trim()}）'
          : disposalObjectName.trim();
    }
    if (incidentType.trim().isNotEmpty && incidentType.trim() != '其他') {
      return incidentType.trim();
    }
    if (crimeAddress.trim().isNotEmpty) return crimeAddress.trim();
    return incidentNumber;
  }

  /// 对未经过服务端重整或缺少 `eventSummary` 的原始接警描述做轻量清洗，
  /// 剥离时间、接警单位套话、重复地址和尾部出动时间线，避免标题展示超长通报。
  static String _cleanFallbackDescribeTitle(
    String rawDesc,
    String rawAddress, {
    String extraAddress = '',
  }) {
    var desc = rawDesc.replaceAll('\r\n', '\n').trim();
    if (desc.isEmpty) return '';

    final leadingPunct = RegExp(r'^[\s，,。；;：:、·]+');
    final leadingDispatchHeader = RegExp(
      r'^(?:[^\s，,。；;：:\n]{1,24}?(?:消防救援站|专职消防队|专职队|特勤站|战保站|消防站|救援站|中队|大队|支队|站|队))?警情出动(?:[（(][^）)\n]{1,30}[）)])?[：:，,、\s]*',
    );
    final leadingTimestamp = RegExp(
      r'^(?:(?:\d{4}[年/-]\d{1,2}[月/-]\d{1,2}日?|\d{1,2}月\d{1,2}日?)\s*(?:\d{1,2}(?:[:：]\d{1,2}(?:[:：]\d{1,2})?|[时点]\d{1,2}分?(?:\d{1,2}秒?)?|时)?(?:\s*(?:许|左右))?)?|\d{1,2}(?:[:：]\d{1,2}(?:[:：]\d{1,2})?|[时点]\d{1,2}分?(?:\d{1,2}秒?)?|时\s*(?:许|左右))(?:\s*(?:许|左右))?)[，,、\s]*',
    );
    final leadingDispatchOrg = RegExp(
      r'^(?:[^\s，,。；;：:\n]{1,24}?(?:支队|大队|中队|救援站|消防站|分指挥中心|指挥中心|调度中心|调度室|值班室)\s*)?接(?:到)?[^，,。；;：:\n]{0,16}?(?:报警人?|转警|警情|通知|指令|接警)(?:[^，,。；;：:\n]{0,10}?称[：:，,\s]*|[：:，,]+)',
    );
    final leadingDispatchAlt = RegExp(
      r'^(?:[^\s，,。；;：:\n]{0,24}?(?:支队|大队|中队|救援站|消防站|分指挥中心|指挥中心|调度中心|调度室|值班室|119|110|群众|报警人)\s*)(?:(?:报警|转警|警情|通知|指令|接警)(?:称[：:，,\s]*|[：:，,]+)|称[：:，,\s]+)',
    );
    final leadingAboveAddr = RegExp(
      r'^(?:[（(]?位于[）)]?\s*)?(?:上述地址|上址)[：:，,\s]*',
    );

    // 1) 最多循环 3 轮剥离前导通报头、时间戳、接警套话及（位于）上述地址前缀
    for (var i = 0; i < 3; i++) {
      final before = desc;
      desc = desc.replaceFirst(leadingPunct, '');
      desc = desc.replaceFirst(leadingDispatchHeader, '');
      desc = desc.replaceFirst(leadingTimestamp, '');
      desc = desc.replaceFirst(leadingPunct, '');
      desc = desc.replaceFirst(leadingDispatchOrg, '');
      desc = desc.replaceFirst(leadingDispatchAlt, '');
      desc = desc.replaceFirst(leadingAboveAddr, '');
      desc = desc.replaceFirst(leadingPunct, '');
      if (desc == before) break;
    }

    // 2) 去掉前导“位于”，若以归一化后非空 address（>=4字）开头且余文去标点仍 >=4 字，则剥离重复地址前缀
    desc = desc.replaceFirst(RegExp(r'^位于[：:\s]*'), '').trim();
    if (desc.isEmpty) return '';

    final addrCandidates = <String>{};
    for (final source in [rawAddress, extraAddress]) {
      final trimmed = source.trim();
      if (trimmed.isEmpty) continue;
      void addCandidate(String value) {
        final v = value.trim();
        if (v.length >= 4) addrCandidates.add(v);
      }

      addCandidate(trimmed);
      final compact = trimmed.replaceAll(RegExp(r'\s+'), '');
      addCandidate(compact);

      final normalized = compact
          .replaceFirst(RegExp(r'^[\u4e00-\u9fa5]{2,5}(?:省|自治区)'), '')
          .replaceFirst(
            RegExp(r'^[\u4e00-\u9fa5]{2,5}市(?=[\u4e00-\u9fa5]{2,5}(?:区|县|市))'),
            '',
          )
          .replaceFirstMapped(
            RegExp(r'^([\u4e00-\u9fa5]{2,5}(?:区|县|市))\1'),
            (m) => m.group(1)!,
          );
      addCandidate(normalized);

      final withoutDistrict = normalized.replaceFirst(
        RegExp(r'^[\u4e00-\u9fa5]{2,5}(?:区|县|市)'),
        '',
      );
      addCandidate(withoutDistrict);

      for (final base in [compact, normalized, withoutDistrict]) {
        final withoutSuffix = base.replaceFirst(
          RegExp(r'(?:附近|一带|旁边|对面|路口)$'),
          '',
        );
        addCandidate(withoutSuffix);
      }
    }

    final sortedCandidates = addrCandidates.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final addr in sortedCandidates) {
      if (desc.startsWith(addr)) {
        final rest = desc
            .substring(addr.length)
            .replaceFirst(RegExp(r'^[，,。；;：:、·\s]+'), '');
        final effectiveLen = rest
            .replaceAll(RegExp(r'[，,。；;：:、·\s！？!?（）()【】\[\]]'), '')
            .length;
        if (effectiveLen >= 4) {
          desc = rest;
        }
        break;
      }
    }

    // 3) 截断“接到报警后…”或“某站出动X车…”及之后派警时间线
    desc = desc.replaceFirst(
      RegExp(
        r'(?:[，,。；;、\s]*)(?:接到?(?:报警|转警|警情|指令|通知)后|接警后).*$',
        dotAll: true,
      ),
      '',
    );
    desc = desc.replaceFirst(
      RegExp(
        r'(?:[，,。；;、\s]+|^)(?:(?:立即|迅速|随即)?(?:调派|派出(?!所)|增派|加派|指令|由)\s*)?[^，,。；;、\s]{1,32}?(?:消防救援站|特勤站|专职消防队|专职队|消防站|救援站|中队|大队|支队|产业园|化工园|集聚区|站|队)\s*(?:立即|迅速|随即)?出动\s*(?:\d+|[一二两三四五六七八九十]+)\s*(?:辆|台|车).*$',
        dotAll: true,
      ),
      '',
    );
    desc = desc.replaceFirst(
      RegExp(
        r'(?:[，,。；;、\s]+|^)(?:[^，,。；;、\s]{0,16}?(?:支队|大队|指挥中心|调度中心)\s*)?(?:立即|迅速|随即)?(?:调派|派出(?!所)|增派|加派)[^，,。；;、\s]{1,24}(?:站|队|大队|中队|产业园|化工园|集聚区).*$',
        dotAll: true,
      ),
      '',
    );

    // 4) 去除“官方状态:…”、“（暂）无人员被困/伤亡”及多余标点，取首分句并限制最长 24 字
    desc = desc
        .replaceAll(RegExp(r'官方状态[:：][^，。；·\n]+'), '')
        .replaceAll(
          RegExp(r'[，,。；;·\s]*(?:目前)?(?:暂)?无(?:其他)?人员(?:被困|伤亡|受伤)[，,。；;·\s]*'),
          '，',
        )
        .replaceAll(RegExp(r'[，,。；;·\s]*人员被困情况不明[，,。；;·\s]*'), '，')
        .replaceAll(RegExp(r'[，,。；;·\s]*(?:群众|电话)?报警[，,。；;·\s]*'), '，')
        .replaceAll(RegExp(r'[，,。；;·\s]*110转警[，,。；;·\s]*'), '，')
        .replaceAll(RegExp(r'^[，,。；;·：:\s]+|[，,。；;·：:\s]+$'), '')
        .replaceAll(RegExp(r'，{2,}'), '，');

    if (desc.isEmpty) return '';
    if (desc.length <= 24) return desc;
    final firstClause = desc
        .split(RegExp(r'[，。；;\n]'))
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => desc);
    return firstClause.length > 24
        ? '${firstClause.substring(0, 23)}…'
        : firstClause;
  }

  String get effectiveLocation {
    if (locationDisplay.trim().isNotEmpty) return locationDisplay.trim();
    if (crimeAddress.trim().isNotEmpty) return crimeAddress.trim();
    return districtName.trim();
  }

  List<String> get compactForceTags {
    final tags = <String>[];
    for (final f in dispatchedForces) {
      final label = f.compactLabel;
      if (label.isNotEmpty) tags.add(label);
    }
    if (tags.isEmpty && dispatchSummary.trim().isNotEmpty) {
      tags.add(dispatchSummary.trim());
    } else if (tags.isEmpty && squadronName.trim().isNotEmpty) {
      tags.add(squadronName.trim());
    }
    return tags;
  }

  String get situationSummary {
    if (situationDetail.trim().isNotEmpty) return situationDetail.trim();
    if (incidentDescribe.trim().isNotEmpty) return incidentDescribe.trim();
    if (disposalObjectName.isNotEmpty && disposalObjectName != '其他') {
      return '$incidentType($disposalObjectName)';
    }
    return incidentType;
  }

  factory ExternalIncident.fromJson(Map<String, dynamic> json) {
    final rawForces = json['dispatched_forces'];
    final forces = rawForces is List
        ? rawForces
              .whereType<Map>()
              .map(
                (item) => ExternalDispatchedForce.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((f) => f.stationName.isNotEmpty)
              .toList()
        : const <ExternalDispatchedForce>[];
    final rawHighlights = json['fact_highlights'];
    final highlights = rawHighlights is List
        ? rawHighlights
              .map((e) => e?.toString().trim() ?? '')
              .where((e) => e.isNotEmpty)
              .toList()
        : const <String>[];

    return ExternalIncident(
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
      alarmPhone: json['alarm_phone']?.toString() ?? '',
      alarmPersonPhone: json['alarm_person_phone']?.toString() ?? '',
      alarmPersonName: json['alarm_person_name']?.toString() ?? '',
      alarmModeName: json['alarm_mode_name']?.toString() ?? '',
      incidentNatureName: json['incident_nature_name']?.toString() ?? '',
      dispatchVehicle: json['dispatch_vehicle']?.toString() ?? '',
      dispatchOrganization: json['dispatch_organization']?.toString() ?? '',
      eventSummary: json['event_summary']?.toString() ?? '',
      disasterCategory: json['disaster_category']?.toString() ?? '',
      specificType: json['specific_type']?.toString() ?? '',
      locationDisplay: json['location_display']?.toString() ?? '',
      officialStatus: json['official_status']?.toString() ?? '',
      situationDetail: json['situation_detail']?.toString() ?? '',
      trapped: json['trapped']?.toString() ?? '',
      injured: json['injured']?.toString() ?? '',
      hazardousMaterials: json['hazardous_materials']?.toString() ?? '',
      dispatchSummary: json['dispatch_summary']?.toString() ?? '',
      dispatchedForces: forces,
      factHighlights: highlights,
      aiStatus: json['ai_status']?.toString() ?? '',
      rawMergedText: json['raw_merged_text']?.toString() ?? '',
      claimed: json['claimed'] == true,
      claimedIncidentId: json['claimed_incident_id']?.toString(),
      claimedIncidentNumber: json['claimed_incident_number']?.toString(),
      claimedIncidentTitle: json['claimed_incident_title']?.toString(),
    );
  }

  ExternalIncident copyWithClaimed({
    required bool claimed,
    String? claimedIncidentId,
    String? claimedIncidentNumber,
    String? claimedIncidentTitle,
  }) {
    return ExternalIncident(
      externalId: externalId,
      incidentNumber: incidentNumber,
      detachmentName: detachmentName,
      brigadeName: brigadeName,
      squadronName: squadronName,
      districtName: districtName,
      incidentType: incidentType,
      disposalObjectName: disposalObjectName,
      incidentLevel: incidentLevel,
      incidentStatus: incidentStatus,
      crimeAddress: crimeAddress,
      incidentDescribe: incidentDescribe,
      registerTime: registerTime,
      latitude: latitude,
      longitude: longitude,
      alarmPhone: alarmPhone,
      alarmPersonPhone: alarmPersonPhone,
      alarmPersonName: alarmPersonName,
      alarmModeName: alarmModeName,
      incidentNatureName: incidentNatureName,
      dispatchVehicle: dispatchVehicle,
      dispatchOrganization: dispatchOrganization,
      eventSummary: eventSummary,
      disasterCategory: disasterCategory,
      specificType: specificType,
      locationDisplay: locationDisplay,
      officialStatus: officialStatus,
      situationDetail: situationDetail,
      trapped: trapped,
      injured: injured,
      hazardousMaterials: hazardousMaterials,
      dispatchSummary: dispatchSummary,
      dispatchedForces: dispatchedForces,
      factHighlights: factHighlights,
      aiStatus: aiStatus,
      rawMergedText: rawMergedText,
      claimed: claimed,
      claimedIncidentId: claimedIncidentId ?? this.claimedIncidentId,
      claimedIncidentNumber:
          claimedIncidentNumber ?? this.claimedIncidentNumber,
      claimedIncidentTitle: claimedIncidentTitle ?? this.claimedIncidentTitle,
    );
  }

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
    if (alarmPhone.isNotEmpty) 'alarm_phone': alarmPhone,
    if (alarmPersonPhone.isNotEmpty) 'alarm_person_phone': alarmPersonPhone,
    if (alarmPersonName.isNotEmpty) 'alarm_person_name': alarmPersonName,
    if (alarmModeName.isNotEmpty) 'alarm_mode_name': alarmModeName,
    if (incidentNatureName.isNotEmpty)
      'incident_nature_name': incidentNatureName,
    if (dispatchVehicle.isNotEmpty) 'dispatch_vehicle': dispatchVehicle,
    if (dispatchOrganization.isNotEmpty)
      'dispatch_organization': dispatchOrganization,
    if (eventSummary.isNotEmpty) 'event_summary': eventSummary,
    if (disasterCategory.isNotEmpty) 'disaster_category': disasterCategory,
    if (specificType.isNotEmpty) 'specific_type': specificType,
    if (locationDisplay.isNotEmpty) 'location_display': locationDisplay,
    if (officialStatus.isNotEmpty) 'official_status': officialStatus,
    if (situationDetail.isNotEmpty) 'situation_detail': situationDetail,
    if (trapped.isNotEmpty) 'trapped': trapped,
    if (injured.isNotEmpty) 'injured': injured,
    if (hazardousMaterials.isNotEmpty)
      'hazardous_materials': hazardousMaterials,
    if (dispatchSummary.isNotEmpty) 'dispatch_summary': dispatchSummary,
    if (dispatchedForces.isNotEmpty)
      'dispatched_forces': dispatchedForces.map((e) => e.toJson()).toList(),
    if (factHighlights.isNotEmpty) 'fact_highlights': factHighlights,
    if (aiStatus.isNotEmpty) 'ai_status': aiStatus,
    if (rawMergedText.isNotEmpty) 'raw_merged_text': rawMergedText,
    'claimed': claimed,
    if (claimedIncidentId != null) 'claimed_incident_id': claimedIncidentId,
    if (claimedIncidentNumber != null)
      'claimed_incident_number': claimedIncidentNumber,
    if (claimedIncidentTitle != null)
      'claimed_incident_title': claimedIncidentTitle,
  };
}
