import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/incident_import_store.dart';

/// 警情导入阶段 1：输入采集视图（续传卡片、警情文字输入、多图拖拽排序与旋转预览）。
class IncidentImportInputView extends StatelessWidget {
  const IncidentImportInputView({
    super.key,
    required this.store,
    required this.textController,
    required this.textFocusNode,
    required this.onPickCamera,
    required this.onPickGallery,
    required this.onPreviewImage,
  });

  final IncidentImportStore store;
  final TextEditingController textController;
  final FocusNode textFocusNode;
  final VoidCallback onPickCamera;
  final VoidCallback onPickGallery;
  final void Function(int index) onPreviewImage;

  static const Map<String, String> _resumeStatusLabels = <String, String>{
    'queued': '等待分析',
    'processing': '正在分析',
    'ready': '待核对',
    'partial': '部分完成',
    'failed': '分析失败，可重试',
  };

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final images = store.images;
    final resume = store.resumeTask;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (resume != null) ...<Widget>[
          SurfaceCard(
            key: const Key('import-resume-card'),
            level: DsSurfaceLevel.outlined,
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.md,
              vertical: DsSpacing.xs,
            ),
            onTap: store.busy ? null : store.resumeUnfinishedTask,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.history_outlined, color: colors.textSecondary),
              title: Text(
                '继续未完成的导入',
                style: typo.body.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              subtitle: Text(
                '状态：${_resumeStatusLabels[resume['status']] ?? '待处理'}',
                style: typo.caption.copyWith(color: colors.textSecondary),
              ),
              trailing: Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
            ),
          ),
          const SizedBox(height: DsSpacing.md),
        ],
        if (images.isEmpty)
          TextField(
            key: const Key('import-text-field'),
            controller: textController,
            focusNode: textFocusNode,
            enabled: !store.busy,
            minLines: 8,
            maxLines: 16,
            maxLength: 20000,
            onChanged: store.setInputText,
            style: typo.body.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              labelText: '警情文字',
              hintText: '粘贴接处警通报或警情信息',
              alignLabelWithHint: true,
              filled: true,
              fillColor: colors.surface,
              border: border,
              enabledBorder: border,
              focusedBorder: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.brand, width: 1.5),
              ),
            ),
          ),
        if (images.isNotEmpty) ...<Widget>[
          Text(
            '已选${images.length}/9张 · 长按拖动排序',
            style: typo.captionTabular.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          SizedBox(
            height: 312,
            child: ReorderableListView.builder(
              key: const Key('import-images-list'),
              buildDefaultDragHandles: false,
              itemCount: images.length,
              onReorder: store.reorderImages,
              itemBuilder: (BuildContext context, int index) {
                final bytes = images[index];
                return ReorderableDelayedDragStartListener(
                  key: ObjectKey(bytes),
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                    child: SurfaceCard(
                      level: DsSurfaceLevel.outlined,
                      padding: const EdgeInsets.symmetric(
                        horizontal: DsSpacing.md,
                        vertical: DsSpacing.sm,
                      ),
                      child: Row(
                        children: <Widget>[
                          GestureDetector(
                            onTap: () => onPreviewImage(index),
                            child: ClipRRect(
                              borderRadius: DsRadius.borderSm,
                              child: Image.memory(
                                bytes,
                                width: 52,
                                height: 56,
                                fit: BoxFit.cover,
                                cacheWidth: 120,
                                errorBuilder: (_, _, _) => Container(
                                  width: 52,
                                  height: 56,
                                  color: colors.surfaceMuted,
                                  alignment: Alignment.center,
                                  child: Icon(
                                    Icons.image_outlined,
                                    color: colors.textTertiary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: DsSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  '第${index + 1}张',
                                  style: typo.body.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: colors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${(bytes.length / 1024).round()} KB',
                                  style: typo.captionTabular.copyWith(
                                    color: colors.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            key: Key('import-image-rotate-$index'),
                            tooltip: '旋转',
                            constraints: const BoxConstraints(
                              minWidth: DsSizes.touchTarget,
                              minHeight: DsSizes.touchTarget,
                            ),
                            onPressed: store.busy ? null : () => store.rotateImage(index),
                            icon: Icon(
                              Icons.rotate_right_rounded,
                              color: colors.textPrimary,
                            ),
                          ),
                          IconButton(
                            key: Key('import-image-remove-$index'),
                            tooltip: '移除',
                            constraints: const BoxConstraints(
                              minWidth: DsSizes.touchTarget,
                              minHeight: DsSizes.touchTarget,
                            ),
                            onPressed: store.busy ? null : () => store.removeImage(index),
                            icon: Icon(Icons.close_rounded, color: colors.textSecondary),
                          ),
                          Icon(Icons.drag_handle_rounded, color: colors.textTertiary),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: DsSpacing.sm),
        Wrap(
          spacing: DsSpacing.sm,
          runSpacing: DsSpacing.sm,
          children: <Widget>[
            CommandButton(
              key: const Key('import-pick-camera-btn'),
              label: '拍照',
              icon: Icons.camera_alt_outlined,
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              enabled: !store.busy,
              onPressed: onPickCamera,
            ),
            CommandButton(
              key: const Key('import-pick-gallery-btn'),
              label: '相册',
              icon: Icons.photo_library_outlined,
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              enabled: !store.busy,
              onPressed: onPickGallery,
            ),
          ],
        ),
        const SizedBox(height: DsSpacing.md),
        CommandButton(
          key: const Key('import-start-btn'),
          label: store.busy ? '正在处理…' : '开始分析',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          enabled: !store.busy,
          isLoading: store.busy,
          onPressed: store.startImport,
        ),
      ],
    );
  }
}
