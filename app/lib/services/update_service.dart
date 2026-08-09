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

/// 远端更新信息（来自 GitHub Releases）
class UpdateInfo {
  final String tagName; // 如 v0.8.5+22
  final String apkUrl;
  final int? sizeBytes;
  final String? sha256;
  final String? changelog; // release body

  const UpdateInfo({
    required this.tagName,
    required this.apkUrl,
    this.sizeBytes,
    this.sha256,
    this.changelog,
  });

  /// 从 tag 尾部 `+N` 解析 versionCode（历史 tag 无 +N 视为 0，永远低于正式版）
  int get versionCode {
    final idx = tagName.lastIndexOf('+');
    if (idx < 0) return 0;
    return int.tryParse(tagName.substring(idx + 1)) ?? 0;
  }
}

/// OTA 更新服务：查询 GitHub Releases 最新版（公开仓库免 token），
/// 由 App 自己下载并校验 APK，再交给原生 FileProvider 拉起系统安装。
///
/// 版本查询优先走 GitHub Releases API（响应小，避免下载整张发布页），
/// API 限流或不可达时回退到 github.com 发布页解析。两条路径都从发布
/// 信息中读取 SHA256，下载后仍必须校验，不能只凭版本号安装。
class UpdateService {
  static const repoHome = 'https://github.com/shooter119/WatchDog';
  static const releaseApiUrl =
      'https://api.github.com/repos/shooter119/WatchDog/releases/latest';
  static const latestUrl = '$repoHome/releases/latest';
  static const userAgent = 'watchdog-app-updater/1.0';
  static const _metadataTimeout = Duration(seconds: 15);

  static const MethodChannel _installChannel = MethodChannel('watchdog/screen');
  static const _cachedTagKey = 'ota_cached_tag';
  static const _cachedShaKey = 'ota_cached_sha256';

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
  /// - 错误信息非空 → 检查失败（GitHub 不可达/网络异常）
  Future<(UpdateInfo?, String?)> checkForUpdate() async {
    final info = await PackageInfo.fromPlatform();
    final localBuild = int.tryParse(info.buildNumber) ?? 0;
    final (remote, error) = await _fetchLatestRelease();
    if (error != null) return (null, error);
    if (remote == null || remote.versionCode <= localBuild) return (null, null);
    return (remote, null);
  }

  Future<(UpdateInfo?, String?)> _fetchLatestRelease() async {
    Object? apiError;
    try {
      final res = await http
          .get(
            Uri.parse(releaseApiUrl),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': userAgent,
            },
          )
          .timeout(_metadataTimeout);
      if (res.statusCode == 200) {
        final parsed = parseReleaseJson(utf8.decode(res.bodyBytes));
        if (parsed != null) return (parsed, null);
        apiError = const FormatException('GitHub API 返回的更新清单不完整');
      } else {
        apiError = HttpException('GitHub API HTTP ${res.statusCode}');
      }
    } catch (e) {
      apiError = e;
    }

