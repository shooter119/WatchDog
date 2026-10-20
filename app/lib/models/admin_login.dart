class AdminCapability {
  final String memberId, name, unitName, unitRole, role;
  const AdminCapability({
    required this.memberId,
    required this.name,
    required this.unitName,
    required this.unitRole,
    required this.role,
  });
  String get roleLabel => role == 'platform_admin' ? '平台管理员' : '单位后台管理员';
  factory AdminCapability.fromJson(Map<String, dynamic> json) =>
      AdminCapability(
        memberId: json['id'] as String,
        name: json['real_name'] as String,
        unitName: json['unit_name'] as String,
        unitRole: json['unit_role'] as String,
        role: json['admin_role'] as String,
      );
}

/// 严格匹配本站规范格式，不打开 URL，不接受跳转、端口、编码别名或其它二维码。
class AdminLoginCode {
  final String id, scan;
  const AdminLoginCode._(this.id, this.scan);
  static AdminLoginCode? parse(String raw) {
    final match = RegExp(
      r'^https://fireman119\.xyz/admin/scan#([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.([A-Za-z0-9_-]{43})$',
    ).firstMatch(raw);
    return match == null || match.end != raw.length
        ? null
        : AdminLoginCode._(match[1]!, match[2]!);
  }
}
