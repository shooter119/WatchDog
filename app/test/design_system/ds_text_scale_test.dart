import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/settings/ui/component_gallery_page.dart';

void _setNarrowViewport(
  WidgetTester tester, {
  Size size = const Size(360, 800),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _withCapturedErrors(
  Future<void> Function(List<FlutterErrorDetails> errors) body,
) async {
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    errors.add(details);
  };
  try {
    await body(errors);
  } finally {
    FlutterError.onError = previousOnError;
  }
}

void _expectNoOverflowOrTruncation(
  WidgetTester tester,
  List<FlutterErrorDetails> errors, {
  double maxWidth = 360.0,
}) {
  expect(tester.takeException(), isNull);
  expect(
    errors,
    isEmpty,
    reason: errors.map((e) => e.exceptionAsString()).join('\n'),
  );

  for (final element in find.byType(RichText).evaluate()) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderParagraph || !renderObject.attached) {
      continue;
    }
    expect(
      renderObject.didExceedMaxLines,
      isFalse,
      reason: '文本发生截断: ${renderObject.text.toPlainText()}',
    );
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final bottomRight = renderObject.localToGlobal(
      Offset(renderObject.size.width, renderObject.size.height),
    );
    expect(
      topLeft.dx,
      greaterThanOrEqualTo(-0.5),
      reason: '文本越出左边界: ${renderObject.text.toPlainText()}',
    );
    expect(
      bottomRight.dx,
      lessThanOrEqualTo(maxWidth + 0.5),
      reason: '文本越出 ${maxWidth}dp 右边界: ${renderObject.text.toPlainText()}',
    );
  }
}

Widget _wrapScaledDs({
  required Widget child,
  Brightness brightness = Brightness.light,
  double textScale = 1.3,
  bool disableAnimations = true,
  Size surfaceSize = const Size(360, 800),
}) {
  return MediaQuery(
    data: MediaQueryData(
      size: surfaceSize,
      devicePixelRatio: 1.0,
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
    ),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildCommandTheme(brightness),
      themeAnimationDuration: Duration.zero,
      home: child,
    ),
  );
}

