import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';

Widget _wrapWithDsTheme({
  required Widget child,
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  bool disableAnimations = false,
  Size? surfaceSize,
}) {
  Widget content = MediaQuery(
    data: MediaQueryData(
      size: surfaceSize ?? const Size(800, 600),
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
    ),
    child: MaterialApp(
      theme: buildCommandTheme(brightness),
      themeAnimationDuration: Duration.zero,
      home: child,
    ),
  );
  return content;
}

Future<void> _setViewport(
  WidgetTester tester,
  Size size, {
  double devicePixelRatio = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  group('CommandScaffold', () {
    testWidgets('昼白与暗曜均使用 canvas 背景并渲染 topBar / body / bottomNavigationBar',
        (WidgetTester tester) async {
      for (final brightness in Brightness.values) {
        final expectedColors = DsColors.of(brightness);
        await tester.pumpWidget(
          _wrapWithDsTheme(
            brightness: brightness,
            child: const CommandScaffold(
              topBar: Text('顶部信息栏'),
              body: Center(child: Text('主体内容')),
              bottomNavigationBar: SizedBox(height: 56, child: Text('底栏')),
            ),
          ),
        );

        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(scaffold.backgroundColor, expectedColors.canvas);
        expect(find.text('顶部信息栏'), findsOneWidget);
        expect(find.text('主体内容'), findsOneWidget);
        expect(find.text('底栏'), findsOneWidget);
        expect(find.byIcon(DsIcons.warning), findsNothing);
      }
    });

    testWidgets('isOffline 为 true 时渲染高对比告警横幅（cautionFill + onCaution）且 360dp/130% 无溢出',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));
      var tapped = false;

      await tester.pumpWidget(
        _wrapWithDsTheme(
          textScale: 1.3,
          surfaceSize: const Size(360, 640),
          child: CommandScaffold(
            isOffline: true,
            offlineMessage: '当前处于离线状态，已记录的现场操作将在恢复联网后自动补传',
            onOfflineTap: () => tapped = true,
            body: const Center(child: Text('内容')),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final icon = tester.widget<Icon>(find.byIcon(DsIcons.warning));
      expect(icon.color, DsColors.daylight.onCaution);

      final text = tester.widget<Text>(
        find.text('当前处于离线状态，已记录的现场操作将在恢复联网后自动补传'),
      );
      expect(text.style?.color, DsColors.daylight.onCaution);

      final bannerMaterial = tester.widget<Material>(
        find.ancestor(
          of: find.byIcon(DsIcons.warning),
          matching: find.byType(Material),
        ).first,
      );
      expect(bannerMaterial.color, DsColors.daylight.cautionFill);

      await tester.tap(find.text('当前处于离线状态，已记录的现场操作将在恢复联网后自动补传'));
      expect(tapped, isTrue);
    });
  });

  group('SurfaceCard', () {
    testWidgets('flat / outlined / raised 三层级配色、边框与阴影符合规范',
        (WidgetTester tester) async {
      for (final brightness in Brightness.values) {
        final colors = DsColors.of(brightness);
        await tester.pumpWidget(
          _wrapWithDsTheme(
            brightness: brightness,
            child: const Scaffold(
              body: Column(
                children: <Widget>[
                  SurfaceCard(level: DsSurfaceLevel.flat, child: Text('flat')),
                  SurfaceCard(
                    level: DsSurfaceLevel.outlined,
                    child: Text('outlined'),
                  ),
                  SurfaceCard(
                    level: DsSurfaceLevel.raised,
                    child: Text('raised'),
                  ),
                ],
              ),
            ),
          ),
        );

        Material cardMaterial(String label) => tester.widget<Material>(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(Material),
              ).first,
            );

        final flatMat = cardMaterial('flat');
        expect(flatMat.color, colors.surfaceMuted);
        expect(
          (flatMat.shape! as RoundedRectangleBorder).side,
          BorderSide.none,
        );

        final outlinedMat = cardMaterial('outlined');
        expect(outlinedMat.color, colors.surface);
        expect(
          (outlinedMat.shape! as RoundedRectangleBorder).side,
          BorderSide(color: colors.border, width: 1),
        );

        final raisedMat = cardMaterial('raised');
        expect(raisedMat.color, colors.surface);
        final raisedDecorated = find.ancestor(
          of: find.text('raised'),
          matching: find.byType(DecoratedBox),
        );
        if (brightness == Brightness.light) {
          expect(raisedDecorated, findsOneWidget);
        } else {
          expect(raisedDecorated, findsNothing);
        }
      }
    });

    testWidgets('accentStatus 支持内含 LayoutBuilder 的子组件并触发 onTap',
        (WidgetTester tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            body: SurfaceCard(
              accentStatus: DsStatus.alarm,
              onTap: () => tapped = true,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    Text('宽:${constraints.maxWidth.round()}'),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final accentBox = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(SurfaceCard),
          matching: find.byType(ColoredBox),
        ).first,
      );
      expect(accentBox.color, DsColors.daylight.alarmFill);

      await tester.tap(find.byType(SurfaceCard));
      expect(tapped, isTrue);
    });
  });

  group('MetricReadout', () {
    testWidgets('启用 FontFeature.tabularFigures 并在 colorByStatus 时采用 AAA metricText',
        (WidgetTester tester) async {
      for (final brightness in Brightness.values) {
        final colors = DsColors.of(brightness);
        for (final status in DsStatus.values) {
          await tester.pumpWidget(
            _wrapWithDsTheme(
              brightness: brightness,
              child: Scaffold(
                body: Row(
                  children: <Widget>[
                    MetricReadout(
                      value: '18.5',
                      unit: 'MPa',
                      label: '默认主色',
                      status: status,
                      colorByStatus: false,
                    ),
                    MetricReadout(
                      value: '24:05',
                      unit: 'min',
                      label: '状态读数',
                      status: status,
                      colorByStatus: true,
                      large: true,
                    ),
                  ],
                ),
              ),
            ),
          );

          final defaultText = tester.widget<Text>(find.text('18.5'));
          expect(
            defaultText.style?.fontFeatures,
            contains(const FontFeature.tabularFigures()),
          );
          expect(defaultText.style?.color, colors.textPrimary);

          final statusText = tester.widget<Text>(find.text('24:05'));
          expect(
            statusText.style?.fontFeatures,
            contains(const FontFeature.tabularFigures()),
          );
          expect(
            statusText.style?.color,
            colors.statusColors(status).metricText,
          );
        }
      }
    });

    testWidgets('120dp 极窄容器 + 130% 字号下零溢出', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrapWithDsTheme(
          textScale: 1.3,
          child: const Scaffold(
            body: SizedBox(
              width: 120,
              child: MetricReadout(
                value: '128:45',
                unit: 'min',
                label: '预计剩余工作时间',
                status: DsStatus.caution,
                colorByStatus: true,
                large: true,
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(FittedBox), findsOneWidget);
    });
  });

  group('StatusPill', () {
    testWidgets('双主题全部 5 种语义均同时渲染 Icon 与 Text 且无截断',
        (WidgetTester tester) async {
      for (final brightness in Brightness.values) {
        final colors = DsColors.of(brightness);
        for (final solid in <bool>[false, true]) {
          await tester.pumpWidget(
            _wrapWithDsTheme(
              brightness: brightness,
              textScale: 1.3,
              child: Scaffold(
                body: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final status in DsStatus.values)
                      StatusPill(status: status, solid: solid),
                  ],
                ),
              ),
            ),
          );

          expect(tester.takeException(), isNull);
          final pills = tester.widgetList<StatusPill>(find.byType(StatusPill));
          expect(pills.length, DsStatus.values.length);

          for (final status in DsStatus.values) {
            final pillFinder = find.byWidgetPredicate(
              (Widget w) => w is StatusPill && w.status == status,
            );
            final iconFinder = find.descendant(
              of: pillFinder,
              matching: find.byType(Icon),
            );
            final textFinder = find.descendant(
              of: pillFinder,
              matching: find.byType(Text),
            );
            expect(iconFinder, findsOneWidget);
            expect(textFinder, findsOneWidget);

            final pair = colors.statusColors(status);
            final expectedFg = solid ? pair.onFill : pair.text;
            expect(tester.widget<Icon>(iconFinder).color, expectedFg);
            expect(tester.widget<Text>(textFinder).style?.color, expectedFg);

            final pillSize = tester.getSize(pillFinder);
            expect(pillSize.height, greaterThanOrEqualTo(26.0));
          }
        }
      }
    });
  });

  group('CommandButton & CommandSheet', () {
    testWidgets('standard >= 48dp, large >= 56dp, loading 保持高度且禁用点击, ghost 使用 brandText',
        (WidgetTester tester) async {
      for (final brightness in Brightness.values) {
        final colors = DsColors.of(brightness);
        var tapCount = 0;

        await tester.pumpWidget(
          _wrapWithDsTheme(
            brightness: brightness,
            disableAnimations: true,
            child: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  CommandButton(
                    label: '常规主按钮',
                    size: CommandButtonSize.standard,
                    variant: CommandButtonVariant.primary,
                    onPressed: () => tapCount++,
                  ),
                  CommandButton(
                    label: '大号次按钮',
                    size: CommandButtonSize.large,
                    variant: CommandButtonVariant.secondary,
                    onPressed: () => tapCount++,
                  ),
                  CommandButton(
                    label: '幽灵按钮',
                    size: CommandButtonSize.standard,
                    variant: CommandButtonVariant.ghost,
                    onPressed: () => tapCount++,
                  ),
                  CommandButton(
                    label: '加载中主按钮',
                    size: CommandButtonSize.large,
                    variant: CommandButtonVariant.primary,
                    isLoading: true,
                    onPressed: () => tapCount++,
                  ),
                  CommandButton(
                    label: '禁用按钮',
                    enabled: false,
                    onPressed: () => tapCount++,
                  ),
                  const CommandButton(
                    label: '空回调按钮',
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ),
        );

        expect(
          tester.getSize(find.widgetWithText(CommandButton, '常规主按钮')).height,
          greaterThanOrEqualTo(48.0),
        );
        expect(
          tester.getSize(find.widgetWithText(CommandButton, '大号次按钮')).height,
          greaterThanOrEqualTo(56.0),
        );
        expect(
          tester.getSize(find.widgetWithText(CommandButton, '幽灵按钮')).height,
          greaterThanOrEqualTo(48.0),
        );
        expect(
          tester.getSize(find.widgetWithText(CommandButton, '加载中主按钮')).height,
          greaterThanOrEqualTo(56.0),
        );

        final ghostText = tester.widget<Text>(find.text('幽灵按钮'));
        expect(ghostText.style?.color, colors.brandText);

        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.tap(find.text('加载中主按钮'));
        await tester.tap(find.text('禁用按钮'));
        await tester.tap(find.text('空回调按钮'));
        expect(tapCount, 0);

        await tester.tap(find.text('常规主按钮'));
        expect(tapCount, 1);
      }
    });

    testWidgets('danger 按钮默认弹出 CommandSheet 二次确认，取消不触发，确认后触发，且 360dp/130% 无溢出',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));
      var evacCount = 0;

      await tester.pumpWidget(
        _wrapWithDsTheme(
          textScale: 1.3,
          surfaceSize: const Size(360, 640),
          child: Scaffold(
            body: Center(
              child: CommandButton(
                label: '一键全员撤离',
                variant: CommandButtonVariant.danger,
                size: CommandButtonSize.large,
                confirmMessage: '确认向全体内攻人员下达紧急撤离指令？',
                onPressed: () => evacCount++,
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byType(CommandButton)).height,
        greaterThanOrEqualTo(56.0),
      );

      // 首次点击不得直接执行回调，必须先弹出 CommandSheet
      await tester.tap(find.text('一键全员撤离'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(evacCount, 0);
      expect(find.byType(CommandSheet), findsOneWidget);
      expect(find.text('确认一键全员撤离'), findsNWidgets(2));
      expect(find.text('确认向全体内攻人员下达紧急撤离指令？'), findsOneWidget);

      // 点击取消关闭弹窗，回调仍为 0
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(evacCount, 0);
      expect(find.byType(CommandSheet), findsNothing);

      // 再次打开并点击确认按钮，回调执行 1 次
      await tester.tap(find.text('一键全员撤离'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CommandButton, '确认一键全员撤离'));
      await tester.pumpAndSettle();

      expect(evacCount, 1);
      expect(find.byType(CommandSheet), findsNothing);
    });

    testWidgets('showCommandSheet 透传局部 Theme(DsTheme)、textScaler 与实时 viewInsets',
        (WidgetTester tester) async {
      DsBrightnessCheck? observed;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            viewInsets: EdgeInsets.only(bottom: 180),
          ),
          child: MaterialApp(
            theme: ThemeData.light(),
            home: Builder(
              builder: (BuildContext outerContext) => MediaQuery(
                data: MediaQuery.of(outerContext).copyWith(
                  textScaler: const TextScaler.linear(1.3),
                  viewInsets: EdgeInsets.zero,
                ),
                child: Theme(
                  data: buildCommandTheme(Brightness.dark),
                  child: Builder(
                    builder: (BuildContext context) => Scaffold(
                      body: Center(
                        child: ElevatedButton(
                          onPressed: () {
                            showCommandSheet<void>(
                              context: context,
                              title: '录入压力读数',
                              subtitle: '示例路站 · 内攻一组',
                              builder: (BuildContext sheetCtx) {
                                observed = DsBrightnessCheck(
                                  brightness: sheetCtx.ds.brightness,
                                  textScale: MediaQuery.textScalerOf(sheetCtx)
                                      .scale(10),
                                  viewInsetsBottom:
                                      MediaQuery.viewInsetsOf(sheetCtx).bottom,
                                );
                                return const Text('弹窗内容');
                              },
                              actionsBuilder: (BuildContext sheetCtx) => <Widget>[
                                CommandButton(
                                  label: '关闭弹窗',
                                  onPressed: () =>
                                      Navigator.of(sheetCtx).pop(),
                                ),
                              ],
                            );
                          },
                          child: const Text('打开弹窗'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(observed, isNotNull);
      expect(observed!.brightness, Brightness.dark);
      expect(observed!.textScale, closeTo(13.0, 0.01));
      expect(observed!.viewInsetsBottom, closeTo(180.0, 0.01));
      expect(find.text('弹窗内容'), findsOneWidget);
      expect(find.text('示例路站 · 内攻一组'), findsOneWidget);

      final animatedPadding = tester.widget<AnimatedPadding>(
        find.descendant(
          of: find.byType(CommandSheet),
          matching: find.byType(AnimatedPadding),
        ),
      );
      expect(animatedPadding.padding, const EdgeInsets.only(bottom: 180));

      await tester.tap(find.text('关闭弹窗'));
      await tester.pumpAndSettle();
      expect(find.byType(CommandSheet), findsNothing);
    });

    testWidgets('CommandSheet 在紧凑/键盘/横屏/极矮视口下均零溢出且无 RangeError',
        (WidgetTester tester) async {
      final cases = <({
        String name,
        Size size,
        EdgeInsets padding,
        EdgeInsets viewInsets,
        double textScale,
      })>[
        (
          name: 'portrait-1.6x-kb280',
          size: const Size(360, 640),
          padding: const EdgeInsets.only(top: 44),
          viewInsets: const EdgeInsets.only(bottom: 280),
          textScale: 1.6,
        ),
        (
          name: 'landscape-1.3x-kb200',
          size: const Size(640, 360),
          padding: EdgeInsets.zero,
          viewInsets: const EdgeInsets.only(bottom: 200),
          textScale: 1.3,
        ),
        (
          name: 'portrait-1.0x-kb450',
          size: const Size(360, 640),
          padding: const EdgeInsets.only(top: 44),
          viewInsets: const EdgeInsets.only(bottom: 450),
          textScale: 1.0,
        ),
        (
          name: 'tiny-height-160',
          size: const Size(360, 160),
          padding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
          textScale: 1.0,
        ),
      ];

      for (final c in cases) {
        await _setViewport(tester, c.size);
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: c.size,
              padding: c.padding,
              viewPadding: c.padding,
              viewInsets: c.viewInsets,
              textScaler: TextScaler.linear(c.textScale),
            ),
            child: MaterialApp(
              theme: buildCommandTheme(Brightness.light),
              themeAnimationDuration: Duration.zero,
              home: Builder(
                builder: (BuildContext context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        showCommandSheet<void>(
                          context: context,
                          title: '确认向全体内攻人员下达紧急撤离指令',
                          subtitle: '示例路站 · 内攻一组与二组协同处置',
                          builder: (_) => const Text('请确认现场人员均已收到撤离信号。'),
                          actionsBuilder: (BuildContext sheetCtx) => <Widget>[
                            CommandButton(
                              label: '取消',
                              variant: CommandButtonVariant.secondary,
                              size: CommandButtonSize.large,
                              onPressed: () => Navigator.of(sheetCtx).pop(),
                            ),
                            CommandButton(
                              label: '确认撤离',
                              variant: CommandButtonVariant.primary,
                              size: CommandButtonSize.large,
                              onPressed: () => Navigator.of(sheetCtx).pop(),
                            ),
                          ],
                        );
                      },
                      child: Text('打开-${c.name}'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('打开-${c.name}'));
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: '${c.name} 应无 RenderFlex 溢出或 RangeError',
        );
        expect(find.byType(CommandSheet), findsOneWidget);

        // 通过滚动使关闭按钮可见或直接关闭弹窗，确保可正常交互退场
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(CommandSheet), findsNothing);
      }
    });

    testWidgets('CommandSheet 在正常高度下保持头部与底部操作栏固定、中间内容独立滚动',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));

      await tester.pumpWidget(
        _wrapWithDsTheme(
          textScale: 1.3,
          surfaceSize: const Size(360, 640),
          child: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showCommandSheet<void>(
                      context: context,
                      title: '气瓶压力录入',
                      subtitle: '示例路站 · 内攻一组',
                      builder: (_) => Column(
                        children: <Widget>[
                          for (var i = 0; i < 20; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text('第 $i 项检查记录'),
                            ),
                        ],
                      ),
                      actionsBuilder: (BuildContext sheetCtx) => <Widget>[
                        CommandButton(
                          label: '关闭',
                          size: CommandButtonSize.large,
                          onPressed: () => Navigator.of(sheetCtx).pop(),
                        ),
                      ],
                    );
                  },
                  child: const Text('打开长内容弹窗'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开长内容弹窗'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('气瓶压力录入'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);

      // 标题和底部按钮在正常高度下应位于可滚动内容区之外（固定不随正文滚走）
      final scrollFinder = find.descendant(
        of: find.byType(CommandSheet),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scrollFinder, findsOneWidget);
      expect(
        find.descendant(of: scrollFinder, matching: find.text('气瓶压力录入')),
        findsNothing,
      );
      expect(
        find.descendant(of: scrollFinder, matching: find.text('关闭')),
        findsNothing,
      );
    });

    testWidgets(
        'showCommandSheet 在 320x568 @ 1.6x 折行大按钮与 viewInsets 0..240 扫描下零溢出且可关闭',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(320, 568));

      for (double insets = 0; insets <= 240; insets += 20) {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 568),
              padding: const EdgeInsets.only(top: 24),
              viewPadding: const EdgeInsets.only(top: 24),
              viewInsets: EdgeInsets.only(bottom: insets),
              textScaler: const TextScaler.linear(1.6),
            ),
            child: MaterialApp(
              theme: buildCommandTheme(Brightness.light),
              themeAnimationDuration: Duration.zero,
              home: Builder(
                builder: (BuildContext context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        showCommandSheet<void>(
                          context: context,
                          title: '确认向全体内攻人员下达紧急撤离指令',
                          subtitle: '示例路站 · 内攻一组协同处置',
                          builder: (_) => const Text('请确认现场编组均已收到撤离信号。'),
                          actionsBuilder: (BuildContext sheetCtx) => <Widget>[
                            CommandButton(
                              label: '取消并返回待命位置',
                              variant: CommandButtonVariant.secondary,
                              size: CommandButtonSize.large,
                              onPressed: () => Navigator.of(sheetCtx).pop(),
                            ),
                            CommandButton(
                              label: '确认向全体编组下达撤离指令',
                              variant: CommandButtonVariant.primary,
                              size: CommandButtonSize.large,
                              onPressed: () => Navigator.of(sheetCtx).pop(),
                            ),
                          ],
                        );
                      },
                      child: const Text('打开弹窗'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('打开弹窗'));
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: '320x568 @ 1.6x insets=$insets 不应出现任何溢出异常',
        );
        expect(find.byType(CommandSheet), findsOneWidget);

        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(CommandSheet), findsNothing);
      }
    });

    testWidgets(
        'showCommandSheet 在 360x640 @ 1.6x Column 堆叠操作栏与 viewInsets 0..300 扫描下零溢出且可关闭',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));

      for (double insets = 0; insets <= 300; insets += 30) {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 640),
              padding: const EdgeInsets.only(top: 44, bottom: 34),
              viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
              viewInsets: EdgeInsets.only(bottom: insets),
              textScaler: const TextScaler.linear(1.6),
            ),
            child: MaterialApp(
              theme: buildCommandTheme(Brightness.light),
              themeAnimationDuration: Duration.zero,
              home: Builder(
                builder: (BuildContext context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        showCommandSheet<void>(
                          context: context,
                          title: '示例县示例路站东侧仓储物流园夜间灭火协同确认',
                          subtitle: '内攻一组与二组气瓶余压复核后方可执行切换',
                          builder: (_) => const Text('请核对各编组当前压力读数与在场人数。'),
                          actionsBuilder: (BuildContext sheetCtx) => <Widget>[
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                CommandButton(
                                  label: '确认立即执行切换',
                                  variant: CommandButtonVariant.primary,
                                  size: CommandButtonSize.large,
                                  expanded: true,
                                  onPressed: () =>
                                      Navigator.of(sheetCtx).pop(),
                                ),
                                const SizedBox(height: DsSpacing.sm),
                                CommandButton(
                                  label: '暂缓并保持当前编组',
                                  variant: CommandButtonVariant.secondary,
                                  size: CommandButtonSize.large,
                                  expanded: true,
                                  onPressed: () =>
                                      Navigator.of(sheetCtx).pop(),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                      child: const Text('打开弹窗'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('打开弹窗'));
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: '360x640 Column actions @ 1.6x insets=$insets 不应溢出',
        );
        expect(find.byType(CommandSheet), findsOneWidget);

        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(CommandSheet), findsNothing);
      }
    });

    testWidgets(
        '直接渲染 CommandSheet 在 320dp @ 1.6x 三行折行大按钮与 120..500 高度扫描及极矮边界下零溢出',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(320, 640));

      final heights = <double>[
        0,
        60,
        for (double h = 120; h <= 500; h += 10) h,
      ];

      for (final h in heights) {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.6),
            ),
            child: MaterialApp(
              theme: buildCommandTheme(Brightness.light),
              themeAnimationDuration: Duration.zero,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 320,
                    height: h,
                    child: CommandSheet(
                      title: '内攻编组高压异常处置确认',
                      subtitle: '示例路站 · 内攻一组',
                      actions: <Widget>[
                        CommandButton(
                          label: '取消操作并返回现场监控主界面视图',
                          variant: CommandButtonVariant.secondary,
                          size: CommandButtonSize.large,
                          onPressed: () {},
                        ),
                        CommandButton(
                          label: '确认下达全员撤离并记录火场日志',
                          variant: CommandButtonVariant.primary,
                          size: CommandButtonSize.large,
                          onPressed: () {},
                        ),
                      ],
                      child: LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints constraints) {
                          return Text(
                            '可用宽度:${constraints.maxWidth.round()}，请确认全部人员已收到撤离通知。',
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(
          tester.takeException(),
          isNull,
          reason: 'height=$h on 320dp @ 1.6x 不应发生溢出或布局异常',
        );
      }
    });

    testWidgets('360x800 下正文可独立滚动且头尾固定，向下拖拽标题可关闭弹窗',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 800));

      await tester.pumpWidget(
        _wrapWithDsTheme(
          surfaceSize: const Size(360, 800),
          child: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showCommandSheet<void>(
                      context: context,
                      title: '巡检记录',
                      subtitle: '示例路站 · 内攻一组',
                      builder: (_) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (var i = 0; i < 30; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text('第 $i 项压力巡检记录'),
                            ),
                        ],
                      ),
                      actionsBuilder: (BuildContext sheetCtx) => <Widget>[
                        CommandButton(
                          label: '完成核查',
                          size: CommandButtonSize.large,
                          onPressed: () => Navigator.of(sheetCtx).pop(),
                        ),
                      ],
                    );
                  },
                  child: const Text('打开巡检弹窗'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开巡检弹窗'));
      await tester.pumpAndSettle();

      final titleTopBefore = tester.getTopLeft(find.text('巡检记录')).dy;
      final actionTopBefore = tester.getTopLeft(find.text('完成核查')).dy;
      final item0TopBefore =
          tester.getTopLeft(find.text('第 0 项压力巡检记录')).dy;

      await tester.drag(
        find.descendant(
          of: find.byType(CommandSheet),
          matching: find.byType(SingleChildScrollView),
        ),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('巡检记录')).dy,
        closeTo(titleTopBefore, 0.01),
      );
      expect(
        tester.getTopLeft(find.text('完成核查')).dy,
        closeTo(actionTopBefore, 0.01),
      );
      expect(
        tester.getTopLeft(find.text('第 0 项压力巡检记录')).dy,
        lessThan(item0TopBefore),
      );

      // 在正常高度下向下拖拽头部标题，应触发外层 ModalBottomSheet 下拉关闭
      await tester.fling(
        find.text('巡检记录'),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.byType(CommandSheet), findsNothing);
    });

    testWidgets('短内容危险确认弹窗（CommandButton danger）在 360x640 下保持紧凑收缩高度',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));

      await tester.pumpWidget(
        _wrapWithDsTheme(
          surfaceSize: const Size(360, 640),
          child: Scaffold(
            body: Center(
              child: CommandButton(
                label: '一键全员撤离',
                variant: CommandButtonVariant.danger,
                size: CommandButtonSize.large,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('一键全员撤离'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final sheetSize = tester.getSize(find.byType(CommandSheet));
      expect(sheetSize.height, lessThan(640 * 0.65));
    });

    testWidgets(
        'TextField 在 viewInsets.bottom 0 -> 280 -> 0 跨越正常/紧致边界时保持焦点、文本与选区',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));

      final controller = TextEditingController(text: '初始压力 28.5');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      double currentInsets = 0.0;
      late StateSetter updateInsets;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            updateInsets = setState;
            return MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 640),
                padding: const EdgeInsets.only(top: 44, bottom: 34),
                viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
                viewInsets: EdgeInsets.only(bottom: currentInsets),
                textScaler: const TextScaler.linear(1.6),
              ),
              child: MaterialApp(
                theme: buildCommandTheme(Brightness.light).copyWith(
                  platform: TargetPlatform.iOS,
                ),
                themeAnimationDuration: Duration.zero,
                home: Builder(
                  builder: (BuildContext appContext) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        onPressed: () {
                          showCommandSheet<void>(
                            context: appContext,
                            title: '录入气瓶余压读数',
                            subtitle: '示例路站 · 内攻一组',
                            builder: (_) => TextField(
                              controller: controller,
                              focusNode: focusNode,
                            ),
                            actionsBuilder: (BuildContext sheetCtx) =>
                                <Widget>[
                              CommandButton(
                                label: '取消',
                                variant: CommandButtonVariant.secondary,
                                size: CommandButtonSize.large,
                                onPressed: () =>
                                    Navigator.of(sheetCtx).pop(),
                              ),
                              CommandButton(
                                label: '保存读数',
                                variant: CommandButtonVariant.primary,
                                size: CommandButtonSize.large,
                                onPressed: () =>
                                    Navigator.of(sheetCtx).pop(),
                              ),
                            ],
                          );
                        },
                        child: const Text('打开输入弹窗'),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );

      await tester.tap(find.text('打开输入弹窗'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection =
          const TextSelection(baseOffset: 2, extentOffset: 4);
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(controller.text, '初始压力 28.5');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 4),
      );

      // 弹出 280dp 键盘跨越至紧致模式
      updateInsets(() => currentInsets = 280.0);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(focusNode.hasFocus, isTrue);
      expect(controller.text, '初始压力 28.5');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 4),
      );

      // 收起键盘返回正常模式
      updateInsets(() => currentInsets = 0.0);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(focusNode.hasFocus, isTrue);
      expect(controller.text, '初始压力 28.5');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 4),
      );
    });

    testWidgets('紧致模式下整表可向上滚动并命中底部操作按钮', (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 180));
      var confirmed = false;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 180),
            textScaler: TextScaler.linear(1.3),
          ),
          child: MaterialApp(
            theme: buildCommandTheme(Brightness.light),
            themeAnimationDuration: Duration.zero,
            home: Builder(
              builder: (BuildContext context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showCommandSheet<void>(
                        context: context,
                        title: '紧致高度交互确认',
                        subtitle: '示例路站 · 内攻一组',
                        builder: (_) => const Text('请滑动确认底部操作按钮可点击。'),
                        actionsBuilder: (BuildContext sheetCtx) => <Widget>[
                          CommandButton(
                            label: '确定执行',
                            size: CommandButtonSize.large,
                            onPressed: () {
                              confirmed = true;
                              Navigator.of(sheetCtx).pop();
                            },
                          ),
                        ],
                      );
                    },
                    child: const Text('打开紧致弹窗'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开紧致弹窗'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CommandSheet), const Offset(0, -180));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(CommandButton, '确定执行'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
      expect(find.byType(CommandSheet), findsNothing);
    });
  });

  group('StatePlaceholder', () {
    testWidgets('.loading() 在 disableAnimations: true 下安全 settle，.empty() 与 .error() 交互正常',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrapWithDsTheme(
          disableAnimations: true,
          child: const Scaffold(
            body: StatePlaceholder.loading(message: '正在同步现场态势'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('正在同步现场态势'), findsOneWidget);

      var emptyTapped = false;
      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            body: StatePlaceholder.empty(
              message: '暂无内攻编组',
              detail: '点击下方按钮添加首批内攻人员',
              actionLabel: '录入进场',
              onAction: () => emptyTapped = true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('录入进场'));
      expect(emptyTapped, isTrue);

      var retryTapped = false;
      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            body: StatePlaceholder.error(
              reason: '连接调度服务器超时',
              onRetry: () => retryTapped = true,
            ),
          ),
        ),
      );
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('连接调度服务器超时'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retryTapped, isTrue);
    });
  });

  group('ToolGrid', () {
    testWidgets('采用响应式 Row/Expanded 布局（无 GridView），360dp + 130% 无溢出且支持徽章与禁用态',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));
      var tappedId = '';

      final items = <DsToolItem>[
        DsToolItem(
          id: 'entry',
          icon: Icons.login_rounded,
          label: '内攻进场',
          badge: '2',
          onTap: () => tappedId = 'entry',
        ),
        DsToolItem(
          id: 'pressure',
          icon: Icons.speed_rounded,
          label: '气瓶压力',
          onTap: () => tappedId = 'pressure',
        ),
        DsToolItem(
          id: 'evac',
          icon: Icons.campaign_rounded,
          label: '紧急撤离',
          badge: '急',
          badgeStatus: DsStatus.timeout,
          onTap: () => tappedId = 'evac',
        ),
        DsToolItem(
          id: 'note',
          icon: Icons.edit_note_rounded,
          label: '火场随手记',
          enabled: false,
          onTap: () => tappedId = 'note',
        ),
        DsToolItem(
          id: 'roster',
          icon: Icons.groups_rounded,
          label: '参战名单',
          onTap: () => tappedId = 'roster',
        ),
        DsToolItem(
          id: 'scan',
          icon: Icons.qr_code_scanner_rounded,
          label: '扫码登记',
          onTap: () => tappedId = 'scan',
        ),
      ];

      await tester.pumpWidget(
        _wrapWithDsTheme(
          textScale: 1.3,
          surfaceSize: const Size(360, 640),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ToolGrid(items: items),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(GridView), findsNothing);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('急'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ds-tool-note')));
      expect(tappedId, '');

      await tester.tap(find.byKey(const Key('ds-tool-entry')));
      expect(tappedId, 'entry');
    });
  });

  group('TimelineList', () {
    testWidgets('同分钟连续记录折叠至同一时间戳，间隔或跨日不折叠，且时间戳启用等宽数字',
        (WidgetTester tester) async {
      final entries = <DsTimelineEntry>[
        DsTimelineEntry(
          timestamp: DateTime(2026, 11, 21, 14, 22, 5),
          icon: Icons.login_rounded,
          title: '张三、李四进入二层东侧',
          categoryLabel: '进场',
          status: DsStatus.safe,
        ),
        DsTimelineEntry(
          timestamp: DateTime(2026, 11, 21, 14, 22, 48),
          icon: Icons.speed_rounded,
          title: '王五上报余压 24 MPa',
          subtitle: '压力正常',
        ),
        DsTimelineEntry(
          timestamp: DateTime(2026, 11, 21, 14, 20, 10),
          icon: Icons.warning_amber_rounded,
          title: '南侧温度升高提示',
          status: DsStatus.caution,
        ),
        DsTimelineEntry(
          timestamp: DateTime(2026, 11, 21, 14, 22, 55),
          icon: Icons.notifications_active_rounded,
          title: '二组触发低压预警',
          status: DsStatus.alarm,
        ),
        DsTimelineEntry(
          timestamp: DateTime(2026, 11, 20, 14, 22, 12),
          icon: Icons.info_outline_rounded,
          title: '前一日演练记录',
        ),
      ];

      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TimelineList(entries: entries),
            ),
          ),
        ),
      );

      // 第 1、2 条同属 11-21 14:22 -> 合并；第 4 条被 14:20 隔开 -> 单独；第 5 条跨日 -> 单独
      expect(find.text('14:22'), findsNWidgets(3));
      expect(find.text('14:20'), findsOneWidget);

      final timeText = tester.widget<Text>(find.text('14:20'));
      expect(
        timeText.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );

      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: const Scaffold(
            body: TimelineList(entries: <DsTimelineEntry>[]),
          ),
        ),
      );
      expect(find.text('暂无时间线记录'), findsOneWidget);
    });
  });

  group('CommandNavBar', () {
    testWidgets('4 标签切换、brandText 高亮、64dp 凸起语音键全热区命中及 360dp/130% 零溢出',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));
      var selected = 0;
      var voiceTapCount = 0;
      var longPressStarted = 0;
      var longPressEnded = 0;

      for (final brightness in Brightness.values) {
        final colors = DsColors.of(brightness);
        selected = 1;
        voiceTapCount = 0;
        longPressStarted = 0;
        longPressEnded = 0;

        await tester.pumpWidget(
          _wrapWithDsTheme(
            brightness: brightness,
            textScale: 1.3,
            surfaceSize: const Size(360, 640),
            child: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: CommandNavBar(
                selectedIndex: selected,
                onSelectTab: (int i) => selected = i,
                onVoiceTap: () => voiceTapCount++,
                onVoiceLongPressStart: (_) => longPressStarted++,
                onVoiceLongPressEnd: (_) => longPressEnded++,
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        for (final label in const <String>['指挥台', '安全管控', '智能辅助', '我的']) {
          expect(find.text(label), findsOneWidget);
        }

        final selectedTabText = tester.widget<Text>(find.text('安全管控'));
        expect(selectedTabText.style?.color, colors.brandText);

        final voiceRect =
            tester.getRect(find.byKey(const Key('ds-nav-voice-button')));
        final barRect =
            tester.getRect(find.byKey(const Key('ds-nav-bar-surface')));
        expect(voiceRect.size, const Size(64, 64));
        expect(
          barRect.top - voiceRect.top,
          closeTo(DsSizes.voiceProtrusion, 0.01),
        );

        // 点击向上凸出顶栏 12dp 的区域（topCenter + Offset(0, 2)）必须真实命中
        await tester.tapAt(voiceRect.topCenter + const Offset(0, 2));
        await tester.pump();
        expect(voiceTapCount, 1);

        await tester.longPressAt(voiceRect.topCenter + const Offset(0, 2));
        await tester.pump();
        expect(longPressStarted, 1);
        expect(longPressEnded, 1);

        await tester.tap(find.byKey(const Key('ds-nav-tab-2')));
        expect(selected, 2);
      }
    });

    testWidgets('语音键三态 idle / recording / processing 及 disableAnimations 兼容',
        (WidgetTester tester) async {
      var voiceTapCount = 0;

      // idle
      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            bottomNavigationBar: CommandNavBar(
              selectedIndex: 0,
              onSelectTab: (_) {},
              voiceState: DsVoiceState.idle,
              onVoiceTap: () => voiceTapCount++,
            ),
          ),
        ),
      );
      expect(find.byIcon(DsIcons.voiceLine), findsOneWidget);

      // recording (disableAnimations: false -> pump 200ms 正常推进)
      await tester.pumpWidget(
        _wrapWithDsTheme(
          disableAnimations: false,
          child: Scaffold(
            bottomNavigationBar: CommandNavBar(
              selectedIndex: 0,
              onSelectTab: (_) {},
              voiceState: DsVoiceState.recording,
              onVoiceTap: () => voiceTapCount++,
            ),
          ),
        ),
      );
      expect(find.byIcon(DsIcons.voiceFill), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));

      // recording (disableAnimations: true -> pumpAndSettle 立即完成)
      await tester.pumpWidget(
        _wrapWithDsTheme(
          disableAnimations: true,
          child: Scaffold(
            bottomNavigationBar: CommandNavBar(
              selectedIndex: 0,
              onSelectTab: (_) {},
              voiceState: DsVoiceState.recording,
              onVoiceTap: () => voiceTapCount++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // processing (屏蔽点击且 disableAnimations: true 下 settle)
      await tester.pumpWidget(
        _wrapWithDsTheme(
          disableAnimations: true,
          child: Scaffold(
            bottomNavigationBar: CommandNavBar(
              selectedIndex: 0,
              onSelectTab: (_) {},
              voiceState: DsVoiceState.processing,
              onVoiceTap: () => voiceTapCount++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byKey(const Key('ds-nav-voice-button')));
      expect(voiceTapCount, 0);
    });
  });

  group('IncidentHeader & ConnectionPill', () {
    testWidgets('ConnectionPill 三态均含 Icon+Text 并支持点击回调',
        (WidgetTester tester) async {
      var tapped = false;

      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            body: Column(
              children: <Widget>[
                const ConnectionPill(state: DsConnectionState.online),
                const ConnectionPill(state: DsConnectionState.reconnecting),
                ConnectionPill(
                  state: DsConnectionState.offline,
                  pendingCount: 3,
                  onTap: () => tapped = true,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('在线'), findsOneWidget);
      expect(find.byIcon(DsIcons.connOnline), findsOneWidget);
      expect(find.text('重连中'), findsOneWidget);
      expect(find.byIcon(DsIcons.connReconnecting), findsOneWidget);
      expect(find.text('离线 · 待补传 3'), findsOneWidget);
      expect(find.byIcon(DsIcons.connOffline), findsOneWidget);

      await tester.tap(find.text('离线 · 待补传 3'));
      expect(tapped, isTrue);
    });

    testWidgets('IncidentHeader 在 360dp + 130% 字号下零溢出且时间使用 tabularFigures',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));
      var headerTapped = false;
      var connTapped = false;

      await tester.pumpWidget(
        _wrapWithDsTheme(
          textScale: 1.3,
          surfaceSize: const Size(360, 640),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: IncidentHeader(
                incidentName: '示例县示例路站东侧仓储物流园火灾扑救',
                category: DsIncidentCategory.fire,
                elapsedText: '00:24:18',
                highestRiskStatus: DsStatus.alarm,
                highestRiskLabel: '1人低压告警',
                connectionState: DsConnectionState.offline,
                pendingSyncCount: 2,
                onTap: () => headerTapped = true,
                onConnectionTap: () => connTapped = true,
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('火灾'), findsOneWidget);
      expect(find.text('1人低压告警'), findsOneWidget);
      expect(find.text('离线 · 待补传 2'), findsOneWidget);

      final elapsedText = tester.widget<Text>(find.text('00:24:18'));
      expect(
        elapsedText.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );

      await tester.tap(find.text('离线 · 待补传 2'));
      expect(connTapped, isTrue);

      await tester.tap(find.text('示例县示例路站东侧仓储物流园火灾扑救'));
      expect(headerTapped, isTrue);
    });

    testWidgets(
        'IncidentHeader 在 360dp + 130% + 离线多位数待补传与长类别标签下零溢出且标题宽度充足',
        (WidgetTester tester) async {
      await _setViewport(tester, const Size(360, 640));
      const incidentName = '示例县示例路大型化工仓储区夜间灭火救援行动';

      for (final scenario in <({String categoryLabel, int pending})>[
        (categoryLabel: '火灾', pending: 12),
        (categoryLabel: '化工火灾', pending: 12),
        (categoryLabel: '危险品泄漏', pending: 12),
        (categoryLabel: '危险化学品泄漏抢险', pending: 999),
      ]) {
        await tester.pumpWidget(
          _wrapWithDsTheme(
            textScale: 1.3,
            surfaceSize: const Size(360, 640),
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: IncidentHeader(
                  incidentName: incidentName,
                  category: DsIncidentCategory.rescue,
                  categoryLabel: scenario.categoryLabel,
                  elapsedText: '00:42:15',
                  highestRiskStatus: DsStatus.timeout,
                  connectionState: DsConnectionState.offline,
                  pendingSyncCount: scenario.pending,
                ),
              ),
            ),
          ),
        );

        expect(
          tester.takeException(),
          isNull,
          reason:
              '${scenario.categoryLabel} + pending:${scenario.pending} 不应溢出',
        );
        expect(find.text(scenario.categoryLabel), findsOneWidget);
        expect(
          find.text('离线 · 待补传 ${scenario.pending}'),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.text(incidentName)).width,
          greaterThanOrEqualTo(150.0),
          reason: '${scenario.categoryLabel} 场景下标题不应被挤压过窄',
        );

        final colors = DsColors.of(Brightness.light);
        final pillContainer = tester.widget<Container>(
          find.byKey(const Key('incident-header-category-pill')),
        );
        final pillDecoration = pillContainer.decoration! as BoxDecoration;
        expect(pillDecoration.color, colors.brand.withValues(alpha: 0.12));
        final pillLabel = tester.widget<Text>(find.text(scenario.categoryLabel));
        expect(pillLabel.style?.color, colors.brandText);
      }
    });

    testWidgets('IncidentHeader embedded=true 不套外层 SurfaceCard 且保留点击回调', (
      WidgetTester tester,
    ) async {
      var tapped = 0;
      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            body: IncidentHeader(
              incidentName: '示例仓库火灾',
              elapsedText: '今日 10:00',
              highestRiskStatus: DsStatus.neutral,
              connectionState: DsConnectionState.online,
              embedded: true,
              onTap: () => tapped++,
            ),
          ),
        ),
      );

      expect(find.byType(SurfaceCard), findsNothing);
      await tester.tap(find.text('示例仓库火灾'));
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('CommandButton dangerOutlined 渲染克制描边样式且默认触发二次确认', (
      WidgetTester tester,
    ) async {
      var confirmed = 0;
      await tester.pumpWidget(
        _wrapWithDsTheme(
          child: Scaffold(
            body: Center(
              child: CommandButton(
                label: '归档警情',
                variant: CommandButtonVariant.dangerOutlined,
                onPressed: () => confirmed++,
              ),
            ),
          ),
        ),
      );

      final colors = DsColors.of(Brightness.light);
      final text = tester.widget<Text>(find.text('归档警情'));
      expect(text.style?.color, colors.alarmText);

      await tester.tap(find.text('归档警情'));
      await tester.pumpAndSettle();
      expect(confirmed, 0);
      expect(find.text('确认归档警情'), findsNWidgets(2));

      await tester.tap(find.widgetWithText(CommandButton, '确认归档警情'));
      await tester.pumpAndSettle();
      expect(confirmed, 1);
    });
  });

  group('ToolGrid 现场工具锁定态组件测试', () {
    testWidgets('locked=true 渲染中性灰阶底框、锁头徽标与无障碍提示，且保持可点击并兼容 badge 优先级', (
      tester,
    ) async {
      final semanticsHandle = tester.ensureSemantics();
      try {
        var lockedTapped = 0;
        var openTapped = 0;

        await tester.pumpWidget(
          _wrapWithDsTheme(
            brightness: Brightness.light,
            child: ToolGrid(
              columns: 3,
              items: <DsToolItem>[
                DsToolItem(
                  id: 'open',
                  icon: DsIcons.toolHazmat,
                  label: '危化速查',
                  onTap: () => openTapped++,
                ),
                DsToolItem(
                  id: 'locked',
                  icon: DsIcons.toolKeySites,
                  label: '重点单位',
                  locked: true,
                  onTap: () => lockedTapped++,
                ),
                DsToolItem(
                  id: 'badged-locked',
                  icon: DsIcons.toolVideoResources,
                  label: '视频资源',
                  badge: '新',
                  locked: true,
                  onTap: () {},
                ),
              ],
            ),
          ),
        );

        expect(find.byKey(const Key('ds-tool-lock-open')), findsNothing);
        expect(find.byKey(const Key('ds-tool-lock-locked')), findsOneWidget);
        expect(find.byKey(const Key('ds-tool-lock-badged-locked')), findsNothing);
        expect(find.text('新'), findsOneWidget);

        final lockedSemantics = tester.getSemantics(
          find.byKey(const Key('ds-tool-locked')),
        );
        expect(lockedSemantics.label, '重点单位，需单位认证后使用');

        await tester.tap(find.byKey(const Key('ds-tool-locked')));
        await tester.tap(find.byKey(const Key('ds-tool-open')));
        await tester.pump();
        expect(lockedTapped, 1);
        expect(openTapped, 1);

        final colors = DsColors.of(Brightness.light);
        final lockedLabel = tester.widget<Text>(find.text('重点单位'));
        expect(lockedLabel.style?.color, colors.textSecondary);
      } finally {
        semanticsHandle.dispose();
      }
    });

    testWidgets('360dp 窄屏 + 130% 字体缩放在昼白与暗曜模式下含锁定工具宫格零溢出', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _wrapWithDsTheme(
            brightness: brightness,
            textScale: 1.3,
            surfaceSize: const Size(360, 740),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(DsSpacing.pageMargin),
              child: ToolGrid(
                columns: 4,
                items: <DsToolItem>[
                  DsToolItem(
                    id: 'a',
                    icon: DsIcons.toolKeySites,
                    label: '重点单位',
                    locked: true,
                    onTap: () {},
                  ),
                  DsToolItem(
                    id: 'b',
                    icon: DsIcons.toolHazmat,
                    label: '危化速查',
                    onTap: () {},
                  ),
                  DsToolItem(
                    id: 'c',
                    icon: DsIcons.toolVideoResources,
                    label: '视频资源',
                    locked: true,
                    onTap: () {},
                  ),
                  DsToolItem(
                    id: 'd',
                    icon: DsIcons.toolSceneMap,
                    label: '现场地图',
                    locked: true,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        );

        expect(
          tester.takeException(),
          isNull,
          reason: '$brightness 模式下 ToolGrid 锁定态不应发生溢出或异常',
        );
      }
    });
  });
}

class DsBrightnessCheck {
  const DsBrightnessCheck({
    required this.brightness,
    required this.textScale,
    required this.viewInsetsBottom,
  });

  final Brightness brightness;
  final double textScale;
  final double viewInsetsBottom;
}
