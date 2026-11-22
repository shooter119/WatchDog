import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../design_system/design_system.dart';

/// 默认拍照识险关注重点文案。
const String defaultCopilotVisionPrompt = '请分析这张图片中与消防救援相关的内容。';

/// 通过 DS v3.0 [CommandSheet] 选择图片来源（拍照 / 从相册选择）。
Future<ImageSource?> showCopilotVisionSourceSheet(BuildContext context) {
  return showCommandSheet<ImageSource>(
    context: context,
    title: '拍照识险',
    subtitle: '上传现场照片（自动压缩至宽 ≤1600px、JPG ≤8MB）',
    builder: (BuildContext sheetContext) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _VisionSourceTile(
            key: const Key('chat-vision-source-camera'),
            icon: DsIcons.camera,
            title: '拍照',
            subtitle: '立即拍摄现场危化标识、烟势或建筑结构',
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
          ),
          const SizedBox(height: DsSpacing.md),
          _VisionSourceTile(
            key: const Key('chat-vision-source-gallery'),
            icon: DsIcons.photoLibrary,
            title: '从相册选择',
            subtitle: '选取本机已有现场照片进行风险研判',
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
          ),
        ],
      );
    },
  );
}

/// 通过 DS v3.0 [CommandSheet] 确认拍照识险关注重点，并明示 4 段结构化输出与免责声明。
Future<String?> showCopilotVisionPromptSheet(
  BuildContext context, {
  String initialPrompt = defaultCopilotVisionPrompt,
}) async {
  final controller = TextEditingController(text: initialPrompt);
  try {
    return await showCommandSheet<String>(
      context: context,
      title: '确认图片分析',
      subtitle: '可补充关注重点，结果按 4 段结构化输出',
      builder: (BuildContext sheetContext) {
        final ds = sheetContext.ds;
        final colors = ds.colors;
        final typo = ds.typography;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const Key('chat-vision-prompt-field'),
              controller: controller,
              maxLines: 3,
              style: typo.body.copyWith(color: colors.textPrimary),
              cursorColor: colors.brand,
              decoration: InputDecoration(
                hintText: '可补充关注重点',
                hintStyle: typo.body.copyWith(color: colors.textTertiary),
                filled: true,
                fillColor: colors.surfaceMuted,
                contentPadding: const EdgeInsets.all(DsSpacing.md),
                border: OutlineInputBorder(
                  borderRadius: DsRadius.borderMd,
                  borderSide: BorderSide(color: colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: DsRadius.borderMd,
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: DsRadius.borderMd,
                  borderSide: BorderSide(color: colors.brand, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: DsSpacing.md),
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              borderRadius: DsRadius.borderMd,
              padding: const EdgeInsets.all(DsSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        DsIcons.checkCircle,
                        size: DsSizes.iconSm,
                        color: colors.brandText,
                      ),
                      const SizedBox(width: DsSpacing.xs),
                      Expanded(
                        child: Text(
                          '结构化研判维度',
                          style: typo.caption.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    '已确认事实 · 可能风险 · 待确认事项 · 建议措施',
                    style: typo.caption.copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    '以上为图片辅助分析，不替代现场专业判断与指挥口令。',
                    style: typo.micro.copyWith(color: colors.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        );
      },
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(),
        ),
        CommandButton(
          key: const Key('chat-vision-confirm-send'),
          label: '发送',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () =>
              Navigator.of(sheetContext).pop(controller.text.trim()),
        ),
      ],
    );
  } finally {
    controller.dispose();
  }
}

class _VisionSourceTile extends StatelessWidget {
  const _VisionSourceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: DsSizes.primaryAction),
      child: SurfaceCard(
        level: DsSurfaceLevel.outlined,
        borderRadius: DsRadius.borderMd,
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.lg,
          vertical: DsSpacing.md,
        ),
        onTap: onTap,
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: DsRadius.borderMd,
              ),
              child: Icon(
                icon,
                size: DsSizes.iconMd,
                color: colors.brandText,
              ),
            ),
            const SizedBox(width: DsSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    style: ds.typography.title.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: ds.typography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: DsSpacing.sm),
            Icon(
              DsIcons.chevronRight,
              size: DsSizes.iconMd,
              color: colors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
