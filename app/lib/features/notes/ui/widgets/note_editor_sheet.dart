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
/// 遵循 DS v3.0 `[ds:restrained-destructive]` 与 `[ds:sheet-form-layout]`：
/// - 删除入口使用克制描边 [CommandButtonVariant.dangerOutlined] 且与保存主按钮同为 56dp（[CommandButtonSize.large]）；
/// - 点击删除默认弹出二次确认 [CommandSheet]，确认抽屉内使用实心红 [CommandButtonVariant.danger]。
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
  static const int _maxLength = 2000;
  static const int _counterWarningThreshold = 1800;

  late final TextEditingController _controller;
  late String _category;
  late int _textLength;
  late bool _canSave;

  @override
  void initState() {
    super.initState();
    final initialText = widget.note?.text ?? '';
    _controller = TextEditingController(text: initialText);
    _category = widget.note?.category ?? NoteCategory.other;
    _textLength = initialText.characters.length;
    _canSave = initialText.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final nextLength = _controller.text.characters.length;
    final nextCanSave = _controller.text.trim().isNotEmpty;
    if (nextLength != _textLength || nextCanSave != _canSave) {
      setState(() {
        _textLength = nextLength;
        _canSave = nextCanSave;
      });
    }
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
    final counterNearLimit = _textLength >= _counterWarningThreshold;

    return CommandSheet(
      title: isEditing ? '编辑日志' : '手动记录',
      subtitle: isEditing ? _formatFullTime(note.createdAt) : '记入当前警情火场时间线',
      actions: <Widget>[
        CommandButton(
          key: const Key('note-editor-save-btn'),
          label: isEditing ? '保存修改' : '保存到日志',
          icon: DsIcons.checkCircle,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          enabled: _canSave,
          onPressed: _save,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '日志内容',
                  style: typo.caption.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$_textLength/$_maxLength',
                key: const Key('note-editor-char-counter'),
                style: typo.captionTabular.copyWith(
                  color: counterNearLimit
                      ? colors.cautionText
                      : colors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          TextField(
            key: const Key('note-editor-text-field'),
            controller: _controller,
            maxLines: 4,
            minLines: 3,
            maxLength: _maxLength,
            buildCounter:
                (
                  BuildContext context, {
                  required int currentLength,
                  required bool isFocused,
                  required int? maxLength,
                }) => null,
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
          const SizedBox(height: DsSpacing.lg),
          Text(
            '日志分类',
            style: typo.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          _CategoryGrid(
            categories: NoteCategory.all,
            selectedCategory: _category,
            onSelected: (String cat) => setState(() => _category = cat),
          ),
          if (isEditing) ...<Widget>[
            const SizedBox(height: DsSpacing.lg),
            CommandButton(
              key: const Key('note-editor-delete-btn'),
              label: '删除这条日志',
              icon: DsIcons.delete,
              variant: CommandButtonVariant.danger,
              size: CommandButtonSize.large,
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

/// 响应式规整等宽分类网格（常规 3 列 × 2 行，大字号/极窄屏自动降为 2 列 × 3 行）。
class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({
    required this.categories,
    required this.selectedCategory,
    required this.onSelected,
  });

  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final columns = (constraints.maxWidth < 280 || textScale > 1.15)
            ? 2
            : 3;
        final rows = <Widget>[];
        for (var i = 0; i < categories.length; i += columns) {
          if (i > 0) {
            rows.add(const SizedBox(height: DsSpacing.sm));
          }
          final rowChildren = <Widget>[];
          for (var col = 0; col < columns; col++) {
            if (col > 0) {
              rowChildren.add(const SizedBox(width: DsSpacing.sm));
            }
            final index = i + col;
            if (index < categories.length) {
              final cat = categories[index];
              rowChildren.add(
                Expanded(
                  child: _CategoryChip(
                    label: cat,
                    selected: selectedCategory == cat,
                    onTap: () => onSelected(cat),
                  ),
                ),
              );
            } else {
              rowChildren.add(const Expanded(child: SizedBox.shrink()));
            }
          }
          rows.add(Row(children: rowChildren));
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
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
      excludeSemantics: true,
      child: Material(
        color: selected ? colors.brand : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderMd,
          side: BorderSide(
            color: selected ? colors.brand : colors.border,
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: DsRadius.borderMd,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: DsSizes.touchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.sm,
                vertical: DsSpacing.xs,
              ),
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
