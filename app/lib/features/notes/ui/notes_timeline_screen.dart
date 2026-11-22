import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design_system/design_system.dart';
import '../../../services/phone_caller.dart';
import '../data/models/note.dart';
import '../data/models/note_category.dart';
import '../state/notes_store.dart';
import 'widgets/note_editor_sheet.dart';
import 'widgets/note_preview_section.dart';

/// 火场日志全量时间线页面（Design System v3.0）。
///
/// 复用 M0 [TimelineList]，按分钟分组并经 [ListView.builder] 懒渲染以保障
/// 200+ 条日志高速滚动流畅；保留 `Key('notes-manual-log-fab')` 入口、分类筛选、
/// 新增/编辑/二次确认删除以及基于冻结 [PhoneCaller] 的号码高亮直拨能力。
class NotesTimelineScreen extends StatefulWidget {
  const NotesTimelineScreen({
    super.key,
    required this.store,
    this.requiresIncident = false,
    this.connectionState = DsConnectionState.online,
    this.pendingSyncCount = 0,
    this.isOffline = false,
    this.onRefresh,
    this.onOpenTacticalBrief,
    this.onConnectionTap,
    this.onRequestIncidentSelection,
    this.phoneLauncher,
    this.now,
  });

  final NotesStore store;
  final bool requiresIncident;
  final DsConnectionState connectionState;
  final int pendingSyncCount;
  final bool isOffline;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenTacticalBrief;
  final VoidCallback? onConnectionTap;
  final VoidCallback? onRequestIncidentSelection;
  final PhoneLauncher? phoneLauncher;
  final DateTime? now;

  static final RegExp phoneRegex = RegExp(
    r'(?:(?:\+?86)?1[3-9]\d{9}|0\d{2,3}-?\d{7,8})',
  );

  @override
  State<NotesTimelineScreen> createState() => _NotesTimelineScreenState();
}

class _MinuteNoteGroup {
  _MinuteNoteGroup({
    required this.anchor,
    required this.notes,
  });

  final DateTime anchor;
  final List<Note> notes;
}

class _NotesTimelineScreenState extends State<NotesTimelineScreen> {
  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  List<_MinuteNoteGroup> _groupByMinute(List<Note> notes) {
    final groups = <_MinuteNoteGroup>[];
    for (final note in notes) {
      final ts = note.updatedAt > note.createdAt ? note.updatedAt : note.createdAt;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      if (groups.isNotEmpty && _sameMinute(groups.last.anchor, dt)) {
        groups.last.notes.add(note);
      } else {
        groups.add(_MinuteNoteGroup(anchor: dt, notes: <Note>[note]));
      }
    }
    return groups;
  }

  List<String> _extractPhones(List<Note> notes) {
    final phones = <String>[];
    for (final note in notes) {
      for (final match in NotesTimelineScreen.phoneRegex.allMatches(note.text)) {
        final phone = note.text.substring(match.start, match.end);
        if (!phones.contains(phone)) phones.add(phone);
      }
    }
    return phones;
  }

  Future<void> _openEditor(Note? note) async {
    if (note == null && widget.requiresIncident) {
      widget.onRequestIncidentSelection?.call();
      return;
    }
    final result = await showNoteEditorSheet(context, note: note);
    if (result == null || !mounted) return;
    if (result.deleted && note != null) {
      await _deleteNote(note);
      return;
    }
    try {
      if (note == null) {
        await widget.store.addNote(result.text, category: result.category);
        if (mounted) _showToast('已记入日志');
      } else {
        await widget.store.updateNote(
          note.id,
          text: result.text,
          category: result.category,
        );
        if (mounted) _showToast('已保存修改');
      }
    } catch (error) {
      if (mounted) _showToast('保存失败：$error');
    }
  }

  Future<void> _deleteNote(Note note) async {
    try {
      await widget.store.deleteNote(note.id);
      if (mounted) _showToast('已删除');
    } catch (error) {
      if (mounted) _showToast('删除失败：$error');
    }
  }

