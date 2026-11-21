/// 大队级自建水源类别枚举。
enum WaterSourceCategory {
  hydrant('hydrant', '市政消火栓', '消火栓'),
  natural('natural', '天然水源', '天然水源'),
  pumpConnector('pump_connector', '水泵接合器', '接合器');

  final String apiValue;
  final String label;
  final String shortLabel;

  const WaterSourceCategory(this.apiValue, this.label, this.shortLabel);

  static WaterSourceCategory fromApi(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'natural':
        return WaterSourceCategory.natural;
      case 'pump_connector':
        return WaterSourceCategory.pumpConnector;
      case 'hydrant':
      default:
        return WaterSourceCategory.hydrant;
    }
  }
}

/// 水源二元可用状态枚举。
enum WaterSourceStatus {
  available('available', '可用'),
  unavailable('unavailable', '不可用');

  final String apiValue;
  final String label;

  const WaterSourceStatus(this.apiValue, this.label);

  static WaterSourceStatus fromApi(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'unavailable':
        return WaterSourceStatus.unavailable;
      case 'available':
      default:
        return WaterSourceStatus.available;
    }
  }
}

/// 天然水源（含消防水池）取水方式枚举。
enum WaterIntakeMethod {
  portablePump('portable_pump', '手抬泵吸水', '手抬泵'),
  fireTruck('fire_truck', '消防车靠近取水', '消防车取水'),
  remoteSupply('remote_supply', '远程供水系统直接取水', '远程供水');

  final String apiValue;
  final String label;
  final String shortLabel;

  const WaterIntakeMethod(this.apiValue, this.label, this.shortLabel);

  static WaterIntakeMethod? tryFromApi(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'portable_pump':
        return WaterIntakeMethod.portablePump;
      case 'fire_truck':
        return WaterIntakeMethod.fireTruck;
      case 'remote_supply':
        return WaterIntakeMethod.remoteSupply;
      default:
        return null;
    }
  }
}

/// 大队级自建水源点位（全库统一 GCJ-02 坐标系）。
class WaterSource {
  final String id;
  final String unitId;
  final WaterSourceCategory category;
  final String name;
  final double lat;
  final double lng;
  final WaterSourceStatus status;
  final List<WaterIntakeMethod> intakeMethods;
  final String note;
  final String createdBy;
  final String createdByName;
  final int createdAt;
  final String updatedBy;
  final String updatedByName;
  final int updatedAt;
  final int? deletedAt;
  final String? deletedBy;
  final String? deletedByName;

  const WaterSource({
    required this.id,
    this.unitId = '',
    required this.category,
    required this.name,
    required this.lat,
    required this.lng,
    this.status = WaterSourceStatus.available,
    this.intakeMethods = const [],
    this.note = '',
    this.createdBy = '',
    this.createdByName = '',
    this.createdAt = 0,
    this.updatedBy = '',
    this.updatedByName = '',
    this.updatedAt = 0,
    this.deletedAt,
    this.deletedBy,
    this.deletedByName,
  });

  bool get isAvailable => status == WaterSourceStatus.available;

  bool get hasNote => note.trim().isNotEmpty;

