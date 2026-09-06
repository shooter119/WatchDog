import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateInfo 版本解析', () {
    test('从 tag 尾部 +N 解析 arm64 split APK versionCode', () {
      expect(UpdateInfo(tagName: 'v0.8.5+22', apkUrl: 'x').versionCode, 2022);
      expect(UpdateInfo(tagName: 'v0.9.0+100', apkUrl: 'x').versionCode, 2100);
    });

    test('历史 tag 无 +N 视为 0（永远低于正式版）', () {
      expect(UpdateInfo(tagName: 'v0.8.4', apkUrl: 'x').versionCode, 0);
    });

    test('非数字 build 号兜底为 0', () {
      expect(UpdateInfo(tagName: 'v1.0.0+abc', apkUrl: 'x').versionCode, 0);
    });
  });

  group('ALI OTA 清单解析', () {
    const sha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test('提取版本、APK 地址、大小、SHA256 和更新说明', () {
      final info = UpdateService.parseReleaseJson('''
{
  "tag_name": "v0.14.0+43",
  "version_code": 2043,
  "changelog": "修复现场日志显示问题",
  "apk_url": "https://fireman119.xyz/ota/versions/watchdog-0.14.0+43-arm64-v8a.apk",
  "size_bytes": 12345678,
  "sha256": "$sha"
}
''');

      expect(info?.tagName, 'v0.14.0+43');
      expect(info?.versionCode, 2043);
      expect(
        info?.apkUrl,
        'https://fireman119.xyz/ota/versions/watchdog-0.14.0+43-arm64-v8a.apk',
      );
      expect(info?.sizeBytes, 12345678);
      expect(info?.sha256, sha);
      expect(info?.changelog, contains('修复现场日志显示问题'));
    });

    test('tag、assets、APK 名称或下载地址无效时拒绝 release', () {
      const valid = {
        'tag_name': 'v0.14.0+43',
        'version_code': 2043,
        'changelog': '测试更新',
        'apk_url':
            'https://fireman119.xyz/ota/versions/watchdog-0.14.0+43-arm64-v8a.apk',
        'size_bytes': 12345678,
        'sha256': sha,
      };
      for (final replacement in [
        {'tag_name': ''},
        {'apk_url': 'http://evil.example/update.apk'},
        {'version_code': 2044},
        {'sha256': 'bad'},
      ]) {
        final body = jsonEncode({...valid, ...replacement});
        expect(
          UpdateService.parseReleaseJson(body),
          isNull,
          reason: 'replacement=$replacement',
        );
      }
    });

    test('缺少 SHA256 时保留版本信息但安装阶段不能跳过校验', () {
      final body = jsonEncode({
        'tag_name': 'v0.14.0+43',
        'apk_url': 'https://fireman119.xyz/ota/versions/watchdog.apk',
      });
      expect(UpdateService.parseReleaseJson(body)?.sha256, isNull);
    });
  });

  group('ALI OTA 请求', () {
    const sha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final release = jsonEncode({
      'tag_name': 'v9.9.9+99',
      'version_code': 2099,
      'changelog': '测试更新',
      'apk_url':
          'https://fireman119.xyz/ota/versions/watchdog-9.9.9+99-arm64-v8a.apk',
      'size_bytes': 123,
      'sha256': sha,
    });

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'WatchDog',
        packageName: 'com.firewatch.watchdog',
        version: '1.2.1',
        buildNumber: '49',
        buildSignature: '',
      );
    });

    test('5xx 重试后成功，并发送禁止缓存请求头', () async {
      final client = _QueueClient([
        _response('', 503),
        _response(release, 200),
      ]);
      final (info, error) = await UpdateService(
        httpClientFactory: () => client,
      ).checkForUpdate();

      expect(error, isNull);
      expect(info?.tagName, 'v9.9.9+99');
      expect(client.requests, hasLength(2));
      expect(client.requests.first.headers['cache-control'], 'no-cache');
      expect(client.requests.first.headers['user-agent'], contains('watchdog'));
    });

    test('4xx 不重试，并返回 ALI OTA 错误', () async {
      final client = _QueueClient([_response('', 404)]);
      final (info, error) = await UpdateService(
        httpClientFactory: () => client,
      ).checkForUpdate();

      expect(info, isNull);
      expect(error, 'ALI OTA 服务不可达（HTTP 404）');
      expect(client.requests, hasLength(1));
    });

    test('网络异常重试后仍失败时返回 ALI 网络错误', () async {
      final client = _QueueClient([
        const SocketException('offline'),
        const SocketException('offline'),
      ]);
      final (info, error) = await UpdateService(
        httpClientFactory: () => client,
      ).checkForUpdate();

      expect(info, isNull);
      expect(error, '无法连接 ALI OTA 服务，请检查网络后重试');
      expect(client.requests, hasLength(2));
    });

    test('请求超时重试后仍失败时返回 ALI 超时提示', () async {
      final client = _QueueClient([
        TimeoutException('slow'),
        TimeoutException('slow'),
      ]);
      final (info, error) = await UpdateService(
        httpClientFactory: () => client,
      ).checkForUpdate();

      expect(info, isNull);
      expect(error, 'ALI OTA 服务响应超时，请稍后重试');
      expect(client.requests, hasLength(2));
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

  group('OTA 安装包大小校验', () {
    const channel = MethodChannel('watchdog/screen');
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory supportDirectory;

    setUp(() async {
      supportDirectory = await Directory.systemTemp.createTemp(
        'watchdog-ota-update-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return supportDirectory.path;
            }
            return null;
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      SharedPreferences.setMockInitialValues({});
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });

    test('响应体大小与清单不一致时拒绝安装', () async {
      final bytes = <int>[1, 2, 3];
      final client = _QueueClient([_responseBytes(bytes, 200)]);
      var nativeInstallCalled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'installDownloadedUpdate') {
              nativeInstallCalled = true;
            }
            return false;
          });

      String? error;
      await UpdateService(httpClientFactory: () => client).downloadAndInstall(
        UpdateInfo(
          tagName: 'v0.11.12+38',
          apkUrl: 'https://example.test/watchdog.apk',
          sizeBytes: 4,
          sha256: sha256.convert(bytes).toString(),
        ),
        onError: (message) => error = message,
      );

      expect(error, contains('大小校验失败'));
      expect(nativeInstallCalled, isFalse);
    });

    test('清单声明超过安全上限时拒绝下载', () async {
      final client = _QueueClient([_responseBytes(<int>[], 200)]);
      String? error;
      await UpdateService(httpClientFactory: () => client).downloadAndInstall(
        const UpdateInfo(
          tagName: 'v0.11.12+38',
          apkUrl: 'https://example.test/watchdog.apk',
          sizeBytes: UpdateService.maxApkSizeBytes + 1,
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        onError: (message) => error = message,
      );

      expect(error, contains('超出安全限制'));
      expect(client.requests, isEmpty);
    });
  });
}

class _QueueClient extends http.BaseClient {
  final List<Object> _outcomes;
  final requests = <http.BaseRequest>[];

  _QueueClient(Iterable<Object> outcomes) : _outcomes = [...outcomes];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final outcome = _outcomes.removeAt(0);
    if (outcome is http.StreamedResponse) return outcome;
    throw outcome;
  }

  @override
  void close() {}
}

http.StreamedResponse _response(String body, int statusCode) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}

http.StreamedResponse _responseBytes(
  List<int> bytes,
  int statusCode, {
  int? contentLength,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    statusCode,
    contentLength: contentLength,
    headers: {'content-type': 'application/vnd.android.package-archive'},
  );
}
