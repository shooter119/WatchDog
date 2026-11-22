import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_version.dart';
import '../../../design_system/design_system.dart';
import '../state/settings_store.dart';
import 'settings_widgets.dart';

/// 「服务连接」展开区：协同服务器地址输入框与同步说明。
class SettingsServerBody extends StatelessWidget {
  const SettingsServerBody({
    super.key,
    required this.serverController,
    required this.serverFocus,
  });

  final TextEditingController serverController;
  final FocusNode serverFocus;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: DsSpacing.md),
          child: TextField(
            controller: serverController,
            focusNode: serverFocus,
            keyboardType: TextInputType.url,
            style: ds.typography.body.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              labelText: '服务器地址',
              hintText: '现场协同服务器地址（Android 模拟器：10.0.2.2:3000）',
              filled: true,
              fillColor: colors.surface,
              border: border,
              enabledBorder: border,
            ),
          ),
        ),
        const SettingsNoticeBanner(
          status: DsStatus.safe,
          icon: DsIcons.sync,
          title: '现场协同同步已开启',
          text: '本机修改优先保存，联网后自动与现场协同服务器同步。',
        ),
      ],
    );
  }
}

/// 设置域标准半屏弹窗与 OTA 流程编排（全部基于 Design System v3.0 `CommandSheet`）。
abstract final class SettingsUpdateSheets {
  static Future<void> runCheckUpdateFlow(
    BuildContext context,
    SettingsStore store,
  ) async {
    final res = await store.checkForUpdate();
    if (!context.mounted) return;
    if (res.blockedByDebugMode) {
      await showResult(
        context,
        title: '测试版环境',
        message: '当前运行的是测试版（火场智控·测试），已与正式版独立隔离。在线更新仅适用于正式版，请使用正式版体验在线升级。',
      );
      return;
    }
    if (res.error != null) {
      await showResult(context, title: '检查更新失败', message: res.error!);
      return;
    }
    if (res.info == null) {
      await showResult(
        context,
        title: '已是最新版本',
        message: '当前版本 ${store.displayVersion(appVersion)} 已是最新',
      );
      return;
    }
    final confirm = await showUpdateAvailable(context, info: res.info!);
    if (confirm && context.mounted) {
      await _runDownloadUpdateFlow(context, store, res.info!);
    }
  }

