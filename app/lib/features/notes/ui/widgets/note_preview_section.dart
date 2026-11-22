import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';
import '../../data/models/note.dart';
import '../../data/models/note_category.dart';

/// 将 [NoteCategory] 映射为 DS v3.0 状态等级与图标，保证时间线与预览语义统一。
(DsStatus, IconData) noteCategoryVisual(String category) {
  return switch (category) {
    NoteCategory.abnormal => (DsStatus.alarm, Icons.warning_amber_rounded),
    NoteCategory.water => (DsStatus.caution, Icons.water_drop_outlined),
    NoteCategory.rescue => (DsStatus.safe, Icons.health_and_safety_outlined),
    NoteCategory.deploy => (DsStatus.neutral, Icons.campaign_outlined),
    NoteCategory.withdraw => (DsStatus.neutral, Icons.logout_rounded),
    _ => (DsStatus.neutral, Icons.notes_rounded),
  };
}

/// 格式化单条日志的次级元信息（修订标记、时间、作者）。
String formatNoteSubtitle(Note note, {DateTime? now}) {
  final edited = note.updatedAt > note.createdAt;
  final ts = edited ? note.updatedAt : note.createdAt;
  final dt = DateTime.fromMillisecondsSinceEpoch(ts);
  final ref = now ?? DateTime.now();
  final isToday =
      dt.year == ref.year && dt.month == ref.month && dt.day == ref.day;
  String two(int n) => n.toString().padLeft(2, '0');
  final dayPrefix = isToday ? '' : '${dt.month}-${two(dt.day)} ';
  final timeText =
      '${edited ? '改 ' : ''}$dayPrefix${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  final author = note.author.trim().isEmpty ? '匿名' : note.author.trim();
  return '$timeText · $author';
}

/// 嵌入指挥台首页的最近火场日志预览区（展示最近 3~5 条）。
///
/// 复用 M0 [TimelineList]，提供 `Key('command-notes-preview')` 与
/// `Key('command-notes-see-all-btn')` 语义契约。
class NotePreviewSection extends StatelessWidget {
  const NotePreviewSection({
    super.key = const Key('command-notes-preview'),
    required this.notes,
    required this.onSeeAll,
    this.onNoteTap,
    this.maxItems = 5,
    this.requiresIncident = false,
    this.now,
  });

  final List<Note> notes;
  final VoidCallback onSeeAll;
  final ValueChanged<Note>? onNoteTap;
  final int maxItems;
  final bool requiresIncident;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final visibleNotes = notes.take(maxItems.clamp(1, 5)).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Text(
                '火场日志',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.title.copyWith(color: colors.textPrimary),
              ),
            ),
            CommandButton(
              key: const Key('command-notes-see-all-btn'),
              label: '查看全部',
              variant: CommandButtonVariant.ghost,
              size: CommandButtonSize.standard,
              onPressed: onSeeAll,
            ),
          ],
        ),
        const SizedBox(height: DsSpacing.sm),
        if (visibleNotes.isEmpty)
          SurfaceCard(
            level: DsSurfaceLevel.outlined,
            onTap: onSeeAll,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.note_alt_outlined,
                  size: DsSizes.iconLg,
                  color: colors.textTertiary,
                ),
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: Text(
                    requiresIncident
                        ? '请先选择或新建警情，再记录火场日志'
                        : '暂无火场日志，长按语音键或点击“查看全部”手动记录',
                    style: typo.caption.copyWith(color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          )
        else
          TimelineList(
            entries: <DsTimelineEntry>[
              for (final note in visibleNotes)
                _toTimelineEntry(note),
            ],
          ),
      ],
    );
  }

  DsTimelineEntry _toTimelineEntry(Note note) {
    final (status, icon) = noteCategoryVisual(note.category);
    final ts = note.updatedAt > note.createdAt ? note.updatedAt : note.createdAt;
    return DsTimelineEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      icon: icon,
      title: note.text,
      subtitle: formatNoteSubtitle(note, now: now),
      status: status,
      categoryLabel: note.category,
      onTap: onNoteTap != null ? () => onNoteTap!(note) : null,
    );
  }
}
