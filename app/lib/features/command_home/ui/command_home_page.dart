import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/tactical_brief_engine.dart';
import 'widgets/commander_brief_card.dart';
import 'widgets/field_tools_grid_section.dart';

/// 指挥台首页（新外壳 Tab 0，Design System v3.0）。
///
/// 采用纯插槽与回调组合架构，严禁跨 Feature 直接导入 `features/incident/`、
/// `features/notes/` 或 `features/monitor/`，由 `app/shell/command_home_assembly.dart`
/// 负责按依赖注入方式完成拼装。
class CommandHomePage extends StatelessWidget {
  const CommandHomePage({
    super.key = const Key('command-home-page'),
    required this.hasIncident,
    required this.tools,
    this.headerTitle = '指挥台',
    this.incidentCardSlot,
    this.onChooseIncident,
    this.glanceCardSlot,
    this.airSafetySummary,
    this.tacticalProgress,
    this.hasCriticalHazards = false,
    this.onOpenMonitor,
    this.notesPreviewSlot,
    this.connectionState = DsConnectionState.online,
    this.pendingSyncCount = 0,
    this.isOffline = false,
    this.offlineMessage = '当前处于离线状态，操作将暂存本地并在联网后自动同步',
    this.onConnectionTap,
    this.onRefresh,
    this.voiceGuidanceText = '长按底部语音键说话，松开自动识别进出场、日志或提问',
    this.bottomClearance = 0.0,
  });

  final bool hasIncident;
  final List<FieldToolSpec> tools;
  final String headerTitle;
  final Widget? incidentCardSlot;
  final VoidCallback? onChooseIncident;
  final Widget? glanceCardSlot;
  final AirSafetySummary? airSafetySummary;
  final String? tacticalProgress;
  final bool hasCriticalHazards;
  final VoidCallback? onOpenMonitor;
  final Widget? notesPreviewSlot;
  final DsConnectionState connectionState;
  final int pendingSyncCount;
  final bool isOffline;
  final String offlineMessage;
  final VoidCallback? onConnectionTap;
  final Future<void> Function()? onRefresh;
  final String? voiceGuidanceText;
  final double bottomClearance;

  @override
  Widget build(BuildContext context) {
    final Widget? resolvedGlance =
        glanceCardSlot ??
        ((airSafetySummary != null && airSafetySummary!.hasActive)
            ? CommanderBriefCard(
                key: const Key('command-glance-card'),
                summary: airSafetySummary!,
                tacticalProgress: tacticalProgress,
                hasCriticalHazards: hasCriticalHazards,
                onTap: onOpenMonitor,
              )
            : null);

    Widget scrollBody = ListView(
      key: const Key('command-home-scroll'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.sm,
        DsSpacing.pageMargin,
        DsSpacing.xl + bottomClearance,
      ),
      children: <Widget>[
        _CommandHeaderBar(
          title: headerTitle,
          connectionState: connectionState,
          pendingSyncCount: pendingSyncCount,
          onConnectionTap: onConnectionTap,
        ),
        const SizedBox(height: DsSpacing.md),
        if (hasIncident && incidentCardSlot != null)
          KeyedSubtree(
            key: const Key('command-incident-card'),
            child: incidentCardSlot!,
          )
        else
          _NoIncidentGuidanceCard(
            key: const Key('command-no-incident-card'),
            onChooseIncident: onChooseIncident,
          ),
        if (resolvedGlance != null) ...<Widget>[
          const SizedBox(height: DsSpacing.cardGap),
          resolvedGlance,
        ],
        const SizedBox(height: DsSpacing.lg),
        FieldToolsGridSection(
          key: const Key('command-tools-grid'),
          tools: tools,
        ),
        if (notesPreviewSlot != null) ...<Widget>[
          const SizedBox(height: DsSpacing.lg),
          notesPreviewSlot!,
        ],
        if (voiceGuidanceText != null &&
            voiceGuidanceText!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: DsSpacing.md),
          _VoiceGuidanceStrip(text: voiceGuidanceText!),
        ],
      ],
    );

    if (onRefresh != null) {
      scrollBody = RefreshIndicator(
        onRefresh: onRefresh!,
        child: scrollBody,
      );
    }

    return CommandScaffold(
      isOffline: isOffline,
      offlineMessage: offlineMessage,
      onOfflineTap: onConnectionTap,
      body: scrollBody,
    );
  }
}

class _CommandHeaderBar extends StatelessWidget {
  const _CommandHeaderBar({
    required this.title,
    required this.connectionState,
    required this.pendingSyncCount,
    this.onConnectionTap,
  });

  final String title;
  final DsConnectionState connectionState;
  final int pendingSyncCount;
  final VoidCallback? onConnectionTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxPillWidth = constraints.hasBoundedWidth
            ? math.max(0.0, constraints.maxWidth * 0.62)
            : double.infinity;
        final titleWidget = Text(
          title,
          key: const Key('command-header-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: typo.display.copyWith(
            fontSize: 22,
            height: 1.25,
            color: colors.textPrimary,
          ),
        );
        final pill = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxPillWidth),
          child: ConnectionPill(
            state: connectionState,
            pendingCount: pendingSyncCount,
            onTap: onConnectionTap,
          ),
        );
        return Row(
          key: const Key('command-header-bar'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: titleWidget),
            const SizedBox(width: DsSpacing.sm),
            pill,
          ],
        );
      },
    );
  }
}

class _NoIncidentGuidanceCard extends StatelessWidget {
  const _NoIncidentGuidanceCard({super.key, this.onChooseIncident});

  final VoidCallback? onChooseIncident;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final alarmPair = colors.statusColors(DsStatus.alarm);

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: alarmPair.pillBg,
                  borderRadius: DsRadius.borderMd,
                ),
                child: Icon(
                  DsIcons.categoryFireLine,
                  size: DsSizes.iconLg,
                  color: alarmPair.text,
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '暂无正在处置的警情',
                      style: typo.title.copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '选择或新建警情后可启用空呼监控与火场日志',
                      style: typo.caption.copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.md),
          CommandButton(
            key: const Key('choose-incident-from-home'),
            label: '选择或新建警情',
            icon: DsIcons.addCircle,
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            expanded: true,
            enabled: onChooseIncident != null,
            onPressed: onChooseIncident,
          ),
        ],
      ),
    );
  }
}

class _VoiceGuidanceStrip extends StatelessWidget {
  const _VoiceGuidanceStrip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      level: DsSurfaceLevel.flat,
      borderRadius: DsRadius.borderMd,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            DsIcons.voiceLine,
            size: DsSizes.iconSm,
            color: colors.textSecondary,
          ),
          const SizedBox(width: DsSpacing.sm),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
