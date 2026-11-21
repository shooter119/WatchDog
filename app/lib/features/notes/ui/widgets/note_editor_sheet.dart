import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/note.dart';
import '../../data/models/note_category.dart';

/// 火场日志编辑弹窗返回结果。
@immutable
class NoteEditorResult {
  const NoteEditorResult.saved({required this.text, required this.category})
    : deleted = false;

  const NoteEditorResult.deleted() : text = '', category = '', deleted = true;

  final String text;
  final String category;
  final bool deleted;
}

/// 弹出基于 [CommandSheet] 的火场日志新增/编辑/删除面板。
///
/// 删除操作使用 [CommandButtonVariant.danger]，默认弹出二次确认 [CommandSheet]。
Future<NoteEditorResult?> showNoteEditorSheet(
  BuildContext context, {
  Note? note,
}) {
  return showModalBottomSheet<NoteEditorResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext routeContext) {
      return _NoteEditorSheet(note: note);
    },
  );
}

class _NoteEditorSheet extends StatefulWidget {
  const _NoteEditorSheet({this.note});

  final Note? note;

  @override
  State<_NoteEditorSheet> createState() => _NoteEditorSheetState();
}

class _NoteEditorSheetState extends State<_NoteEditorSheet> {
  late final TextEditingController _controller;
  late String _category;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.note?.text ?? '');
    _category = widget.note?.category ?? NoteCategory.other;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _formatFullTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(
      context,
    ).pop(NoteEditorResult.saved(text: text, category: _category));
  }

  void _confirmDelete() {
    Navigator.of(context).pop(const NoteEditorResult.deleted());
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final note = widget.note;
    final isEditing = note != null;

    return CommandSheet(
      title: isEditing ? '编辑日志' : '手动记录',
      subtitle: isEditing ? _formatFullTime(note.createdAt) : '记入当前警情火场时间线',
      actions: <Widget>[
        CommandButton(
          key: const Key('note-editor-save-btn'),
          label: isEditing ? '保存修改' : '保存到日志',
          icon: Icons.check_circle_outline_rounded,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          onPressed: _save,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const Key('note-editor-text-field'),
            controller: _controller,
            maxLines: 4,
            minLines: 3,
            maxLength: 2000,
            style: typo.body.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: '记录此刻发生了什么…',
              hintStyle: typo.body.copyWith(color: colors.textTertiary),
              alignLabelWithHint: true,
              filled: true,
              fillColor: colors.surfaceMuted,
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
          Text(
            '日志分类',
            style: typo.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.sm,
            children: <Widget>[
              for (final cat in NoteCategory.all)
                _CategoryChip(
                  label: cat,
                  selected: _category == cat,
                  onTap: () => setState(() => _category = cat),
                ),
            ],
          ),
          if (isEditing) ...<Widget>[
            const SizedBox(height: DsSpacing.lg),
            CommandButton(
              key: const Key('note-editor-delete-btn'),
              label: '删除这条日志',
              icon: Icons.delete_outline_rounded,
              variant: CommandButtonVariant.danger,
              size: CommandButtonSize.standard,
              expanded: true,
              confirmTitle: '删除日志',
              confirmMessage: '确认删除这条日志？\n${note.text}',
              confirmActionLabel: '确认删除',
              onPressed: _confirmDelete,
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? colors.brand : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderPill,
          side: BorderSide(
            color: selected ? colors.brand : colors.border,
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: DsRadius.borderPill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: DsSizes.touchTarget,
              minWidth: DsSizes.touchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.sm,
              ),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: ds.typography.caption.copyWith(
                    color: selected ? colors.onBrand : colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
