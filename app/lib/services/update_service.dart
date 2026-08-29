import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

int? _arm64VersionCodeFromTag(String tagName) {
  final idx = tagName.lastIndexOf('+');
  if (idx < 1 || idx == tagName.length - 1) return null;
  final buildNumber = int.tryParse(tagName.substring(idx + 1));
  if (buildNumber == null || buildNumber < 1) return null;
  // Release workflow publishes the arm64 split APK. Keep this offset in sync
  // with Flutter's split-per-abi versionCode convention.
  return 2000 + buildNumber;
}

/// 远端更新信息（来自国内 CloudBase OTA 清单）
class UpdateInfo {
  final String tagName; // 如 v0.8.5+22
  final String apkUrl;
  final int? sizeBytes;
  final String? sha256;
  final String? changelog; // 国内 OTA 清单中的更新说明

  const UpdateInfo({
    required this.tagName,
    required this.apkUrl,
    this.sizeBytes,
    this.sha256,
    this.changelog,
  });

  /// 从 tag 尾部 `+N` 解析 arm64 split APK 的 Android versionCode。
  /// Flutter 的 split-per-abi 会给 arm64 增加 2000 的 ABI 偏移；OTA 清单必须
  /// 与 APK 内部 versionCode 一致，原生安装校验和本地版本比较也使用该值。
  int get versionCode {
    return _arm64VersionCodeFromTag(tagName) ?? 0;
  }
}

typedef UpdateEventLogger =
    void Function(String stage, String message, String level);

/// OTA 更新服务：从国内 CloudBase 静态托管公开清单获取版本，
/// 由 App 自己下载并校验 APK，再交给原生 FileProvider 拉起系统安装。
///
/// 清单和 APK 均只走国内更新入口；GitHub Release 仍由发布流水线保留，
/// 供旧版本迁移、人工下载和历史归档使用，但新版本 App 不在运行时访问 GitHub。
class UpdateService {
  static const updateManifestUrl = String.fromEnvironment(
    'WATCHDOG_UPDATE_MANIFEST_URL',
    defaultValue:
        'https://watchdog-prod-d6gch930m378d9a16-1351750301.tcloudbaseapp.com/ota/latest.json',
  );
  static const userAgent = 'watchdog-app-updater/2.0';
  static const _metadataTimeout = Duration(seconds: 15);
  static const _metadataAttempts = 2;
  static const _downloadAttempts = 2;
  static const _retryDelay = Duration(milliseconds: 500);
  // 当前正式 arm64 APK 约 47 MB；给压缩/未来依赖增长留出空间，同时避免
  // 清单被篡改或服务异常时把无界响应写入应用存储。
  static const maxApkSizeBytes = 160 * 1024 * 1024;

  static const MethodChannel _installChannel = MethodChannel('watchdog/screen');
  static const _cachedTagKey = 'ota_cached_tag';
  static const _cachedShaKey = 'ota_cached_sha256';

  final http.Client Function() _httpClientFactory;
  final UpdateEventLogger? _logger;