  void _showToast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _copyPhone(String phone) async {
    await Clipboard.setData(ClipboardData(text: phone));
    if (mounted) _showToast('已复制号码: $phone');
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return ListenableBuilder(
      listenable: widget.store,
      builder: (BuildContext context, Widget? _) {
        final filtered = widget.store.filteredNotes;
        final groups = _groupByMinute(filtered);
        final selected = widget.store.selectedCategory;

        return CommandScaffold(
          isOffline: widget.isOffline,
          onOfflineTap: widget.onConnectionTap,
          appBar: AppBar(
            title: Text(
              '火场日志',
              style: typo.headline.copyWith(color: colors.textPrimary),
            ),
            actions: <Widget>[
              if (widget.onOpenTacticalBrief != null)
                IconButton(
                  key: const Key('notes-tactical-brief-btn'),
                  tooltip: '警情上报',
                  icon: const Icon(Icons.description_outlined),
                  constraints: const BoxConstraints(
                    minWidth: DsSizes.touchTarget,
                    minHeight: DsSizes.touchTarget,
                  ),
                  onPressed: widget.onOpenTacticalBrief,
                ),
              Padding(
                padding: const EdgeInsets.only(right: DsSpacing.md),
                child: Center(
                  child: ConnectionPill(
                    state: widget.connectionState,
                    pendingCount: widget.pendingSyncCount,
                    onTap: widget.onConnectionTap,
                  ),
                ),
              ),
            ],
          ),
          body: Stack(
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildCategoryFilterBar(context, selected),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: widget.onRefresh ?? () async {},
                      child: groups.isEmpty
                          ? _buildEmptyState()
                          : ListView.builder(
                              key: const Key('notes-timeline-list'),
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(
                                DsSpacing.pageMargin,
                                DsSpacing.sm,
                                DsSpacing.pageMargin,
                                96,
                              ),
                              itemCount: groups.length,
                              itemBuilder: (BuildContext context, int index) {
                                final group = groups[index];
                                return _buildMinuteGroup(context, group);
                              },
                            ),
                    ),
                  ),
                ],
              ),
              Positioned(
                right: DsSpacing.pageMargin,
                bottom: DsSpacing.pageMargin,
                child: Semantics(
                  button: true,
                  label: '手动记录日志',
                  child: FloatingActionButton(
                    key: const Key('notes-manual-log-fab'),
                    tooltip: '手动记录日志',
                    backgroundColor: colors.brand,
                    foregroundColor: colors.onBrand,
                    elevation: 2,
                    highlightElevation: 3,
                    shape: CircleBorder(
                      side: BorderSide(color: colors.surface, width: 1.5),
                    ),
                    onPressed: () => _openEditor(null),
                    child: const Icon(Icons.add_rounded, size: 28),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCategoryFilterBar(BuildContext context, String selected) {
    final ds = context.ds;
    final colors = ds.colors;
    final categories = <String>[NotesStore.allCategory, ...NoteCategory.all];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.pageMargin,
        vertical: DsSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < categories.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: DsSpacing.sm),
            _FilterPill(
              label: categories[i],
              selected: selected == categories[i],
              colors: colors,
              onTap: () => widget.store.setCategory(categories[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: StatePlaceholder.empty(
              icon: Icons.note_alt_outlined,
              message: '还没有日志记录',
              detail: widget.requiresIncident
                  ? '请先选择或新建警情，再记录火场日志'
                  : '点击右下角加号手动记录，或返回指挥台长按语音键说话',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMinuteGroup(BuildContext context, _MinuteNoteGroup group) {
    final entries = <DsTimelineEntry>[
      for (final note in group.notes) _toEntry(note),
    ];
    final phones = _extractPhones(group.notes);

    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TimelineList(entries: entries),
          if (phones.isNotEmpty) ...<Widget>[
            const SizedBox(height: DsSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Wrap(
                spacing: DsSpacing.sm,
                runSpacing: DsSpacing.xs,
                children: <Widget>[
                  for (final phone in phones)
                    _PhoneActionChip(
                      phone: phone,
                      onCall: () => PhoneCaller.dial(
                        context,
                        phone,
                        launcher: widget.phoneLauncher,
                      ),
                      onLongPress: () => _copyPhone(phone),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  DsTimelineEntry _toEntry(Note note) {
    final (status, icon) = noteCategoryVisual(note.category);
    final ts = note.updatedAt > note.createdAt ? note.updatedAt : note.createdAt;
    return DsTimelineEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      icon: icon,
      title: note.text,
      subtitle: formatNoteSubtitle(note, now: widget.now),
      status: status,
      categoryLabel: note.category,
      onTap: () => _openEditor(note),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final DsColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: DsRadius.borderPill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: DsSizes.touchTarget,
              minWidth: DsSizes.touchTarget,
            ),
            child: Center(
              widthFactor: 1,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: selected ? colors.brand : colors.surface,
                  borderRadius: DsRadius.borderPill,
                  border: Border.all(
                    color: selected ? colors.brand : colors.border,
                    width: 1,
                  ),
                ),
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

class _PhoneActionChip extends StatelessWidget {
  const _PhoneActionChip({
    required this.phone,
    required this.onCall,
    required this.onLongPress,
  });

  final String phone;
  final VoidCallback onCall;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Semantics(
      button: true,
      label: '呼叫 $phone',
      child: Material(
        key: Key('note-phone-call-$phone'),
        color: colors.brand.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: DsRadius.borderPill,
          side: BorderSide(
            color: colors.brand.withValues(alpha: 0.28),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: DsRadius.borderPill,
          onTap: onCall,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.phone_in_talk_outlined,
                    size: DsSizes.iconSm,
                    color: colors.brandText,
                  ),
                  const SizedBox(width: DsSpacing.xs),
                  Text(
                    phone,
                    style: ds.typography.captionTabular.copyWith(
                      color: colors.brandText,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                      decorationColor: colors.brandText.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
