import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

typedef PhoneLauncher = Future<bool> Function(Uri uri);

/// 全局电话呼叫门面服务。
///
/// 统一处理手机号/固话号码清洗、`tel:` 系统 Intent 调起、异常捕获与无头测试桩注入。
class PhoneCaller {
  /// 测试桩注入器，仅供单元测试和 UI 测试环境下替代真实系统拨号。
  static PhoneLauncher? testLauncher;

  /// 清洗号码：移除空格、短横线与常见分隔符
  static String normalizePhone(String raw) {
    return raw.trim().replaceAll(RegExp(r'[\s\-_]'), '');
  }

  /// 粗筛判断是否为有效电话号码格式（11位手机号、带区号固话或常见应急服务号）
  static bool isValidPhoneNumber(String raw) {
    final clean = normalizePhone(raw);
    if (clean.isEmpty) return false;
    // 手机号 1[3-9]\d{9} 或 固话 0\d{2,3}\d{7,8}
    return RegExp(r'^(?:1[3-9]\d{9}|0\d{2,3}\d{7,8}|\d{7,8})$').hasMatch(clean);
  }

  /// 调起系统拨号盘并预填号码。
  static Future<bool> dial(
    BuildContext? context,
    String rawPhone, {
    PhoneLauncher? launcher,
  }) async {
    final phone = normalizePhone(rawPhone);
    if (phone.isEmpty) return false;

    final uri = Uri(scheme: 'tel', path: phone);
    final invokeLauncher = launcher ??
        testLauncher ??
        (u) => launchUrl(u, mode: LaunchMode.externalApplication);

    try {
      final success = await invokeLauncher(uri);
      if (success) return true;
    } catch (_) {
      // 捕获权限异常或不支持拨号的模拟器环境
    }

    if (context != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开拨号界面: $phone')),
      );
    }
    return false;
  }
}
