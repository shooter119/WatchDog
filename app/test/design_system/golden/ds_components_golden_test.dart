import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';

Future<void> _pumpGoldenPanel(
  WidgetTester tester, {
  required Brightness brightness,
  required Size size,
  required GlobalKey captureKey,
  required Widget child,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(
          key: captureKey,
          child: child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _panelShell({
  required BuildContext context,
  required String title,
  required Widget child,
}) {
  final ds = context.ds;
  return Scaffold(
    backgroundColor: ds.colors.canvas,
    body: Padding(
      padding: const EdgeInsets.all(DsSpacing.pageMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: ds.typography.title.copyWith(color: ds.colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.md),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

void main() {
  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('CommandScaffold & SurfaceCard ($themeTag)',
        (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenPanel(
        tester,
        brightness: brightness,
        size: const Size(400, 560),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            final ds = context.ds;
            return CommandScaffold(
              useSafeArea: false,
              isOffline: true,
              topBar: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.pageMargin,
                  vertical: DsSpacing.sm,
                ),
                child: Text(
                  'CommandScaffold · $themeTag',
                  style: ds.typography.title.copyWith(
                    color: ds.colors.textPrimary,
                  ),
                ),
              ),
              body: Padding(
                padding: const EdgeInsets.all(DsSpacing.pageMargin),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SurfaceCard(
                      level: DsSurfaceLevel.flat,
                      child: Text(
                        'SurfaceCard · flat',
                        style: ds.typography.body.copyWith(
                          color: ds.colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: DsSpacing.sm),
                    SurfaceCard(
                      level: DsSurfaceLevel.outlined,
                      accentStatus: DsStatus.alarm,
                      child: Text(
                        'SurfaceCard · outlined + alarm',
                        style: ds.typography.body.copyWith(
                          color: ds.colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: DsSpacing.sm),
                    SurfaceCard(
                      level: DsSurfaceLevel.outlined,
                      accentStatus: DsStatus.caution,
                      child: Text(
                        'SurfaceCard · outlined + caution',
                        style: ds.typography.body.copyWith(
                          color: ds.colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: DsSpacing.sm),
                    SurfaceCard(
                      level: DsSurfaceLevel.raised,
                      child: Text(
                        'SurfaceCard · raised',
                        style: ds.typography.body.copyWith(
                          color: ds.colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_scaffold_card_$themeTag.png'),
      );
    });

    testWidgets('StatusPill, ConnectionPill & MetricReadout ($themeTag)',
        (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenPanel(
        tester,
        brightness: brightness,
        size: const Size(400, 620),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            return _panelShell(
              context: context,
              title: 'StatusPill · ConnectionPill · MetricReadout',
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Wrap(
                          spacing: DsSpacing.sm,
                          runSpacing: DsSpacing.sm,
                          children: <Widget>[
                            StatusPill(status: DsStatus.safe),
                            StatusPill(status: DsStatus.caution),
                            StatusPill(status: DsStatus.alarm),
                            StatusPill(status: DsStatus.timeout),
                            StatusPill(status: DsStatus.neutral),
                          ],
                        ),
                        SizedBox(height: DsSpacing.sm),
                        Wrap(
                          spacing: DsSpacing.sm,
                          runSpacing: DsSpacing.sm,
                          children: <Widget>[
                            StatusPill(status: DsStatus.safe, solid: true),
                            StatusPill(status: DsStatus.caution, solid: true),
                            StatusPill(status: DsStatus.alarm, solid: true),
                            StatusPill(status: DsStatus.timeout, solid: true),
                            StatusPill(status: DsStatus.neutral, solid: true),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: DsSpacing.md),
                  SurfaceCard(
                    child: Wrap(
                      spacing: DsSpacing.sm,
                      runSpacing: DsSpacing.sm,
                      children: <Widget>[
                        ConnectionPill(state: DsConnectionState.online),
                        ConnectionPill(state: DsConnectionState.reconnecting),
                        ConnectionPill(
                          state: DsConnectionState.offline,
                          pendingCount: 3,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: DsSpacing.md),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: MetricReadout(
                                label: '默认读数',
                                value: '28.5',
                                unit: 'MPa',
                              ),
                            ),
                            SizedBox(width: DsSpacing.md),
                            Expanded(
                              child: MetricReadout(
                                label: '注意状态',
                                value: '12:18',
                                status: DsStatus.caution,
                                colorByStatus: true,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: DsSpacing.md),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: MetricReadout(
                                label: '告警倒计时',
                                value: '18:42',
                                status: DsStatus.alarm,
                                colorByStatus: true,
                                large: true,
                              ),
                            ),
                            SizedBox(width: DsSpacing.md),
                            Expanded(
                              child: MetricReadout(
                                label: '已超时',
                                value: '01:24',
                                status: DsStatus.timeout,
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
                ],
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_metrics_pills_$themeTag.png'),
      );
    });

    testWidgets('CommandButton & CommandSheet ($themeTag)',
        (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenPanel(
        tester,
        brightness: brightness,
        size: const Size(400, 740),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            final ds = context.ds;
            return _panelShell(
              context: context,
              title: 'CommandButton & CommandSheet',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SurfaceCard(
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
                              onPressed: () {},
                            ),
                            CommandButton(
                              label: '次级操作',
                              variant: CommandButtonVariant.secondary,
                              onPressed: () {},
                            ),
                            CommandButton(
                              label: '轻量',
                              variant: CommandButtonVariant.ghost,
                              onPressed: () {},
                            ),
                            CommandButton(
                              label: '危险',
                              variant: CommandButtonVariant.danger,
                              requireConfirmation: false,
                              onPressed: () {},
                            ),
                            CommandButton(
                              label: '加载中',
                              isLoading: true,
                              onPressed: () {},
                            ),
                            const CommandButton(
                              label: '不可用',
                              enabled: false,
                              onPressed: null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: DsSpacing.md),
                  SizedBox(
                    height: 300,
                    child: CommandSheet(
                      title: '确认报压操作',
                      subtitle: '示例路站 · 张三',
                      actions: <Widget>[
                        CommandButton(
                          label: '取消',
                          variant: CommandButtonVariant.secondary,
                          size: CommandButtonSize.large,
                          onPressed: () {},
                        ),
                        CommandButton(
                          label: '确认',
                          variant: CommandButtonVariant.primary,
                          size: CommandButtonSize.large,
                          onPressed: () {},
                        ),
                      ],
                      child: Text(
                        '弹窗容器包含拖拽手柄、标题区、可滚动内容及底部双 56dp 行动栏。',
                        style: ds.typography.body.copyWith(
                          color: ds.colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_buttons_sheet_$themeTag.png'),
      );
    });

    testWidgets('StatePlaceholder 3 modes ($themeTag)',
        (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenPanel(
        tester,
        brightness: brightness,
        size: const Size(400, 840),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            return _panelShell(
              context: context,
              title: 'StatePlaceholder · 三态占位',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SurfaceCard(
                    child: StatePlaceholder.loading(message: '正在加载现场数据…'),
                  ),
                  const SizedBox(height: DsSpacing.md),
                  SurfaceCard(
                    child: StatePlaceholder.empty(
                      message: '暂无人员记录',
                      detail: '点击下方按钮或长按语音键录入首批人员。',
                      actionLabel: '登记进场',
                      onAction: () {},
                    ),
                  ),
                  const SizedBox(height: DsSpacing.md),
                  SurfaceCard(
                    child: StatePlaceholder.error(
                      reason: '前指网络暂时中断',
                      onRetry: () {},
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_placeholders_$themeTag.png'),
      );
    });

    testWidgets('ToolGrid & TimelineList ($themeTag)',
        (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenPanel(
        tester,
        brightness: brightness,
        size: const Size(400, 760),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            return _panelShell(
              context: context,
              title: 'ToolGrid & TimelineList',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ToolGrid(items: PreviewFixtures.buildHomeTools()),
                  const SizedBox(height: DsSpacing.md),
                  TimelineList(
                    entries: PreviewFixtures.buildTimelineEntries()
                        .take(3)
                        .toList(growable: false),
                  ),
                ],
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_tools_timeline_$themeTag.png'),
      );
    });

    testWidgets('IncidentHeader & CommandNavBar 3 states ($themeTag)',
        (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenPanel(
        tester,
        brightness: brightness,
        size: const Size(400, 660),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            return _panelShell(
              context: context,
              title: 'IncidentHeader & CommandNavBar',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const IncidentHeader(
                    incidentName: '示例县示例路仓库火灾',
                    category: DsIncidentCategory.fire,
                    elapsedText: '00:42:15',
                    highestRiskStatus: DsStatus.alarm,
                    connectionState: DsConnectionState.online,
                  ),
                  const SizedBox(height: DsSpacing.sm),
                  const IncidentHeader(
                    incidentName: '示例县南环抢险救援',
                    category: DsIncidentCategory.rescue,
                    elapsedText: '00:18:04',
                    highestRiskStatus: DsStatus.timeout,
                    connectionState: DsConnectionState.offline,
                    pendingSyncCount: 3,
                  ),
                  const SizedBox(height: DsSpacing.md),
                  CommandNavBar(
                    selectedIndex: 0,
                    voiceState: DsVoiceState.idle,
                    onSelectTab: (_) {},
                  ),
                  const SizedBox(height: DsSpacing.md),
                  CommandNavBar(
                    selectedIndex: 1,
                    voiceState: DsVoiceState.recording,
                    onSelectTab: (_) {},
                  ),
                  const SizedBox(height: DsSpacing.md),
                  CommandNavBar(
                    selectedIndex: 2,
                    voiceState: DsVoiceState.processing,
                    onSelectTab: (_) {},
                  ),
                ],
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_header_navbar_$themeTag.png'),
      );
    });
  }
}