  UpdateService({
    http.Client Function()? httpClientFactory,
    UpdateEventLogger? logger,
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new,
       _logger = logger;

  void _log(String stage, String message, {String level = 'info'}) {
    _logger?.call(stage, message, level);
  }

  /// 使用版本化文件名，避免不同版本之间复用同一个残留 APK。
  static String filenameFor(UpdateInfo update) {
    final safeTag = update.tagName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return 'watchdog-update-$safeTag.apk';
  }

  /// Android 8+ 安装 APK 需要"安装未知来源应用"授权。
  /// 返回 false 时下载后也无法弹出安装界面，应先引导用户授权。
  /// 平台不可用/低版本/测试环境视为已授权（不阻断下载）。
  static Future<bool> canRequestPackageInstalls() async {
    try {
      final v = await _installChannel
          .invokeMethod<bool>('canRequestPackageInstalls')
          .timeout(const Duration(seconds: 2));
      return v ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 打开系统"安装未知来源应用"授权页（本应用）
  static Future<void> openUnknownAppSourcesSettings() async {
    try {
      await _installChannel
          .invokeMethod('openUnknownAppSourcesSettings')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 平台不支持时静默忽略
    }
  }

  /// 是否已有该版本已下载并通过校验的安装包。
  ///
  /// APK 保存在应用内部目录；这里只在版本和校验值都匹配时复用，避免远端
  /// 发布新版本后误装旧包。原生层会再确认文件确实存在且非空。
  static Future<bool> hasReadyPackage(UpdateInfo update) async {
    try {
      // 没有发布端 SHA256 就不能证明本地文件已校验，宁可重新下载。
      if (update.sha256 == null) return false;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_cachedTagKey) != update.tagName ||
          prefs.getString(_cachedShaKey) != update.sha256) {
        return false;
      }
      // 原生层重新计算文件 SHA256，并读取 APK 内部包名/ versionCode，
      // 不再仅凭“文件存在”复用可能已经被替换的安装包。
      return await _installChannel
              .invokeMethod<bool>('verifyDownloadedUpdate', {
                'filename': filenameFor(update),
                'sha256': update.sha256,
                'versionCode': update.versionCode,
              })
              .timeout(const Duration(seconds: 5)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 重新拉起系统安装器，不重复下载已校验的 APK。
  static Future<void> installReadyPackage(UpdateInfo update) async {
    await _installChannel
        .invokeMethod<void>('installDownloadedUpdate', {
          'filename': filenameFor(update),
        })
        .timeout(const Duration(seconds: 5));
  }

  static Future<void> _rememberReadyPackage(UpdateInfo update) async {
    if (update.sha256 == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cachedTagKey, update.tagName);
    await prefs.setString(_cachedShaKey, update.sha256!);
  }

  /// 检查更新。返回 (更新信息, 错误信息)：
  /// - 更新信息非空 → 有新版可下载
  /// - 两者皆空 → 已是最新
  /// - 错误信息非空 → 检查失败（国内更新服务不可达/网络异常）
  Future<(UpdateInfo?, String?)> checkForUpdate() async {
    final info = await PackageInfo.fromPlatform();
    final localBuild = int.tryParse(info.buildNumber) ?? 0;
    final (remote, error) = await _fetchLatestManifest();
    if (error != null) return (null, error);
    if (remote == null || remote.versionCode <= localBuild) return (null, null);
    return (remote, null);
  }

  Future<(UpdateInfo?, String?)> _fetchLatestManifest() async {
    final manifestUri = Uri.tryParse(updateManifestUrl);
    if (manifestUri == null || !_isHttpsUri(manifestUri)) {
      const error = '国内更新服务地址无效';
      _log('ota_manifest_fail', error, level: 'error');
      return (null, error);
    }

    _log('ota_manifest_start', '开始请求国内更新清单');
    final client = _httpClientFactory();
    Object? lastError;
    try {
      for (var attempt = 1; attempt <= _metadataAttempts; attempt++) {
        try {
          final res = await client
              .get(
                manifestUri,
                headers: {
                  'Accept': 'application/json',
                  'Cache-Control': 'no-cache',
                  'User-Agent': userAgent,
                },
              )
              .timeout(_metadataTimeout);
          if (res.statusCode == 200) {
            final parsed = parseManifestJson(
              utf8.decode(res.bodyBytes),
              manifestUrl: manifestUri,
            );
            if (parsed != null) {
              _log(
                'ota_manifest_ready',
                '国内更新清单读取成功：${parsed.tagName}',
                level: 'info',
              );
              return (parsed, null);
            }
            const error = '国内更新清单格式无效';
            _log('ota_manifest_fail', error, level: 'error');
            return (null, error);
          }

          lastError = _HttpStatusException(res.statusCode);
          if (!_isRetryableMetadataStatus(res.statusCode) ||
              attempt == _metadataAttempts) {
            final error = '国内更新服务不可达（HTTP ${res.statusCode}）';
            _log('ota_manifest_fail', error, level: 'error');
            return (null, error);
          }
        } catch (e) {
          lastError = e;
          if (attempt == _metadataAttempts) {
            final error = _friendlyNetworkError(e);
            _log('ota_manifest_fail', error, level: 'error');
            return (null, error);
          }
        }
        await Future<void>.delayed(_retryDelay);
      }
      final error = _friendlyNetworkError(
        lastError ?? const SocketException('请求失败'),
      );
      _log('ota_manifest_fail', error, level: 'error');
      return (null, error);
    } finally {
      client.close();
    }
  }

  /// 解析国内 CloudBase OTA 清单，并将相对 APK 路径解析为同一入口下的 HTTPS 地址。
  static UpdateInfo? parseManifestJson(String body, {Uri? manifestUrl}) {
    try {
      final baseUri = manifestUrl ?? Uri.tryParse(updateManifestUrl);
      if (baseUri == null || !_isHttpsUri(baseUri)) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      if (decoded['schemaVersion'] != 1) return null;

      final tagName = decoded['tagName'];
      final versionCode = decoded['versionCode'];
      final apkPath = decoded['apkPath'];
      final sha256 = decoded['sha256'];
      final sizeBytes = decoded['sizeBytes'];
      final changelog = decoded['changelog'];
      if (tagName is! String || tagName.trim().isEmpty) return null;
      if (versionCode is! num ||
          !versionCode.isFinite ||
          versionCode != versionCode.roundToDouble() ||
          versionCode < 1) {
        return null;
      }
      if (apkPath is! String || !_isSafeApkPath(apkPath)) return null;
      if (sha256 is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
        return null;
      }
      if (sizeBytes is! num ||
          !sizeBytes.isFinite ||
          sizeBytes != sizeBytes.roundToDouble() ||
          sizeBytes < 1 ||
          sizeBytes > maxApkSizeBytes) {
        return null;
      }
      if (changelog is! String) return null;

      final parsedTagVersionCode = _arm64VersionCodeFromTag(tagName);
      if (parsedTagVersionCode == null ||
          parsedTagVersionCode != versionCode.toInt()) {
        return null;
      }
      final apkUrl = baseUri.resolve(apkPath).toString();
      return UpdateInfo(
        tagName: tagName,
        apkUrl: apkUrl,
        sizeBytes: sizeBytes.toInt(),
        sha256: sha256.toLowerCase(),
        changelog: changelog,
      );
    } catch (_) {
      return null;
    }
  }

  static String _friendlyNetworkError(Object error) {
    if (error is TimeoutException) return '国内更新服务响应超时，请稍后重试';
    if (error is SocketException || error is http.ClientException) {
      return '无法连接国内更新服务，请检查网络后重试';
    }
    return '检查国内更新服务失败：$error';
  }

  static bool _isHttpsUri(Uri uri) =>
      uri.scheme.toLowerCase() == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty;

  static bool _isSafeApkPath(String value) {
    if (value.isEmpty || value.startsWith('/') || value.contains('\\')) {
      return false;
    }
    // 只允许 CI 生成的普通对象路径，拒绝 %2e、%2f 等编码后的路径穿越变体。
    if (RegExp(r'[^A-Za-z0-9._+/-]').hasMatch(value)) return false;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.hasScheme ||
        uri.host.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    final segments = value.split('/');
    return segments.isNotEmpty &&
        segments.first == 'releases' &&
        !segments.contains('') &&
        !segments.contains('.') &&
        !segments.contains('..') &&
        value.endsWith('-arm64-v8a.apk');
  }

  static bool _isRetryableMetadataStatus(int statusCode) =>
      statusCode >= 500 && statusCode <= 599;

  static bool _isRetryableDownloadError(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException ||
      (error is _HttpStatusException &&
          error.statusCode >= 500 &&
          error.statusCode <= 599);

  /// 下载并安装（下载进度 0-100 通过回调上报；错误通过回调 message 返回）。
  ///
  /// 下载、校验和拉起安装器全部由本服务控制，避免 ota_update 插件在下载完成后
  /// 走另一套旧的安装 Intent。系统安装器被成功拉起后，用户仍需在系统界面确认。
  Future<void> downloadAndInstall(
    UpdateInfo update, {
    void Function(int percent)? onProgress,
    void Function(String message)? onError,
    void Function()? onInstalling,
  }) async {
    try {
      if (update.sha256 == null) {
        throw StateError('发布版本缺少 SHA256，已阻止安装');
      }
      if (await hasReadyPackage(update)) {
        await installReadyPackage(update);
        _log('ota_installing', '已校验的安装包就绪，进入系统安装阶段');
        onInstalling?.call();
        onProgress?.call(100);
        return;
      }
      _log('ota_download_start', '开始下载更新包');
      await _downloadAndVerify(
        update,
        onProgress: onProgress,
      ).timeout(const Duration(minutes: 15));
      // 只在本地文件已通过校验后记录待安装版本；系统安装器取消时可安全重试。
      await _rememberReadyPackage(update);
      await installReadyPackage(update);
      _log('ota_installing', '下载完成，进入系统安装阶段');
      onInstalling?.call();
      onProgress?.call(100);
    } catch (e) {
      _log('ota_fail', e.toString(), level: 'error');
      onError?.call(e.toString());
    }
  }

  Future<void> _downloadAndVerify(
    UpdateInfo update, {
    void Function(int percent)? onProgress,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _downloadAttempts; attempt++) {
      try {
        await _downloadAndVerifyOnce(update, onProgress: onProgress);
        return;
      } catch (e) {
        lastError = e;
        if (!_isRetryableDownloadError(e) || attempt == _downloadAttempts) {
          if (e is _HttpStatusException) {
            throw StateError('下载失败（HTTP ${e.statusCode}）');
          }
          rethrow;
        }
        await Future<void>.delayed(_retryDelay);
      }
    }
    throw lastError ?? StateError('下载失败');
  }

  Future<void> _downloadAndVerifyOnce(
    UpdateInfo update, {
    void Function(int percent)? onProgress,
  }) async {
    final client = _httpClientFactory();
    IOSink? sink;
    File? apk;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final otaDir = Directory(path.join(supportDir.path, 'ota_update'));
      await otaDir.create(recursive: true);
      apk = File(path.join(otaDir.path, filenameFor(update)));
      if (await apk.exists()) await apk.delete();

      final expectedSize = update.sizeBytes;
      if (expectedSize != null && expectedSize > maxApkSizeBytes) {
        throw StateError('安装包大小超出安全限制，已阻止安装');
      }

      final request = http.Request('GET', Uri.parse(update.apkUrl))
        ..headers['User-Agent'] = userAgent;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _HttpStatusException(response.statusCode);
      }

      final declaredSize = response.contentLength;
      if (declaredSize != null && declaredSize >= 0) {
        if (declaredSize > maxApkSizeBytes) {
          throw StateError('安装包大小超出安全限制，已阻止安装');
        }
        if (expectedSize != null && declaredSize != expectedSize) {
          throw StateError('安装包大小校验失败，请重试');
        }
      }
      final total = declaredSize != null && declaredSize >= 0
          ? declaredSize
          : expectedSize ?? 0;
      var received = 0;
      final digestSink = AccumulatorSink<Digest>();
      final digestInput = sha256.startChunkedConversion(digestSink);
      final fileSink = apk.openWrite();
      sink = fileSink;
      onProgress?.call(0);
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > maxApkSizeBytes) {
          throw StateError('安装包大小超出安全限制，已阻止安装');
        }
        fileSink.add(chunk);
        digestInput.add(chunk);
        if (total > 0) {
          onProgress?.call((received * 100 / total).clamp(0, 99).round());
        }
      }
      await fileSink.flush();
      await fileSink.close();
      sink = null;
      digestInput.close();

      if (expectedSize != null && received != expectedSize) {
        _log('ota_size_fail', '安装包大小校验失败', level: 'error');
        await apk.delete();
        throw StateError('安装包大小校验失败，请重试');
      }

      final actualSha = digestSink.events.single.toString();
      if (actualSha.toLowerCase() != update.sha256!.trim().toLowerCase()) {
        _log('ota_checksum_fail', '安装包校验失败', level: 'error');
        await apk.delete();
        throw StateError('安装包校验失败，请重试');
      }
    } catch (e) {
      if (apk != null && await apk.exists()) {
        await apk.delete();
      }
      rethrow;
    } finally {
      await sink?.close();
      client.close();
    }
  }
}

class _HttpStatusException implements Exception {
  final int statusCode;

  const _HttpStatusException(this.statusCode);
}
