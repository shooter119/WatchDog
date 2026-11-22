import 'package:flutter/material.dart';

import '../components/command_button.dart';
import '../components/command_nav_bar.dart';
import '../components/command_scaffold.dart';
import '../components/command_sheet.dart';
import '../components/connection_pill.dart';
import '../components/incident_header.dart';
import '../components/metric_readout.dart';
import '../components/state_placeholder.dart';
import '../components/status_pill.dart';
import '../components/surface_card.dart';
import '../components/timeline_list.dart';
import '../components/tool_grid.dart';
import '../theme/build_command_theme.dart';
import '../theme/ds_theme.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_icons.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_spacing.dart';
import 'command_home_preview.dart';
import 'monitor_preview.dart';
import 'preview_fixtures.dart';

/// 预览页子视图枚举。
enum DsPreviewView {
  overview,
  commandHome,
  monitor,
}

/// Design System v3.0 调试预览页（昼白 / 暗曜、100% / 130% 字号、语音三态与双核心原型）。
class DsPreviewPage extends StatefulWidget {
  const DsPreviewPage({
    super.key,
    this.initialBrightness = Brightness.light,
    this.initialTextScale = 1.0,
    this.initialVoiceState = DsVoiceState.idle,
    this.initialView = DsPreviewView.overview,
    this.liveTick = true,
  });

  final Brightness initialBrightness;
  final double initialTextScale;
  final DsVoiceState initialVoiceState;
  final DsPreviewView initialView;
  final bool liveTick;

  @override
  State<DsPreviewPage> createState() => _DsPreviewPageState();
}

class _DsPreviewPageState extends State<DsPreviewPage> {
  late Brightness _brightness;
  late double _textScale;
  late DsVoiceState _voiceState;
  late DsPreviewView _activeView;

  @override
  void initState() {
    super.initState();
    _brightness = widget.initialBrightness;
    _textScale = widget.initialTextScale;
    _voiceState = widget.initialVoiceState;
    _activeView = widget.initialView;
  }

  void _cycleVoiceState() {
    setState(() {
      _voiceState = switch (_voiceState) {
        DsVoiceState.idle => DsVoiceState.recording,
        DsVoiceState.recording => DsVoiceState.processing,
        DsVoiceState.processing => DsVoiceState.idle,
      };
    });
  }

  void _handleNavTab(BuildContext dsContext, int index) {
    if (index == 0) {
      setState(() => _activeView = DsPreviewView.commandHome);
      return;
    }
    if (index == 1) {
      setState(() => _activeView = DsPreviewView.monitor);
      return;
    }
    final label = CommandNavBar.defaultTabs[index].label;
    _showDemoSnackBar(dsContext, '「$label」页面将在后续里程碑重构，当前仅预览核心双页');
  }

