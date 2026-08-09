import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      const sha =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const body =
          '## v0.8.5+22\n\nversionCode: 22\nSHA256: $sha\n\n### 更新内容\n- 修复';
      final m = RegExp(r'SHA256:\s*([0-9a-fA-F]{64})').firstMatch(body);
      expect(m?.group(1), sha);
    });

    test('body 缺 SHA256 时返回 null（下载时跳过校验）', () {
      const body = '## v0.8.5+22\n\n### 更新内容\n- 修复';
      final m = RegExp(r'SHA256:\s*([0-9a-fA-F]{64})').firstMatch(body);
      expect(m, isNull);
    });
  });

  group('releases/latest 302 页提取约定（免 api.github.com 限流）', () {
    test('从 og:url meta 提取 tag（%2B 编码，需 decode）', () {
      const ogUrl = '/shooter119/WatchDog/releases/tag/v0.8.5%2B22';
      final m = RegExp(r'/releases/tag/([^/?]+)').firstMatch(ogUrl);
      expect(Uri.decodeComponent(m?.group(1) ?? ''), 'v0.8.5+22');
    });

    test('下载 URL 约定：watchdog-<版本>-arm64-v8a.apk（+ 需编码）', () {
      const tagName = 'v0.8.5+22';
      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final apkUrl =
          'https://github.com/shooter119/WatchDog/releases/download/'
          '${Uri.encodeComponent(tagName)}/watchdog-$version-arm64-v8a.apk';
      expect(apkUrl, contains('watchdog-0.8.5+22-arm64-v8a.apk'));
      expect(apkUrl, contains('releases/download/v0.8.5%2B22/'));
    });
  });

  group('已下载安装包复用', () {
    const channel = MethodChannel('watchdog/screen');
    const sha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const update = UpdateInfo(
      tagName: 'v0.11.12+38',
      apkUrl: 'https://example.test/watchdog.apk',
      sha256: sha,
    );

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      SharedPreferences.setMockInitialValues({});
    });

    test('版本和 SHA256 匹配且文件存在时可直接安装', () async {
      SharedPreferences.setMockInitialValues({
        'ota_cached_tag': update.tagName,
        'ota_cached_sha256': sha,
      });
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'verifyDownloadedUpdate') return true;
            return null;
          });

      var installing = false;
      await UpdateService().downloadAndInstall(
        update,
        onInstalling: () => installing = true,
      );

      expect(calls, ['verifyDownloadedUpdate', 'installDownloadedUpdate']);
      expect(installing, isTrue);
    });

    test('不同版本使用不同安装包文件名', () {
      expect(
        UpdateService.filenameFor(update),
        'watchdog-update-v0.11.12_38.apk',
      );
      expect(
        UpdateService.filenameFor(
          const UpdateInfo(tagName: 'v0.11.13+39', apkUrl: 'x'),
        ),
        isNot(UpdateService.filenameFor(update)),
      );
    });

    test('版本不匹配时不复用旧安装包', () async {
      SharedPreferences.setMockInitialValues({
        'ota_cached_tag': 'v0.11.11+37',
        'ota_cached_sha256': sha,
      });
      var nativeCalled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            nativeCalled = true;
            return true;
          });

      expect(await UpdateService.hasReadyPackage(update), isFalse);
      expect(nativeCalled, isFalse);
    });

    test('缺少 SHA256 时不复用未经校验的安装包', () async {
      const noChecksum = UpdateInfo(
        tagName: 'v0.11.12+38',
        apkUrl: 'https://example.test/watchdog.apk',
      );
      SharedPreferences.setMockInitialValues({
        'ota_cached_tag': noChecksum.tagName,
        'ota_cached_sha256': '',
      });

      expect(await UpdateService.hasReadyPackage(noChecksum), isFalse);
    });
  });
}
