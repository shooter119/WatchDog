class UnitMember {
  final String id;
  final String unitId;
  final String realName;
  final String role;
  final String status;
  final String reviewStatus;
  final String stationName;
  final String phone;
  final String applyReason;
  final int createdAt;
  final bool inRoster;

  const UnitMember({
    required this.id,
    required this.unitId,
    required this.realName,
    required this.role,
    required this.status,
    required this.reviewStatus,
    this.stationName = '',
    this.phone = '',
    this.applyReason = '',
    this.createdAt = 0,
    this.inRoster = false,
  });

  factory UnitMember.fromJson(Map<String, dynamic> json) {
    return UnitMember(
      id: json['id'] as String? ?? '',
      unitId: json['unit_id'] as String? ?? '',
      realName: (json['real_name'] ?? json['name'] ?? '') as String,
      role: json['role'] as String? ?? 'member',
      status: json['status'] as String? ?? 'active',
      reviewStatus: json['review_status'] as String? ?? 'approved',
      stationName: json['station_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      applyReason: json['apply_reason'] as String? ?? '',
      createdAt: (json['created_at'] is num)
          ? (json['created_at'] as num).toInt()
          : 0,
      inRoster: json['in_roster'] == true,
    );
  }
}