    // API 可能因匿名限流或特定网络环境不可用，保留网页路径作为兜底。
    try {
      final res = await http
          .get(Uri.parse(latestUrl), headers: {'User-Agent': userAgent})
          .timeout(_metadataTimeout);
      if (res.statusCode != 200) {
        return (null, '更新服务不可达（HTTP ${res.statusCode}）');
      }
      final parsed = parseReleaseHtml(utf8.decode(res.bodyBytes));
      if (parsed != null) return (parsed, null);
      return (null, '更新清单解析失败');
    } catch (e) {
      // 优先展示最后一次（网页兜底）错误；API 错误仅作为诊断信息保留，
      // 避免用户看到两个重复的异常堆叠。
      if (apiError is TimeoutException && e is TimeoutException) {
        return (null, 'GitHub 响应超时，请稍后重试');
      }
      return (null, _friendlyNetworkError(e));
    }
  }

  /// 解析 GitHub Releases API 返回的 JSON。公开保留便于单测覆盖发布格式。
  static UpdateInfo? parseReleaseJson(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final tagName = decoded['tag_name'];
      if (tagName is! String || tagName.isEmpty) return null;

      final rawAssets = decoded['assets'];
      if (rawAssets is! List) return null;
      Map<String, dynamic>? apkAsset;
      for (final rawAsset in rawAssets) {
        if (rawAsset is! Map) continue;
        final name = rawAsset['name'];
        if (name is String &&
            name.startsWith('watchdog-') &&
            name.endsWith('-arm64-v8a.apk')) {
          apkAsset = Map<String, dynamic>.from(rawAsset);
          break;
        }
      }
      if (apkAsset == null) return null;

      final assetName = apkAsset['name'] as String;
      final assetUrl =
          apkAsset['browser_download_url'] as String? ??
          '$repoHome/releases/download/${Uri.encodeComponent(tagName)}/$assetName';
      final rawSize = apkAsset['size'];
      final bodyText = decoded['body'] as String? ?? '';
      return UpdateInfo(
        tagName: tagName,
        apkUrl: assetUrl,
        sizeBytes: rawSize is num ? rawSize.toInt() : null,
        sha256: _extractSha256(bodyText),
        changelog: bodyText,
      );
    } catch (_) {
      return null;
    }
  }

  /// 兼容旧版本发布页格式，作为 API 不可用时的兜底解析器。
  static UpdateInfo? parseReleaseHtml(String html) {
    final ogMatch = RegExp(r'og:url"\s+content="([^"]+)"').firstMatch(html);
    final tagMatch = RegExp(
      r'/releases/tag/[^/?]+',
    ).firstMatch(ogMatch?.group(1) ?? '');
    if (tagMatch == null) return null;
    final encodedTag = tagMatch.group(0)!.split('/').last;
    final tagName = Uri.decodeComponent(encodedTag);
    if (tagName.isEmpty) return null;

    final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    final assetName = 'watchdog-$version-arm64-v8a.apk';
    return UpdateInfo(
      tagName: tagName,
      apkUrl:
          '$repoHome/releases/download/${Uri.encodeComponent(tagName)}/$assetName',
      sha256: _extractSha256(html),
    );
  }

  static String? _extractSha256(String source) {
    return RegExp(r'SHA256:\s*([0-9a-fA-F]{64})').firstMatch(source)?.group(1);
  }

  static String _friendlyNetworkError(Object error) {
    if (error is TimeoutException) return 'GitHub 响应超时，请稍后重试';
    if (error is SocketException) return '无法连接 GitHub，请检查网络后重试';
    return '检查更新失败：$error';
  }

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
        onInstalling?.call();
        onProgress?.call(100);
        return;
      }
      await _downloadAndVerify(
        update,
        onProgress: onProgress,
      ).timeout(const Duration(minutes: 15));
      // 只在本地文件已通过校验后记录待安装版本；系统安装器取消时可安全重试。
      await _rememberReadyPackage(update);
      await installReadyPackage(update);
      onInstalling?.call();
      onProgress?.call(100);
    } catch (e) {
      onError?.call(e.toString());
    }
  }

  Future<void> _downloadAndVerify(
    UpdateInfo update, {
    void Function(int percent)? onProgress,
  }) async {
    final client = http.Client();
    IOSink? sink;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final otaDir = Directory(path.join(supportDir.path, 'ota_update'));
      await otaDir.create(recursive: true);
      final apk = File(path.join(otaDir.path, filenameFor(update)));
      if (await apk.exists()) await apk.delete();

      final request = http.Request('GET', Uri.parse(update.apkUrl))
        ..headers['User-Agent'] = userAgent;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('下载失败（HTTP ${response.statusCode}）');
      }

      final total = response.contentLength ?? update.sizeBytes ?? 0;
      var received = 0;
      final digestSink = AccumulatorSink<Digest>();
      final digestInput = sha256.startChunkedConversion(digestSink);
      final fileSink = apk.openWrite();
      sink = fileSink;
      onProgress?.call(0);
      await for (final chunk in response.stream) {
        fileSink.add(chunk);
        digestInput.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received * 100 / total).clamp(0, 99).round());
        }
      }
      await fileSink.flush();
      await fileSink.close();
      sink = null;
      digestInput.close();

      final actualSha = digestSink.events.single.toString();
      if (actualSha.toLowerCase() != update.sha256!.trim().toLowerCase()) {
        await apk.delete();
        throw StateError('安装包校验失败，请重试');
      }
    } finally {
      await sink?.close();
      client.close();
    }
  }
}
