import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design_system/design_system.dart';
import '../../../../services/phone_caller.dart';
import '../../data/models/note.dart';
import '../../data/models/note_category.dart';

/// 火场日志文本中的电话号码正则（手机号 / 带区号座机）。
final RegExp notePhoneRegex = RegExp(
  r'(?:(?:\+?86)?1[3-9]\d{9}|0\d{2,3}-?\d{7,8})',
);

/// 提取单条日志中的去重电话号码列表。
List<String> extractNotePhones(String text) {
  final phones = <String>[];
  for (final match in notePhoneRegex.allMatches(text)) {
    final phone = text.substring(match.start, match.end);
    if (!phones.contains(phone)) phones.add(phone);
  }
  return phones;
}

/// 将 [NoteCategory] 映射为 DS v3.0 状态等级与图标，保证时间线与预览语义统一。
///
/// 遵循克制色彩纪律：仅「异常」点亮告警红，其余常规过程节点统一中性深岩灰。
(DsStatus, IconData) noteCategoryVisual(String category) {
  return switch (category) {
    NoteCategory.abnormal => (DsStatus.alarm, DsIcons.warning),
    NoteCategory.water => (DsStatus.neutral, DsIcons.toolWaterSources),
    NoteCategory.rescue => (DsStatus.neutral, DsIcons.categoryRescueLine),
    NoteCategory.deploy => (DsStatus.neutral, DsIcons.broadcast),
    NoteCategory.withdraw => (DsStatus.neutral, DsIcons.logout),
    _ => (DsStatus.neutral, DsIcons.note),
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
    this.phoneLauncher,
    this.maxItems = 5,
    this.requiresIncident = false,
    this.now,
  });

  final List<Note> notes;
  final VoidCallback onSeeAll;
  final ValueChanged<Note>? onNoteTap;
  final PhoneLauncher? phoneLauncher;
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
                  DsIcons.note,
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
                _toTimelineEntry(context, note),
            ],
          ),
      ],
    );
  }

  Future<void> _copyPhone(BuildContext context, String phone) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: phone));
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制号码: $phone'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  DsTimelineEntry _toTimelineEntry(BuildContext context, Note note) {
    final (status, icon) = noteCategoryVisual(note.category);
    final ts = note.updatedAt > note.createdAt ? note.updatedAt : note.createdAt;
    final phones = extractNotePhones(note.text);
    return DsTimelineEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      icon: icon,
      title: note.text,
      footer: phones.isEmpty
          ? null
          : NotePhoneChips(
              phones: phones,
              onCall: (String phone) => PhoneCaller.dial(
                context,
                phone,
                launcher: phoneLauncher,
              ),
              onLongPress: (String phone) =>
                  unawaited(_copyPhone(context, phone)),
            ),
      subtitle: formatNoteSubtitle(note, now: now),
      status: status,
      categoryLabel: note.category,
      onTap: onNoteTap != null ? () => onNoteTap!(note) : null,
    );
  }
}

/// 嵌入单条日志卡片内部的电话一键拨号芯片组（左对齐正文，保持 ≥48dp 触控热区）。
class NotePhoneChips extends StatelessWidget {
  const NotePhoneChips({
    super.key,
    required this.phones,
    required this.onCall,
    required this.onLongPress,
  });

  final List<String> phones;
  final ValueChanged<String> onCall;
  final ValueChanged<String> onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final typo = context.ds.typography;
    return Wrap(
      spacing: DsSpacing.sm,
      runSpacing: DsSpacing.xs,
      children: <Widget>[
        for (final phone in phones)
          Semantics(
            button: true,
            label: '呼叫 $phone',
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: Key('note-phone-call-$phone'),
                borderRadius: DsRadius.borderPill,
                onTap: () => onCall(phone),
                onLongPress: () => onLongPress(phone),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: DsSizes.touchTarget,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.brand.withValues(alpha: 0.08),
                        borderRadius: DsRadius.borderPill,
                        border: Border.all(
                          color: colors.brand.withValues(alpha: 0.24),
                          width: 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              DsIcons.phone,
                              size: DsSizes.iconSm,
                              color: colors.brandText,
                            ),
                            const SizedBox(width: DsSpacing.xs),
                            Text(
                              phone,
                              style: typo.captionTabular.copyWith(
                                color: colors.brandText,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                                decorationColor:
                                    colors.brandText.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