void main() {
  group('360dp + 130% 字号缩放零溢出与零截断验证', () {
    testWidgets('1. CommandScaffold 离线横幅与上下槽位在昼白/暗曜下无溢出',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            _wrapScaledDs(
              brightness: brightness,
              child: CommandScaffold(
                isOffline: true,
                offlineMessage:
                    '当前处于离线状态，已记录的现场操作与空呼报压将在恢复联网后自动同步至前指服务器',
                onOfflineTap: () {},
                topBar: const Padding(
                  padding: EdgeInsets.all(DsSpacing.md),
                  child: Text('顶部状态栏'),
                ),
                body: ListView(
                  padding: const EdgeInsets.all(DsSpacing.pageMargin),
                  children: const <Widget>[
                    Text('主体列表内容区域，用于检验 360dp 窄屏与 130% 放大字号下整体安全边距。'),
                  ],
                ),
                bottomNavigationBar: CommandNavBar(
                  selectedIndex: 0,
                  onSelectTab: (_) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          _expectNoOverflowOrTruncation(tester, errors);
        }
      });
    });

    testWidgets('2. SurfaceCard 三级平面与左侧风险条在 360dp + 130% 下无溢出',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: CommandScaffold(
              body: ListView(
                padding: const EdgeInsets.all(DsSpacing.pageMargin),
                children: <Widget>[
                  const SurfaceCard(
                    level: DsSurfaceLevel.flat,
                    child: Text('flat 平面卡片正文'),
                  ),
                  const SizedBox(height: DsSpacing.sm),
                  SurfaceCard(
                    level: DsSurfaceLevel.outlined,
                    accentStatus: DsStatus.alarm,
                    onTap: () {},
                    child: const Text('outlined 带告警左侧色条与点击反馈卡片'),
                  ),
                  const SizedBox(height: DsSpacing.sm),
                  const SurfaceCard(
                    level: DsSurfaceLevel.raised,
                    child: Text('raised 浮层卡片'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
      });
    });

    testWidgets('3. MetricReadout 两列并排在 360dp + 130% 下无溢出不截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: const CommandScaffold(
              body: Padding(
                padding: EdgeInsets.all(DsSpacing.pageMargin),
                child: SurfaceCard(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: MetricReadout(
                          label: '当前气瓶压力',
                          value: '28.5',
                          unit: 'MPa',
                          status: DsStatus.safe,
                        ),
                      ),
                      SizedBox(width: DsSpacing.md),
                      Expanded(
                        child: MetricReadout(
                          label: '预计剩余可用时间',
                          value: '18:42',
                          unit: 'min',
                          status: DsStatus.alarm,
                          colorByStatus: true,
                          large: true,
                          crossAxisAlignment: CrossAxisAlignment.end,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
      });
    });

    testWidgets('4. StatusPill 五态 × 描边/实心均含图标与文字且不截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: CommandScaffold(
              body: Padding(
                padding: const EdgeInsets.all(DsSpacing.pageMargin),
                child: Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.sm,
                  children: <Widget>[
                    for (final status in DsStatus.values) ...<Widget>[
                      StatusPill(status: status),
                      StatusPill(status: status, solid: true),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);

        final pills = find.byType(StatusPill);
        expect(pills, findsNWidgets(DsStatus.values.length * 2));
        for (var i = 0; i < DsStatus.values.length * 2; i++) {
          final pill = pills.at(i);
          expect(
            find.descendant(of: pill, matching: find.byType(Icon)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: pill, matching: find.byType(Text)),
            findsOneWidget,
          );
        }
      });
    });

    testWidgets('5. CommandButton 全变体与并排 56dp 主按钮对无溢出不重叠',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: CommandScaffold(
              body: ListView(
                padding: const EdgeInsets.all(DsSpacing.pageMargin),
                children: <Widget>[
                  Wrap(
                    spacing: DsSpacing.sm,
                    runSpacing: DsSpacing.sm,
                    children: <Widget>[
                      for (final variant in CommandButtonVariant.values)
                        for (final size in CommandButtonSize.values)
                          CommandButton(
                            label: '${variant.name}-${size.name}',
                            variant: variant,
                            size: size,
                            requireConfirmation: false,
                            onPressed: () {},
                          ),
                      CommandButton(
                        label: '加载中',
                        isLoading: true,
                        onPressed: () {},
                      ),
                      const CommandButton(
                        label: '已禁用',
                        enabled: false,
                        onPressed: null,
                      ),
                    ],
                  ),
                  const SizedBox(height: DsSpacing.md),
                  SurfaceCard(
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: CommandButton(
                            key: const Key('pair-report'),
                            label: '报压',
                            variant: CommandButtonVariant.secondary,
                            size: CommandButtonSize.large,
                            icon: Icons.speed_rounded,
                            onPressed: () {},
                          ),
                        ),
                        const SizedBox(width: DsSpacing.md),
                        Expanded(
                          child: CommandButton(
                            key: const Key('pair-exit'),
                            label: '出场',
                            variant: CommandButtonVariant.primary,
                            size: CommandButtonSize.large,
                            icon: Icons.logout_rounded,
                            onPressed: () {},
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);

        await tester.scrollUntilVisible(
          find.byKey(const Key('pair-report')),
          200,
        );
        final reportRect = tester.getRect(find.byKey(const Key('pair-report')));
        final exitRect = tester.getRect(find.byKey(const Key('pair-exit')));
        expect(reportRect.height, greaterThanOrEqualTo(56.0));
        expect(exitRect.height, greaterThanOrEqualTo(56.0));
        expect(reportRect.right, lessThanOrEqualTo(exitRect.left));
      });
    });

    testWidgets('6. StatePlaceholder 加载/空/错误三态在 360dp + 130% 下无溢出',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            disableAnimations: true,
            child: CommandScaffold(
              body: ListView(
                padding: const EdgeInsets.all(DsSpacing.pageMargin),
                children: <Widget>[
                  const StatePlaceholder.loading(message: '正在同步现场内攻数据…'),
                  StatePlaceholder.empty(
                    message: '暂无人员进场记录',
                    detail: '可通过底部语音键或快捷按钮登记首批进场人员。',
                    actionLabel: '登记进场',
                    onAction: () {},
                  ),
                  StatePlaceholder.error(
                    reason: '前指网络暂时不可用，请检查中继状态后重试',
                    onRetry: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
      });
    });

    testWidgets('7. CommandSheet 弹窗在 360dp + 130% 下保留主题与字号缩放且不截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            brightness: Brightness.dark,
            child: Builder(
              builder: (BuildContext context) {
                return CommandScaffold(
                  body: Center(
                    child: CommandButton(
                      label: '全员撤离',
                      variant: CommandButtonVariant.danger,
                      size: CommandButtonSize.large,
                      confirmTitle: '确认下达全员撤离指令？',
                      confirmMessage: '当前在场 6 名内攻人员将立即收到撤离信号。',
                      onPressed: () {},
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('全员撤离'));
        await tester.pumpAndSettle();

        final sheetFinder = find.byType(CommandSheet);
        expect(sheetFinder, findsOneWidget);
        final sheetContext = tester.element(sheetFinder);
        expect(sheetContext.ds.brightness, Brightness.dark);
        expect(
          MediaQuery.textScalerOf(sheetContext).scale(10),
          closeTo(13.0, 0.01),
        );
        _expectNoOverflowOrTruncation(tester, errors);
      });
    });

    testWidgets('8. ToolGrid 8 项工具在 360dp + 130% 下不溢出不截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: CommandScaffold(
              body: Padding(
                padding: const EdgeInsets.all(DsSpacing.pageMargin),
                child: ToolGrid(items: PreviewFixtures.buildHomeTools()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
        expect(find.text('位置共享'), findsOneWidget);
      });
    });

    testWidgets('9. TimelineList 同分钟合并与多状态日志在 360dp + 130% 下不溢出不截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: CommandScaffold(
              body: ListView(
                padding: const EdgeInsets.all(DsSpacing.pageMargin),
                children: <Widget>[
                  TimelineList(entries: PreviewFixtures.buildTimelineEntries()),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
        expect(find.text('14:22'), findsOneWidget);
      });
    });

    testWidgets('10. CommandNavBar 三态语音键与四栏导航在 360dp + 130% 下无重叠截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        for (final state in DsVoiceState.values) {
          final disableAnimations = state != DsVoiceState.recording;
          await tester.pumpWidget(
            _wrapScaledDs(
              disableAnimations: disableAnimations,
              child: CommandScaffold(
                body: const SizedBox.shrink(),
                bottomNavigationBar: CommandNavBar(
                  selectedIndex: 0,
                  voiceState: state,
                  tabs: const <CommandNavTab>[
                    CommandNavTab(
                      label: '指挥台',
                      icon: Icons.dashboard_outlined,
                      badgeCount: 3,
                    ),
                    CommandNavTab(
                      label: '安全管控',
                      icon: Icons.monitor_heart_outlined,
                      hasAlert: true,
                    ),
                    CommandNavTab(
                      label: '智能辅助',
                      icon: Icons.psychology_outlined,
                    ),
                    CommandNavTab(
                      label: '我的',
                      icon: Icons.person_outline,
                    ),
                  ],
                  onSelectTab: (_) {},
                ),
              ),
            ),
          );
          if (disableAnimations) {
            await tester.pumpAndSettle();
          } else {
            await tester.pump(const Duration(milliseconds: 200));
          }
          _expectNoOverflowOrTruncation(tester, errors);

          final voiceRect = tester.getRect(
            find.byKey(const Key('ds-nav-voice-button')),
          );
          expect(voiceRect.left, greaterThanOrEqualTo(0));
          expect(voiceRect.right, lessThanOrEqualTo(360));
        }
      });
    });

    testWidgets('11. IncidentHeader 长标题与离线待补传在 360dp + 130% 下不截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: const CommandScaffold(
              body: Padding(
                padding: EdgeInsets.all(DsSpacing.pageMargin),
                child: IncidentHeader(
                  incidentName: '示例县示例路大型仓储物流园火灾扑救',
                  category: DsIncidentCategory.fire,
                  elapsedText: '00:42:15',
                  highestRiskStatus: DsStatus.alarm,
                  connectionState: DsConnectionState.offline,
                  pendingSyncCount: 12,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
      });
    });

    testWidgets('12. ConnectionPill 三态在 360dp + 130% 下无溢出不截断',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          _wrapScaledDs(
            child: const CommandScaffold(
              body: Padding(
                padding: EdgeInsets.all(DsSpacing.pageMargin),
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
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
      });
    });

    testWidgets('13. CommandHomePreview 双主题在 360dp + 130% 下无溢出且战术简报弹窗可用',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            _wrapScaledDs(
              brightness: brightness,
              child: const CommandHomePreview(),
            ),
          );
          await tester.pumpAndSettle();
          _expectNoOverflowOrTruncation(tester, errors);
          expect(find.text('现场态势总览'), findsOneWidget);
          expect(find.text('查看战术简报'), findsOneWidget);
        }

        await tester.tap(find.text('查看战术简报'));
        await tester.pumpAndSettle();
        expect(find.text('现场战术简报'), findsOneWidget);
        _expectNoOverflowOrTruncation(tester, errors);

        await tester.tap(find.text('关闭简报'));
        await tester.pumpAndSettle();
        expect(find.text('现场战术简报'), findsNothing);
      });
    });

    testWidgets('14. MonitorPreview 双主题静态与实时 1s 倒计时及撤离确认无溢出',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            _wrapScaledDs(
              brightness: brightness,
              child: const MonitorPreview(liveTick: false),
            ),
          );
          await tester.pumpAndSettle();
          _expectNoOverflowOrTruncation(tester, errors);
          expect(find.text('在场 6 人 · 风险分布'), findsOneWidget);
        }

        final evacuateBtn = find.text('全员撤离');
        await tester.scrollUntilVisible(
          evacuateBtn,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(evacuateBtn);
        await tester.pumpAndSettle();
        expect(find.text('确认下达全员撤离指令？'), findsOneWidget);
        _expectNoOverflowOrTruncation(tester, errors);

        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();

        // 重置滚动位置后再验证 liveTick: true 每秒递减一次且销毁时不遗留挂起 Timer。
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          _wrapScaledDs(
            child: const MonitorPreview(
              key: Key('live-monitor'),
              liveTick: true,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('04:05'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('04:04'), findsOneWidget);
        _expectNoOverflowOrTruncation(tester, errors);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    });

    testWidgets('15. DsPreviewPage 挂入旧版 MaterialApp 后切换视图/主题/130%字号/语音态及弹窗无异常',
        (WidgetTester tester) async {
      _setNarrowViewport(tester);
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              devicePixelRatio: 1.0,
              disableAnimations: true,
            ),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildCommandTheme(Brightness.light),
              home: const DsPreviewPage(liveTick: false),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);

        // 切换至 130% 字号 + 暗曜主题 + 录音中状态
        await tester.tap(find.text('130%'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('暗曜'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('录音'));
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);

        // 在暗曜 + 130% 下打开 CommandSheet 验证主题与字号透传
        final sheetTrigger = find.text('打开 CommandSheet 弹窗演示');
        await tester.scrollUntilVisible(
          sheetTrigger,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(sheetTrigger);
        await tester.pumpAndSettle();

        final sheetFinder = find.byType(CommandSheet);
        expect(sheetFinder, findsOneWidget);
        final sheetContext = tester.element(sheetFinder);
        expect(sheetContext.ds.brightness, Brightness.dark);
        expect(
          MediaQuery.textScalerOf(sheetContext).scale(10),
          closeTo(13.0, 0.01),
        );
        _expectNoOverflowOrTruncation(tester, errors);

        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();

        // 切换至指挥台原型与安全管控原型
        await tester.tap(find.text('指挥台原型'));
        await tester.pumpAndSettle();
        expect(find.byType(CommandHomePreview), findsOneWidget);
        _expectNoOverflowOrTruncation(tester, errors);

        await tester.tap(find.text('安全管控原型'));
        await tester.pumpAndSettle();
        expect(find.byType(MonitorPreview), findsOneWidget);
        _expectNoOverflowOrTruncation(tester, errors);

        // 切换识别中状态
        await tester.tap(find.text('识别中'));
        await tester.pumpAndSettle();
        _expectNoOverflowOrTruncation(tester, errors);
      });
    });

    testWidgets('16. ComponentGalleryPage 顶部调试入口可跳转至 DsPreviewPage',
        (WidgetTester tester) async {
      _setNarrowViewport(tester, size: const Size(480, 800));
      await _withCapturedErrors((errors) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(480, 800),
              devicePixelRatio: 1.0,
              disableAnimations: true,
            ),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildCommandTheme(Brightness.light),
              home: const ComponentGalleryPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final entry = find.text('Design System v3.0 预览');
        expect(entry, findsOneWidget);

        await tester.tap(entry);
        await tester.pumpAndSettle();

        expect(find.byType(DsPreviewPage), findsOneWidget);
        _expectNoOverflowOrTruncation(tester, errors, maxWidth: 480.0);
      });
    });
  });
}
