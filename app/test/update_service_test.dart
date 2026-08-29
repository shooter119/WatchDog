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

  group('国内 OTA 清单解析', () {
    const sha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const manifestUrl = 'https://download.example.test/ota/latest.json';

    test('提取版本、APK 地址、大小、SHA256 和更新说明', () {
      final info = UpdateService.parseManifestJson('''
{
  "schemaVersion": 1,
  "tagName": "v0.14.0+43",
  "versionCode": 2043,
  "apkPath": "releases/v0.14.0+43/watchdog-0.14.0+43-arm64-v8a.apk",
  "sizeBytes": 12345678,
  "sha256": "$sha",
  "changelog": "修复现场日志显示问题"
}
''', manifestUrl: Uri.parse(manifestUrl));

      expect(info?.tagName, 'v0.14.0+43');
      expect(info?.versionCode, 2043);
      expect(
        info?.apkUrl,
        'https://download.example.test/ota/releases/'
        'v0.14.0+43/watchdog-0.14.0+43-arm64-v8a.apk',
      );
      expect(info?.sizeBytes, 12345678);
      expect(info?.sha256, sha);
      expect(info?.changelog, '修复现场日志显示问题');
    });

    test('schema、字段、版本号或 SHA256 无效时拒绝清单', () {
      const valid = {
        'schemaVersion': 1,
        'tagName': 'v0.14.0+43',
        'versionCode': 2043,
        'apkPath': 'releases/v0.14.0+43/watchdog-0.14.0+43-arm64-v8a.apk',
        'sizeBytes': 12345678,
        'sha256': sha,
        'changelog': '测试更新',
      };
      for (final replacement in [
        {'schemaVersion': 2},
        {'versionCode': 2044},
        {'sha256': 'not-a-sha256'},
        {'sizeBytes': 0},
        {'apkPath': 'releases/v0.14.0+43/not-an-apk.zip'},
      ]) {
        final body = jsonEncode({...valid, ...replacement});
        expect(
          UpdateService.parseManifestJson(
            body,
            manifestUrl: Uri.parse(manifestUrl),
          ),
          isNull,
          reason: 'replacement=$replacement',
        );
      }
    });

    test('APK 路径拒绝绝对地址、查询参数和路径穿越', () {
      const paths = [
        '/releases/v0.14.0+43/watchdog-0.14.0+43-arm64-v8a.apk',
        'https://evil.example/update.apk',
        'releases/../watchdog-0.14.0+43-arm64-v8a.apk',
        'releases/%2e%2e/watchdog-0.14.0+43-arm64-v8a.apk',
        'releases/v0.14.0+43/watchdog-0.14.0+43-arm64-v8a.apk?x=1',
      ];
      for (final apkPath in paths) {
        final body = jsonEncode({
          'schemaVersion': 1,
          'tagName': 'v0.14.0+43',
          'versionCode': 2043,
          'apkPath': apkPath,
          'sizeBytes': 12345678,
          'sha256': sha,
          'changelog': '测试更新',
        });
        expect(
          UpdateService.parseManifestJson(
            body,
            manifestUrl: Uri.parse(manifestUrl),
          ),
          isNull,
          reason: 'apkPath=$apkPath',
        );
      }
    });

    test('清单入口必须使用 HTTPS', () {
      const body =
          '''
{
  "schemaVersion": 1,
  "tagName": "v0.14.0+43",
  "versionCode": 2043,
  "apkPath": "releases/v0.14.0+43/watchdog-0.14.0+43-arm64-v8a.apk",
  "sizeBytes": 12345678,
  "sha256": "$sha",
  "changelog": "测试更新"
}
''';
      expect(
        UpdateService.parseManifestJson(
          body,
          manifestUrl: Uri.parse(
            'http://download.example.test/ota/latest.json',
          ),
        ),
        isNull,
      );
    });
  });

  group('国内 OTA 清单请求', () {
    const sha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final manifest = jsonEncode({
      'schemaVersion': 1,
      'tagName': 'v9.9.9+99',
      'versionCode': 2099,
      'apkPath': 'releases/v9.9.9+99/watchdog-9.9.9+99-arm64-v8a.apk',
      'sizeBytes': 123,
      'sha256': sha,
      'changelog': '测试更新',
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
        _response(manifest, 200),
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

    test('4xx 不重试，并返回国内更新服务错误', () async {
      final client = _QueueClient([_response('', 404)]);
      final (info, error) = await UpdateService(
        httpClientFactory: () => client,
      ).checkForUpdate();

      expect(info, isNull);
      expect(error, '国内更新服务不可达（HTTP 404）');
      expect(client.requests, hasLength(1));
    });

    test('网络异常重试后仍失败时返回国内网络错误', () async {
      final client = _QueueClient([
        const SocketException('offline'),
        const SocketException('offline'),
      ]);
      final (info, error) = await UpdateService(
        httpClientFactory: () => client,
      ).checkForUpdate();

      expect(info, isNull);
      expect(error, '无法连接国内更新服务，请检查网络后重试');
      expect(client.requests, hasLength(2));
    });

    test('请求超时重试后仍失败时返回超时提示', () async {
      final client = _QueueClient([
        TimeoutException('slow'),
        TimeoutException('slow'),
      ]);
      final (info, error) = await UpdateService(
        httpClientFactory: () => client,
      ).checkForUpdate();

      expect(info, isNull);
      expect(error, '国内更新服务响应超时，请稍后重试');
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