  /// 提取备注首行非空文本，用于列表卡片首屏外露关键提示（如缺闷盖、水压偏低、水池容量）。
  String get firstNoteLine {
    if (note.trim().isEmpty) return '';
    for (final line in note.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  /// 最近操作人展示名（优先更新人，回退创建人）。
  String get latestActorName {
    final updater = updatedByName.trim();
    if (updater.isNotEmpty) return updater;
    final creator = createdByName.trim();
    if (creator.isNotEmpty) return creator;
    return '系统导入';
  }

  factory WaterSource.fromJson(Map<String, dynamic> json) {
    final rawMethods = json['intake_methods'];
    final methods = <WaterIntakeMethod>[];
    if (rawMethods is List) {
      for (final item in rawMethods) {
        final parsed = WaterIntakeMethod.tryFromApi(item?.toString());
        if (parsed != null && !methods.contains(parsed)) {
          methods.add(parsed);
        }
      }
    }

    int parseInt(Object? value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    int? parseNullableInt(Object? value) {
      if (value == null) return null;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    double parseDouble(Object? value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0;
    }

    return WaterSource(
      id: (json['id'] ?? '').toString(),
      unitId: (json['unit_id'] ?? '').toString(),
      category: WaterSourceCategory.fromApi(json['category']?.toString()),
      name: (json['name'] ?? '').toString(),
      lat: parseDouble(json['lat']),
      lng: parseDouble(json['lng']),
      status: WaterSourceStatus.fromApi(json['status']?.toString()),
      intakeMethods: List.unmodifiable(methods),
      note: (json['note'] ?? '').toString(),
      createdBy: (json['created_by'] ?? '').toString(),
      createdByName: (json['created_by_name'] ?? '').toString(),
      createdAt: parseInt(json['created_at']),
      updatedBy: (json['updated_by'] ?? '').toString(),
      updatedByName: (json['updated_by_name'] ?? '').toString(),
      updatedAt: parseInt(json['updated_at']),
      deletedAt: parseNullableInt(json['deleted_at']),
      deletedBy: json['deleted_by']?.toString(),
      deletedByName: json['deleted_by_name']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'unit_id': unitId,
    'category': category.apiValue,
    'name': name,
    'lat': lat,
    'lng': lng,
    'status': status.apiValue,
    'intake_methods': intakeMethods.map((m) => m.apiValue).toList(),
    'note': note,
    'created_by': createdBy,
    'created_by_name': createdByName,
    'created_at': createdAt,
    'updated_by': updatedBy,
    'updated_by_name': updatedByName,
    'updated_at': updatedAt,
    'deleted_at': deletedAt,
    'deleted_by': deletedBy,
    'deleted_by_name': deletedByName,
  };

  WaterSource copyWith({
    String? id,
    String? unitId,
    WaterSourceCategory? category,
    String? name,
    double? lat,
    double? lng,
    WaterSourceStatus? status,
    List<WaterIntakeMethod>? intakeMethods,
    String? note,
    String? createdBy,
    String? createdByName,
    int? createdAt,
    String? updatedBy,
    String? updatedByName,
    int? updatedAt,
    int? deletedAt,
    String? deletedBy,
    String? deletedByName,
  }) {
    return WaterSource(
      id: id ?? this.id,
      unitId: unitId ?? this.unitId,
      category: category ?? this.category,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      status: status ?? this.status,
      intakeMethods: intakeMethods != null
          ? List.unmodifiable(intakeMethods)
          : this.intakeMethods,
      note: note ?? this.note,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      createdAt: createdAt ?? this.createdAt,
      updatedBy: updatedBy ?? this.updatedBy,
      updatedByName: updatedByName ?? this.updatedByName,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      deletedBy: deletedBy ?? this.deletedBy,
      deletedByName: deletedByName ?? this.deletedByName,
    );
  }
}

/// 单位水源统计摘要。
class WaterSourceSummary {
  final int total;
  final int available;
  final int unavailable;
  final int hydrant;
  final int natural;
  final int pumpConnector;

  const WaterSourceSummary({
    this.total = 0,
    this.available = 0,
    this.unavailable = 0,
    this.hydrant = 0,
    this.natural = 0,
    this.pumpConnector = 0,
  });

  factory WaterSourceSummary.fromJson(Map<String, dynamic> json) {
    int parseInt(Object? value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    final byCategory = json['by_category'] is Map
        ? Map<String, dynamic>.from(json['by_category'] as Map)
        : const <String, dynamic>{};

    return WaterSourceSummary(
      total: parseInt(json['total']),
      available: parseInt(json['available']),
      unavailable: parseInt(json['unavailable']),
      hydrant: parseInt(byCategory['hydrant']),
      natural: parseInt(byCategory['natural']),
      pumpConnector: parseInt(byCategory['pump_connector']),
    );
  }

  factory WaterSourceSummary.fromItems(List<WaterSource> items) {
    var available = 0;
    var unavailable = 0;
    var hydrant = 0;
    var natural = 0;
    var pumpConnector = 0;
    for (final item in items) {
      if (item.isAvailable) {
        available++;
      } else {
        unavailable++;
      }
      switch (item.category) {
        case WaterSourceCategory.hydrant:
          hydrant++;
        case WaterSourceCategory.natural:
          natural++;
        case WaterSourceCategory.pumpConnector:
          pumpConnector++;
      }
    }
    return WaterSourceSummary(
      total: items.length,
      available: available,
      unavailable: unavailable,
      hydrant: hydrant,
      natural: natural,
      pumpConnector: pumpConnector,
    );
  }
}

/// `GET /api/water-sources` 响应模型。
class WaterSourceListResult {
  final List<WaterSource> items;
  final WaterSourceSummary summary;

  const WaterSourceListResult({required this.items, required this.summary});

  factory WaterSourceListResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map((m) => WaterSource.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
        : const <WaterSource>[];
    final summary = json['summary'] is Map
        ? WaterSourceSummary.fromJson(
            Map<String, dynamic>.from(json['summary'] as Map),
          )
        : WaterSourceSummary.fromItems(items);
    return WaterSourceListResult(items: items, summary: summary);
  }
}
