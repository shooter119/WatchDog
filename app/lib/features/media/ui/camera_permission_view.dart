import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 水印相机权限被拒时的引导界面（取景黑底 + 高对比说明 + 48/56dp 触控按钮）。
class CameraPermissionView extends StatelessWidget {
  const CameraPermissionView({
    super.key,
    required this.onClose,
    required this.onOpenSettings,
    required this.onRequestAgain,
  });

  final VoidCallback onClose;
  final VoidCallback onOpenSettings;
  final VoidCallback onRequestAgain;

  @override
  Widget build(BuildContext context) {
    final typo = context.ds.typography;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(
            DsIcons.close,
            color: Colors.white,
            size: DsSizes.iconLg,
          ),
          style: IconButton.styleFrom(
            minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
          ),
          onPressed: onClose,
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpacing.xxl),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  DsIcons.cameraOff,
                  size: 48,
                  color: Colors.white54,
                ),
                const SizedBox(height: DsSpacing.lg),
                Text(
                  '需要相机权限才能拍摄现场资料',
                  textAlign: TextAlign.center,
                  style: typo.title.copyWith(color: Colors.white),
                ),
                const SizedBox(height: DsSpacing.sm),
                Text(
                  '拍摄内容只保存在本机，不会自动上传',
                  textAlign: TextAlign.center,
                  style: typo.caption.copyWith(color: Colors.white60),
                ),
                const SizedBox(height: DsSpacing.sm),
                Text(
                  '麦克风用于记录现场口述；定位用于在水印标注拍摄地点。未授权时不会填入推测位置。',
                  textAlign: TextAlign.center,
                  style: typo.body.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: DsSpacing.md),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size(
                      DsSizes.touchTarget,
                      DsSizes.touchTarget,
                    ),
                  ),
                  onPressed: onOpenSettings,
                  child: const Text('去系统设置'),
                ),
                const SizedBox(height: DsSpacing.lg),
                CommandButton(
                  label: '重新授权',
                  variant: CommandButtonVariant.primary,
                  size: CommandButtonSize.large,
                  onPressed: onRequestAgain,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
