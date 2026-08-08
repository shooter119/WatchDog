import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/update_service.dart';

void main() {
  group('UpdateInfo 版本解析', () {
    test('从 tag 尾部 +N 解析 versionCode', () {
      expect(UpdateInfo(tagName: 'v0.8.5+22', apkUrl: 'x').versionCode, 22);
      expect(UpdateInfo(tagName: 'v0.9.0+100', apkUrl: 'x').versionCode, 100);
    });

    test('历史 tag 无 +N 视为 0（永远低于正式版）', () {
      expect(UpdateInfo(tagName: 'v0.8.4', apkUrl: 'x').versionCode, 0);
    });

    test('非数字 build 号兜底为 0', () {
      expect(UpdateInfo(tagName: 'v1.0.0+abc', apkUrl: 'x').versionCode, 0);
    });
  });

  group('release body 解析约定', () {
    test('SHA256 行提取（CI 自动写入 release body）', () {
      const sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const body = '## v0.8.5+22\n\nversionCode: 22\nSHA256: $sha\n\n### 更新内容\n- 修复';
      final m = RegExp(r'SHA256:\s*([0-9a-fA-F]{64})').firstMatch(body);
      expect(m?.group(1), sha);
    });

    test('body 缺 SHA256 时返回 null（下载时跳过校验）', () {
      const body = '## v0.8.5+22\n\n### 更新内容\n- 修复';
      final m = RegExp(r'SHA256:\s*([0-9a-fA-F]{64})').firstMatch(body);
      expect(m, isNull);
    });
  });
}