  void _showDemoSnackBar(BuildContext context, String message) {
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

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildCommandTheme(_brightness),
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(_textScale),
        ),
        child: Builder(
          builder: (BuildContext dsContext) {
            final ds = dsContext.ds;
            return Scaffold(
              backgroundColor: ds.colors.canvas,
              appBar: AppBar(
                title: const FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('Design System v3.0 预览'),
                ),
              ),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildControlBar(dsContext),
                  Expanded(
                    child: _buildActiveView(dsContext),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildControlBar(BuildContext dsContext) {
    final ds = dsContext.ds;
    final colors = ds.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.pageMargin,
        vertical: DsSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Wrap(
            spacing: DsSpacing.xs,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              _PreviewChip(
                label: '组件总览',
                selected: _activeView == DsPreviewView.overview,
                onTap: () =>
                    setState(() => _activeView = DsPreviewView.overview),
              ),
              _PreviewChip(
                label: '指挥台原型',
                selected: _activeView == DsPreviewView.commandHome,
                onTap: () =>
                    setState(() => _activeView = DsPreviewView.commandHome),
              ),
              _PreviewChip(
                label: '安全管控原型',
                selected: _activeView == DsPreviewView.monitor,
                onTap: () =>
                    setState(() => _activeView = DsPreviewView.monitor),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xs),
          Wrap(
            spacing: DsSpacing.xs,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              _PreviewChip(
                label: '昼白',
                selected: _brightness == Brightness.light,
                onTap: () => setState(() => _brightness = Brightness.light),
              ),
              _PreviewChip(
                label: '暗曜',
                selected: _brightness == Brightness.dark,
                onTap: () => setState(() => _brightness = Brightness.dark),
              ),
              _PreviewChip(
                label: '100%',
                selected: (_textScale - 1.0).abs() < 0.01,
                onTap: () => setState(() => _textScale = 1.0),
              ),
              _PreviewChip(
                label: '130%',
                selected: (_textScale - 1.3).abs() < 0.01,
                onTap: () => setState(() => _textScale = 1.3),
              ),
              _PreviewChip(
                label: '待命',
                selected: _voiceState == DsVoiceState.idle,
                onTap: () => setState(() => _voiceState = DsVoiceState.idle),
              ),
              _PreviewChip(
                label: '录音',
                selected: _voiceState == DsVoiceState.recording,
                onTap: () =>
                    setState(() => _voiceState = DsVoiceState.recording),
              ),
              _PreviewChip(
                label: '识别中',
                selected: _voiceState == DsVoiceState.processing,
                onTap: () =>
                    setState(() => _voiceState = DsVoiceState.processing),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActiveView(BuildContext dsContext) {
    return switch (_activeView) {
      DsPreviewView.overview => _buildOverview(dsContext),
      DsPreviewView.commandHome => CommandHomePreview(
          voiceState: _voiceState,
          onSelectTab: (index) => _handleNavTab(dsContext, index),
          onVoiceTap: _cycleVoiceState,
        ),
      DsPreviewView.monitor => MonitorPreview(
          voiceState: _voiceState,
          onSelectTab: (index) => _handleNavTab(dsContext, index),
          onVoiceTap: _cycleVoiceState,
          liveTick: widget.liveTick,
        ),
    };
  }

  Widget _buildOverview(BuildContext dsContext) {
    final ds = dsContext.ds;
    final colors = ds.colors;
    final typography = ds.typography;

    return ListView(
      padding: const EdgeInsets.all(DsSpacing.pageMargin),
      children: <Widget>[
        _sectionTitle(dsContext, '1. 警情头栏与同步状态 (IncidentHeader & ConnectionPill)'),
        IncidentHeader(
          incidentName: PreviewFixtures.incident.name,
          category: PreviewFixtures.incident.category,
          elapsedText: PreviewFixtures.incident.elapsedText,
          highestRiskStatus: DsStatus.alarm,
          connectionState: DsConnectionState.offline,
          pendingSyncCount: 3,
        ),
        const SizedBox(height: DsSpacing.sm),
        Wrap(
          spacing: DsSpacing.sm,
          runSpacing: DsSpacing.xs,
          children: const <Widget>[
            ConnectionPill(state: DsConnectionState.online),
            ConnectionPill(state: DsConnectionState.reconnecting),
            ConnectionPill(state: DsConnectionState.offline, pendingCount: 3),
          ],
        ),
        const SizedBox(height: DsSpacing.lg),
        _sectionTitle(dsContext, '2. 状态胶囊与等宽数值 (StatusPill & MetricReadout)'),
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: DsSpacing.xs,
                runSpacing: DsSpacing.xs,
                children: const <Widget>[
                  StatusPill(status: DsStatus.safe),
                  StatusPill(status: DsStatus.caution),
                  StatusPill(status: DsStatus.alarm),
                  StatusPill(status: DsStatus.timeout),
                  StatusPill(status: DsStatus.neutral),
                  StatusPill(status: DsStatus.alarm, solid: true, label: '告警实心'),
                  StatusPill(
                    status: DsStatus.timeout,
                    solid: true,
                    label: '超时实心',
                  ),
                ],
              ),
              const SizedBox(height: DsSpacing.md),
              const Row(
                children: <Widget>[
                  Expanded(
                    child: MetricReadout(
                      label: '当前气瓶压力',
                      value: '28.5',
                      unit: 'MPa',
                    ),
                  ),
                  SizedBox(width: DsSpacing.md),
                  Expanded(
                    child: MetricReadout(
                      label: '预计可用时间',
                      value: '18:42',
                      status: DsStatus.alarm,
                      colorByStatus: true,
                      large: true,
                      crossAxisAlignment: CrossAxisAlignment.end,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        _sectionTitle(dsContext, '3. 分层卡片 (SurfaceCard)'),
        const SurfaceCard(
          level: DsSurfaceLevel.flat,
          child: Text('flat · 扁平辅助卡片（无描边无阴影）'),
        ),
        const SizedBox(height: DsSpacing.sm),
        const SurfaceCard(
          level: DsSurfaceLevel.outlined,
          accentStatus: DsStatus.caution,
          child: Text('outlined + accentStatus · 1px 描边 + 左侧状态条'),
        ),
        const SizedBox(height: DsSpacing.sm),
        const SurfaceCard(
          level: DsSurfaceLevel.raised,
          child: Text('raised · 轻浮层卡片（昼白微阴影 / 暗曜纯描边）'),
        ),
        const SizedBox(height: DsSpacing.lg),
        _sectionTitle(dsContext, '4. 行动按钮与底部弹窗 (CommandButton & CommandSheet)'),
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Wrap(
                spacing: DsSpacing.sm,
                runSpacing: DsSpacing.sm,
                children: <Widget>[
                  CommandButton(
                    label: '主操作',
                    variant: CommandButtonVariant.primary,
                    size: CommandButtonSize.large,
                    onPressed: () =>
                        _showDemoSnackBar(dsContext, '点击了主操作按钮（56dp）'),
                  ),
                  CommandButton(
                    label: '次级操作',
                    variant: CommandButtonVariant.secondary,
                    size: CommandButtonSize.standard,
                    onPressed: () =>
                        _showDemoSnackBar(dsContext, '点击了次级按钮（48dp）'),
                  ),
                  CommandButton(
                    label: '轻量操作',
                    variant: CommandButtonVariant.ghost,
                    size: CommandButtonSize.standard,
                    onPressed: () =>
                        _showDemoSnackBar(dsContext, '点击了轻量按钮（48dp）'),
                  ),
                  CommandButton(
                    label: '加载中',
                    variant: CommandButtonVariant.primary,
                    isLoading: true,
                    onPressed: () {},
                  ),
                  const CommandButton(
                    label: '不可用',
                    variant: CommandButtonVariant.secondary,
                    enabled: false,
                    onPressed: null,
                  ),
                ],
              ),
              const SizedBox(height: DsSpacing.md),
              CommandButton(
                label: '打开 CommandSheet 弹窗演示',
                variant: CommandButtonVariant.secondary,
                size: CommandButtonSize.large,
                expanded: true,
                icon: DsIcons.list,
                onPressed: () => showCommandSheet<void>(
                  context: dsContext,
                  title: 'CommandSheet 弹窗',
                  subtitle: '自动继承当前昼白/暗曜主题与 100%/130% 字号',
                  builder: (BuildContext sheetContext) {
                    final sheetDs = sheetContext.ds;
                    return Text(
                      '这是 Design System v3.0 标准底部弹窗容器，顶部固定标题区与底部固定操作栏在窄屏与大字号下均保持完整可读。',
                      style: sheetDs.typography.body.copyWith(
                        color: sheetDs.colors.textPrimary,
                      ),
                    );
                  },
                  actionsBuilder: (BuildContext sheetContext) => <Widget>[
                    CommandButton(
                      label: '关闭',
                      variant: CommandButtonVariant.primary,
                      size: CommandButtonSize.large,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: DsSpacing.sm),
              CommandButton(
                label: '危险操作二次确认（全员撤离演示）',
                variant: CommandButtonVariant.danger,
                size: CommandButtonSize.large,
                expanded: true,
                confirmTitle: '确认执行危险演示操作？',
                confirmMessage: '危险按钮默认拉起 CommandSheet 二次确认，防止误触。',
                confirmActionLabel: '确认继续',
                onPressed: () => _showDemoSnackBar(dsContext, '已完成危险确认演示'),
              ),
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        _sectionTitle(dsContext, '5. 状态占位 (StatePlaceholder)'),
        const SurfaceCard(
          level: DsSurfaceLevel.outlined,
          child: StatePlaceholder.loading(message: '正在同步现场数据…'),
        ),
        const SizedBox(height: DsSpacing.sm),
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          child: StatePlaceholder.empty(
            message: '暂无内攻人员',
            detail: '点击下方按钮或长按语音键快速登记进场。',
            actionLabel: '演示操作',
            onAction: () => _showDemoSnackBar(dsContext, '触发空态引导操作'),
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          child: StatePlaceholder.error(
            reason: '与前方中继服务器连接中断',
            onRetry: () => _showDemoSnackBar(dsContext, '已触发错误态重试'),
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        _sectionTitle(dsContext, '6. 现场工具网格与火场时间线 (ToolGrid & TimelineList)'),
        ToolGrid(
          items: PreviewFixtures.buildHomeTools(
            onToolTap: (item) =>
                _showDemoSnackBar(dsContext, '工具格演示：${item.label}'),
          ),
        ),
        const SizedBox(height: DsSpacing.md),
        TimelineList(
          entries: PreviewFixtures.buildTimelineEntries(
            onEntryTap: (title) => _showDemoSnackBar(dsContext, title),
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        _sectionTitle(dsContext, '7. 离线骨架屏与语音导航栏 (CommandScaffold & CommandNavBar)'),
        SizedBox(
          height: 220,
          child: ClipRRect(
            borderRadius: DsRadius.borderLg,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: colors.border),
                borderRadius: DsRadius.borderLg,
              ),
              child: CommandScaffold(
                useSafeArea: false,
                isOffline: true,
                topBar: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.md,
                    vertical: DsSpacing.sm,
                  ),
                  child: Text(
                    'CommandScaffold · 离线高对比横幅预览',
                    style: typography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                body: Center(
                  child: Text(
                    '页面主体区域',
                    style: typography.body.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                bottomNavigationBar: CommandNavBar(
                  selectedIndex: 0,
                  voiceState: _voiceState,
                  onSelectTab: (index) => _handleNavTab(dsContext, index),
                  onVoiceTap: _cycleVoiceState,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext dsContext, String text) {
    final ds = dsContext.ds;
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.sm),
      child: Text(
        text,
        style: ds.typography.title.copyWith(color: ds.colors.textPrimary),
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({
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
    return Material(
      color: selected ? colors.brand : colors.surfaceMuted,
      borderRadius: DsRadius.borderPill,
      child: InkWell(
        onTap: onTap,
        borderRadius: DsRadius.borderPill,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.md,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            borderRadius: DsRadius.borderPill,
            border: Border.all(
              color: selected ? colors.brand : colors.border,
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
    );
  }
}
