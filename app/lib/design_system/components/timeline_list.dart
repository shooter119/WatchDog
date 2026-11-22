import 'package:flutter/material.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';
import 'state_placeholder.dart';
import 'surface_card.dart';

/// [TimelineList] 单条事件记录数据模型。
@immutable
class DsTimelineEntry {
  const DsTimelineEntry({
    required this.timestamp,
    required this.icon,
    required this.title,
    this.subtitle,
    this.footer,
    this.status = DsStatus.neutral,
    this.categoryLabel,
    this.onTap,
  });

  final DateTime timestamp;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? footer;
  final DsStatus status;
  final String? categoryLabel;
  final VoidCallback? onTap;
}

class _MinuteGroup {
  _MinuteGroup({
    required this.anchor,
    required this.minuteLabel,
    required this.entries,
  });

  final DateTime anchor;
  final String minuteLabel;
  final List<DsTimelineEntry> entries;
}

/// Design System v3.0 火场事件时间线列表。
///
/// 保持调用方输入顺序不篡改，将连续处于同一分钟 `(year, month, day, hour, minute)`
/// 的记录合并在同一 `HH:mm` 等宽数字时间戳下展示。
class TimelineList extends StatelessWidget {
  const TimelineList({
    super.key,
    required this.entries,
    this.emptyBuilder,
    this.connectLastToNext = false,
  });

  final List<DsTimelineEntry> entries;
  final WidgetBuilder? emptyBuilder;

  /// 当多个 [TimelineList] 在外层分段列表（如按分钟分片的 `ListView.builder`）中
  /// 纵向拼接时，设为 `true` 可让最后一条卡片向下一分组保持竖线连通与等距间距。
  final bool connectLastToNext;

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  static String _formatMinute(DateTime ts) {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  List<_MinuteGroup> _groupConsecutive() {
    final groups = <_MinuteGroup>[];
    for (final entry in entries) {
      if (groups.isNotEmpty && _sameMinute(groups.last.anchor, entry.timestamp)) {
        groups.last.entries.add(entry);
      } else {
        groups.add(
          _MinuteGroup(
            anchor: entry.timestamp,
            minuteLabel: _formatMinute(entry.timestamp),
            entries: <DsTimelineEntry>[entry],
          ),
        );
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return emptyBuilder?.call(context) ??
          const StatePlaceholder.empty(message: '暂无时间线记录');
    }

    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final groups = _groupConsecutive();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var g = 0; g < groups.length; g++)
          _TimelineGroupRow(
            group: groups[g],
            isLastGroup: g == groups.length - 1,
            connectLastToNext: connectLastToNext,
            timeStyle: typo.captionTabular.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

class _TimelineGroupRow extends StatelessWidget {
  const _TimelineGroupRow({
    required this.group,
    required this.isLastGroup,
    required this.connectLastToNext,
    required this.timeStyle,
  });

  final _MinuteGroup group;
  final bool isLastGroup;
  final bool connectLastToNext;
  final TextStyle timeStyle;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: DsSpacing.xs),
          child: Text(group.minuteLabel, style: timeStyle),
        ),
        const SizedBox(width: DsSpacing.sm),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < group.entries.length; i++) ...<Widget>[
                Builder(
                  builder: (BuildContext context) {
                    final entry = group.entries[i];
                    final isVeryLast =
                        isLastGroup && i == group.entries.length - 1;
                    final showConnector = !isVeryLast || connectLastToNext;
                    final statusPair = colors.statusColors(entry.status);

                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(
                            width: 28,
                            child: Column(
                              children: <Widget>[
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: statusPair.pillBg,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: statusPair.fill
                                          .withValues(alpha: 0.35),
                                      width: 1,
                                    ),
                                  ),
                                  child: Icon(
                                    entry.icon,
                                    size: DsSizes.iconSm,
                                    color: statusPair.text,
                                  ),
                                ),
                                if (showConnector)
                                  Expanded(
                                    child: Container(
                                      width: 1.5,
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 2,
                                      ),
                                      color: colors.border,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: DsSpacing.sm),
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                bottom: showConnector ? DsSpacing.md : 0,
                              ),
                              child: SurfaceCard(
                                level: DsSurfaceLevel.outlined,
                                padding: const EdgeInsets.all(DsSpacing.md),
                                onTap: entry.onTap,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    if (entry.categoryLabel != null &&
                                        entry.categoryLabel!
                                            .isNotEmpty) ...<Widget>[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: DsSpacing.sm,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: statusPair.pillBg,
                                          borderRadius: DsRadius.borderSm,
                                        ),
                                        child: Text(
                                          entry.categoryLabel!,
                                          style: typo.micro.copyWith(
                                            color: statusPair.text,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: DsSpacing.xs),
                                    ],
                                    Text(
                                      entry.title,
                                      style: typo.body.copyWith(
                                        color: colors.textPrimary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (entry.footer != null) ...<Widget>[
                                      const SizedBox(height: DsSpacing.xs),
                                      entry.footer!,
                                    ],
                                    if (entry.subtitle != null &&
                                        entry.subtitle!.isNotEmpty) ...<Widget>[
                                      const SizedBox(height: DsSpacing.xs),
                                      Text(
                                        entry.subtitle!,
                                        style: typo.caption.copyWith(
                                          color: colors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