  static Future<void> _runDownloadUpdateFlow(
    BuildContext context,
    SettingsStore store,
    UpdateInfo info,
  ) async {
    if (!await store.canRequestPackageInstalls()) {
      if (!context.mounted) return;
      if (await showInstallPermission(context)) {
        await store.openUnknownAppSourcesSettings();
      }
      return;
    }
    if (!context.mounted) return;
    final progress = ValueNotifier<int>(0);
    unawaited(showDownloadProgress(context, progress: progress));
    var closed = false;
    void closeProgress() {
      if (!closed && context.mounted) {
        closed = true;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    final result = await store.downloadAndInstallUpdate(
      info,
      onProgress: (p) => progress.value = p,
      onInstalling: () {
        closeProgress();
        if (context.mounted) {
          unawaited(
            showResult(
              context,
              title: '安装中',
              message: '安装包已就绪，请在弹出的系统界面完成安装',
            ),
          );
        }
      },
    );
    progress.dispose();
    if (!context.mounted) return;
    closeProgress();
    if (result.error != null) {
      final err = result.error!;
      if (err.contains('安装未完成') || err.contains('未知来源')) {
        if (await showInstallIncomplete(context, message: err)) {
          await store.openUnknownAppSourcesSettings();
        }
      } else {
        await showResult(context, title: '更新失败', message: err);
      }
    } else if (!result.installPrompted) {
      await showResult(context, title: '下载完成', message: '请在弹出的系统界面完成安装');
    }
  }

  static Future<void> showResult(
    BuildContext context, {
    required String title,
    required String message,
  }) => showCommandSheet<void>(
    context: context,
    title: title,
    builder: (ctx) => Text(
      message,
      style: ctx.ds.typography.body.copyWith(color: ctx.ds.colors.textSecondary),
    ),
    actionsBuilder: (ctx) => <Widget>[
      CommandButton(
        label: '好的',
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(),
      ),
    ],
  );

  static Future<bool> showUpdateAvailable(
    BuildContext context, {
    required UpdateInfo info,
  }) async {
    final sizeText = info.sizeBytes == null
        ? null
        : '安装包大小：${(info.sizeBytes! / 1048576).toStringAsFixed(1)} MB';
    return _confirmSheet(
      context,
      title: '发现新版本 ${info.tagName}',
      subtitle: sizeText,
      message: info.changelog ?? '点击立即更新下载安装',
      cancelLabel: '稍后',
      confirmLabel: '立即更新',
    );
  }

  static Future<bool> showInstallPermission(BuildContext context) => _confirmSheet(
    context,
    title: '需要开启安装权限',
    message: '系统要求先允许本应用“安装未知来源应用”，否则下载完成后无法弹出安装界面。\n\n是否前往系统设置开启？',
    cancelLabel: '取消',
    confirmLabel: '去设置',
  );

  static Future<void> showDownloadProgress(
    BuildContext context, {
    required ValueNotifier<int> progress,
  }) => showCommandSheet<void>(
    context: context,
    title: '正在下载更新',
    subtitle: '下载中请保持应用在前台',
    showCloseButton: false,
    isDismissible: false,
    enableDrag: false,
    useRootNavigator: true,
    builder: (ctx) => ValueListenableBuilder<int>(
      valueListenable: progress,
      builder: (innerCtx, value, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LinearProgressIndicator(
            value: value / 100,
            minHeight: 8,
            borderRadius: DsRadius.borderSm,
          ),
          const SizedBox(height: DsSpacing.md),
          Text(
            '$value%',
            textAlign: TextAlign.center,
            style: innerCtx.ds.typography.metric.copyWith(
              color: innerCtx.ds.colors.textPrimary,
            ),
          ),
        ],
      ),
    ),
  );

  static Future<bool> showInstallIncomplete(
    BuildContext context, {
    required String message,
  }) => _confirmSheet(
    context,
    title: '安装未完成',
    message: message,
    cancelLabel: '知道了',
    confirmLabel: '去设置开启',
  );

  static Future<bool> showOfflineModelConfirm(BuildContext context) => _confirmSheet(
    context,
    title: '未下载本地语音模型',
    message: '关闭联网识别后将使用本地模型，但本地 ASR 主模型尚未下载（约 75MB；另有可选的 9.8MB 降噪模型）。\n\n是否现在下载？',
    cancelLabel: '稍后',
    confirmLabel: '下载',
  );

  static Future<bool> showStorageRecovery(
    BuildContext context, {
    required int availableBytes,
  }) {
    final mb = (availableBytes / (1024 * 1024)).floor();
    return _confirmSheet(
      context,
      title: '设备存储空间不足',
      message: '当前可用空间约 ${mb}MB。为保护当前本地模型和现场数据，App 不会自动删除它们。\n\n'
          '清理空间后可重新下载；暂时也可以继续使用联网语音识别。',
      cancelLabel: '继续联网识别',
      confirmLabel: '去系统存储设置',
    );
  }

  static Future<bool> showLeaveUnitConfirm(
    BuildContext context, {
    required String unitName,
  }) => _confirmSheet(
    context,
    title: '退出当前单位？',
    message: '退出后将清除本机的“$unitName”认证，需要重新输入单位验证码和姓名。',
    cancelLabel: '取消',
    confirmLabel: '退出单位',
    danger: true,
  );

  static Future<bool> _confirmSheet(
    BuildContext context, {
    required String title,
    String? subtitle,
    required String message,
    required String cancelLabel,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: title,
      subtitle: subtitle,
      builder: (ctx) => Text(
        message,
        style: ctx.ds.typography.body.copyWith(
          color: ctx.ds.colors.textSecondary,
        ),
      ),
      actionsBuilder: (ctx) => <Widget>[
        CommandButton(
          label: cancelLabel,
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        CommandButton(
          label: confirmLabel,
          variant: danger
              ? CommandButtonVariant.danger
              : CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    );
    return confirmed == true;
  }
}
