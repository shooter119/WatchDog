import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
/// ota_update 下载（内部目录免存储权限 + sha256 校验）并拉起系统安装。
///
/// 版本查询走 github.com 主站（releases/latest 302 → 最新 tag 页，从 HTML
/// 提取 SHA256），不依赖 api.github.com——匿名 API 限流 60 次/小时/出口 IP，
/// 调试工具与多台设备共享 IP 时极易撞上 403。
class UpdateService {
  static const repoHome = 'https://github.com/shooter119/WatchDog';
  static const latestUrl = '$repoHome/releases/latest';
  static const userAgent = 'watchdog-app-updater/1.0';

  final OtaUpdate _ota = OtaUpdate();

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
    try {
      // releases/latest 302 到最新 tag 页（http 包跟随重定向后 body 已是
      // 最终页，但 request.url 仍是最初地址），从 og:url meta 提取 tag
      final res = await http
          .get(Uri.parse(latestUrl), headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        return (null, '更新服务不可达（HTTP ${res.statusCode}）');
      }
      final html = utf8.decode(res.bodyBytes);
      final ogMatch =
          RegExp(r'og:url"\s+content="([^"]+)"').firstMatch(html);
      final tagMatch =
          RegExp(r'/releases/tag/([^/?]+)').firstMatch(ogMatch?.group(1) ?? '');
      if (tagMatch == null) return (null, '更新清单解析失败');
      final tagName = Uri.decodeComponent(tagMatch.group(1)!);
      if (tagName.isEmpty) return (null, '更新清单解析失败');

      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      // asset 命名约定：watchdog-<版本>-arm64-v8a.apk（CI 构建产出）
      final apkUrl =
          '$repoHome/releases/download/${Uri.encodeComponent(tagName)}/'
          'watchdog-$version-arm64-v8a.apk';
      // sha256 约定写在 release body 的 `SHA256: <hex>` 行（CI 自动生成），
      // markdown 渲染进 HTML 后以纯文本保留
      final shaMatch =
          RegExp(r'SHA256:\s*([0-9a-fA-F]{64})').firstMatch(html);
      return (
        UpdateInfo(tagName: tagName, apkUrl: apkUrl, sha256: shaMatch?.group(1)),
        null,
      );
    } catch (e) {
      return (null, '检查更新失败：$e');
    }
  }

  /// 下载并安装（下载进度 0-100 通过回调上报；错误通过回调 message 返回）
  Future<void> downloadAndInstall(
    UpdateInfo update, {
    void Function(int percent)? onProgress,
    void Function(String message)? onError,
  }) async {
    final completer = Completer<void>();
    StreamSubscription<OtaEvent>? sub;
    try {
      final stream = _ota.execute(
        update.apkUrl,
        headers: {'User-Agent': userAgent},
        sha256checksum: update.sha256,
      );
      sub = stream.listen(
        (event) {
          switch (event.status) {
            case OtaStatus.DOWNLOADING:
              onProgress?.call(int.tryParse(event.value ?? '') ?? 0);
            case OtaStatus.INSTALLING:
              onProgress?.call(100);
            case OtaStatus.INSTALLATION_DONE:
              if (!completer.isCompleted) completer.complete();
            case OtaStatus.ALREADY_RUNNING_ERROR:
            case OtaStatus.INSTALLATION_ERROR:
            case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            case OtaStatus.INTERNAL_ERROR:
            case OtaStatus.DOWNLOAD_ERROR:
            case OtaStatus.CHECKSUM_ERROR:
            case OtaStatus.CANCELED:
              if (!completer.isCompleted) {
                completer.completeError(_errorText(event));
              }
          }
        },
        onError: (Object e) {
          if (!completer.isCompleted) {
            completer.completeError(_errorText(OtaEvent(OtaStatus.INTERNAL_ERROR, '$e')));
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );
      await completer.future.timeout(const Duration(minutes: 15));
    } catch (e) {
      onError?.call(e.toString());
    } finally {
      await sub?.cancel();
    }
  }

  String _errorText(OtaEvent event) {
    final detail = event.value ?? '';
    switch (event.status) {
      case OtaStatus.CHECKSUM_ERROR:
        return '安装包校验失败，请重试';
      case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
        return '需要允许安装未知来源应用';
      case OtaStatus.DOWNLOAD_ERROR:
        return '下载失败（网络异常）$detail';
      case OtaStatus.ALREADY_RUNNING_ERROR:
        return '已有下载任务进行中';
      case OtaStatus.CANCELED:
        return '已取消下载';
      default:
        return '更新失败：${detail.isEmpty ? event.status.name : detail}';
    }
  }
}
