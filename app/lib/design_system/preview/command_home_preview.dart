import 'package:flutter/material.dart';

import '../components/command_button.dart';
import '../components/command_nav_bar.dart';
import '../components/command_scaffold.dart';
import '../components/command_sheet.dart';
import '../components/incident_header.dart';
import '../components/metric_readout.dart';
import '../components/status_pill.dart';
import '../components/surface_card.dart';
import '../components/timeline_list.dart';
import '../components/tool_grid.dart';
import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_spacing.dart';
import 'preview_fixtures.dart';

/// Design System v3.0 指挥台（首页）静态视觉原型。
class CommandHomePreview extends StatelessWidget {
  const CommandHomePreview({
    super.key,
    this.voiceState = DsVoiceState.idle,
    this.onSelectTab,
    this.onVoiceTap,
  });

  final DsVoiceState voiceState;
  final ValueChanged<int>? onSelectTab;
  final VoidCallback? onVoiceTap;

  void _showDemoNotice(BuildContext context, String message) {
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

  Future<void> _openBriefSheet(BuildContext context) {
    final counts = PreviewFixtures.countByStatus();
    return showCommandSheet<void>(
      context: context,
      title: '现场战术简报',
      subtitle: PreviewFixtures.incident.name,
      builder: (BuildContext sheetContext) {
        final sheetDs = sheetContext.ds;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              PreviewFixtures.incident.briefSummary,
              style: sheetDs.typography.body.copyWith(
                color: sheetDs.colors.textPrimary,
              ),
            ),
            const SizedBox(height: DsSpacing.md),
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              padding: const EdgeInsets.all(DsSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '态势要点',
                    style: sheetDs.typography.title.copyWith(
                      color: sheetDs.colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: DsSpacing.sm),
                  Text(
                    '• 参战力量：${PreviewFixtures.incident.forceSummary}，在场内攻 ${PreviewFixtures.personnel.length} 人\n'
                    '• 重点关注：超时 ${counts[DsStatus.timeout]} 人、告警 ${counts[DsStatus.alarm]} 人（均在内攻一组）\n'
                    '• 通联状态：前指无线中继与本地离线队列双通道就绪',
                    style: sheetDs.typography.body.copyWith(
                      color: sheetDs.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '关闭简报',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(),
        ),
      ],
    );
  }

  Future<void> _openAllTimelineSheet(BuildContext context) {
    final entries = PreviewFixtures.buildTimelineEntries();
    return showCommandSheet<void>(
      context: context,
      title: '全部火场日志',
      subtitle: '共 ${entries.length} 条记录（原型演示数据）',
      builder: (BuildContext sheetContext) {
        return TimelineList(entries: entries);
      },
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '返回指挥台',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typography = ds.typography;
    final counts = PreviewFixtures.countByStatus();
    final highestRisk = PreviewFixtures.highestRiskStatus();
    final urgentCount =
        (counts[DsStatus.timeout] ?? 0) + (counts[DsStatus.alarm] ?? 0);

    final tools = PreviewFixtures.buildHomeTools(
      onToolTap: (item) => _showDemoNotice(
        context,
        '已点击「${item.label}」（M0 原型演示，未跳转真实页面）',
      ),
    );
    final entries = PreviewFixtures.buildTimelineEntries(
      onEntryTap: (title) => _showDemoNotice(context, '日志详情：$title'),
    );

    return CommandScaffold(
      bottomNavigationBar: CommandNavBar(
        selectedIndex: 0,
        voiceState: voiceState,
        onSelectTab: onSelectTab ?? (_) {},
        onVoiceTap: onVoiceTap ??
            () => _showDemoNotice(context, '长按语音键可演示待命/录音/识别中状态切换'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(DsSpacing.pageMargin),
        children: <Widget>[
          IncidentHeader(
            incidentName: PreviewFixtures.incident.name,
            category: PreviewFixtures.incident.category,
            elapsedText: PreviewFixtures.incident.elapsedText,
            highestRiskStatus: highestRisk,
            highestRiskLabel: '最高风险 · 超时',
            connectionState: PreviewFixtures.incident.connectionState,
            pendingSyncCount: PreviewFixtures.incident.pendingSyncCount,
            onTap: () => _openBriefSheet(context),
            onConnectionTap: () => _showDemoNotice(context, '当前同步链路在线（演示）'),
          ),
          const SizedBox(height: DsSpacing.cardGap),
          SurfaceCard(
            level: DsSurfaceLevel.outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      '现场态势总览',
                      style: typography.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    StatusPill(
                      status: DsStatus.neutral,
                      label: '参战力量 ${PreviewFixtures.incident.forceSummary}',
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.md),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: MetricReadout(
                        label: '在场内攻',
                        value: '${PreviewFixtures.personnel.length}',
                        unit: '人',
                      ),
                    ),
                    const SizedBox(width: DsSpacing.md),
                    Expanded(
                      child: MetricReadout(
                        label: '告警/超时',
                        value: '$urgentCount',
                        unit: '人',
                        status: DsStatus.alarm,
                        colorByStatus: true,
                      ),
                    ),
                    const SizedBox(width: DsSpacing.md),
                    Expanded(
                      child: MetricReadout(
                        label: '注意关注',
                        value: '${counts[DsStatus.caution] ?? 0}',
                        unit: '人',
                        status: DsStatus.caution,
                        colorByStatus: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.md),
                Wrap(
                  spacing: DsSpacing.xs,
                  runSpacing: DsSpacing.xs,
                  children: <Widget>[
                    StatusPill(
                      status: DsStatus.timeout,
                      label: '超时 ${counts[DsStatus.timeout] ?? 0}',
                    ),
                    StatusPill(
                      status: DsStatus.alarm,
                      label: '告警 ${counts[DsStatus.alarm] ?? 0}',
                    ),
                    StatusPill(
                      status: DsStatus.caution,
                      label: '注意 ${counts[DsStatus.caution] ?? 0}',
                    ),
                    StatusPill(
                      status: DsStatus.safe,
                      label: '安全 ${counts[DsStatus.safe] ?? 0}',
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.md),
                CommandButton(
                  label: '查看战术简报',
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.large,
                  expanded: true,
                  icon: Icons.description_outlined,
                  onPressed: () => _openBriefSheet(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.lg),
          Text(
            '现场工具',
            style: typography.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.sm),
          ToolGrid(items: tools),
          const SizedBox(height: DsSpacing.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '火场日志',
                  style: typography.title.copyWith(color: colors.textPrimary),
                ),
              ),
              CommandButton(
                label: '查看全部',
                variant: CommandButtonVariant.ghost,
                size: CommandButtonSize.standard,
                onPressed: () => _openAllTimelineSheet(context),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          TimelineList(entries: entries),
        ],
      ),
    );
  }
}
