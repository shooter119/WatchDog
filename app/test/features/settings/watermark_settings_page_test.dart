import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/settings/ui/watermark_settings_page.dart';
import 'package:watchdog/services/watermark_settings.dart';

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildCommandTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openFromLauncher(
  WidgetTester tester, {
  double scale = 1.0,
  String unitName = '示例市消防救援支队',
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (unitName.isNotEmpty) 'unit_name': unitName,
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildCommandTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const WatermarkSettingsPage(),
              ),
            ),
            child: const Text('打开设置'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('WatermarkSettingsPage 水印设置', () {
    testWidgets('加载后显示三个输入框、五个显示开关、队徽资源与空抬头占位', (tester) async {
      _useTallViewport(tester);
      await _pumpPage(tester, const WatermarkSettingsPage());

      expect(find.text('水印设置'), findsOneWidget);
      expect(find.text('效果预览'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.text('单位抬头'), findsOneWidget);
      expect(find.text('拍摄单位'), findsOneWidget);
      expect(find.text('拍摄人'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNWidgets(5));
      expect(find.text('未填写单位抬头'), findsOneWidget);

      final badge = tester.widget<Image>(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName ==
                  'assets/branding/fire_rescue_badge.png',
        ),
      );
      expect(badge, isNotNull);

      expect(find.text('拍摄\r\n时间'), findsOneWidget);
      expect(find.text('晴 21℃ 东南风2级 湿度87%'), findsOneWidget);
      expect(find.text('示例市 · 某某有限公司'), findsOneWidget);
      expect(find.text('东经 118°22′'), findsOneWidget);
      expect(find.text('北纬 29°0′'), findsOneWidget);
    });

    testWidgets('修改文本后预览同步更新，关闭开关后对应字段消失并即时保存', (tester) async {
      _useTallViewport(tester);
      await _pumpPage(tester, const WatermarkSettingsPage());

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '示例省总队测试支队');
      await tester.enterText(fields.at(1), '通信保障分队');
      await tester.enterText(fields.at(2), '张三');
      await tester.pump();

      expect(find.text('未填写单位抬头'), findsNothing);
      expect(find.text('拍摄单位：通信保障分队'), findsOneWidget);
      expect(find.text('拍摄人'), findsNWidgets(2));
      expect(find.text('张三'), findsNWidgets(2));

      await tester.tap(find.widgetWithText(SwitchListTile, '拍摄时间'));
      await tester.tap(find.widgetWithText(SwitchListTile, '天气'));
      await tester.pumpAndSettle();

      expect(find.text('拍摄\r\n时间'), findsNothing);
      expect(find.text('晴 21℃ 东南风2级 湿度87%'), findsNothing);
      expect(find.text('示例市 · 某某有限公司'), findsOneWidget);
      final saved = await WatermarkSettings.load();
      expect(saved.showTime, isFalse);
      expect(saved.showWeather, isFalse);
    });

    testWidgets('空抬头回落登录单位，编辑与清空同步预览', (tester) async {
      await _openFromLauncher(tester);
      expect(find.text('示例市消防救援支队'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '通信保障分队');
      await tester.pump();
      expect(find.text('通信保障分队'), findsNWidgets(2));
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      expect(find.text('示例市消防救援支队'), findsOneWidget);
    });

    testWidgets('返回时冲刷未完成防抖的输入并立即保存', (tester) async {
      await _openFromLauncher(tester);
      await tester.enterText(find.byType(TextField).first, '立即返回的单位');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('打开设置'), findsOneWidget);
      expect((await WatermarkSettings.load()).unitTitle, '立即返回的单位');
    });

    testWidgets('连续编辑防抖写入 SharedPreferences，只保留最终内容且无保存按钮', (tester) async {
      _useTallViewport(tester);
      await _pumpPage(tester, const WatermarkSettingsPage());

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '初始单位');
      await tester.enterText(fields.at(0), '测试支队');
      await tester.enterText(fields.at(1), '测试分队');
      await tester.enterText(fields.at(2), '李四');
      await tester.pump();

      expect(find.text('保存'), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('watermark_settings_v1');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['unitTitle'], '测试支队');
      expect(decoded['department'], '测试分队');
      expect(decoded['actorName'], '李四');
    });

    testWidgets('横竖屏拍摄方向切换即时持久化', (tester) async {
      _useTallViewport(tester);
      await _pumpPage(tester, const WatermarkSettingsPage());

      await tester.tap(find.byKey(const Key('capture-orientation-portrait')));
      await tester.pumpAndSettle();
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.portrait,
      );

      await tester.tap(find.byKey(const Key('capture-orientation-landscape')));
      await tester.pumpAndSettle();
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.landscape,
      );
    });

    testWidgets('没有登录单位时明确提示抬头缺失', (tester) async {
      await _openFromLauncher(tester, unitName: '');
      expect(find.text('未填写单位抬头'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '临时支援单位');
      await tester.pump();
      expect(find.text('临时支援单位'), findsNWidgets(2));
    });

    testWidgets('预览蓝条白字对比度至少 4.5', (tester) async {
      await _openFromLauncher(tester);
      final title = tester.widget<Text>(find.text('示例市消防救援支队'));
      final bar = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('示例市消防救援支队'),
              matching: find.byWidgetPredicate(
                (w) => w is Container && w.color != null,
              ),
            )
            .first,
      );
      final fg = title.style!.color!.computeLuminance();
      final bg = bar.color!.computeLuminance();
      expect((fg + 0.05) / (bg + 0.05), greaterThanOrEqualTo(4.5));
    });

    for (final (width, scale) in const <(double, double)>[
      (360.0, 1.3),
      (320.0, 1.5),
      (320.0, 2.0),
    ]) {
      testWidgets('${width.toInt()}dp 字号 $scale 全页无溢出且标题完整换行', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _openFromLauncher(tester, scale: scale);

        await tester.scrollUntilVisible(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == '单位抬头',
          ),
          200,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        const longTitle = '很长的单位名称用于确认顶部蓝条在大字号下能够换行显示全部文字';
        await tester.enterText(find.byType(TextField).first, longTitle);
        await tester.pump();
        expect(tester.takeException(), isNull);

        for (var i = 0; i < 14; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -240));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        await tester.drag(find.byType(ListView), const Offset(0, 5000));
        await tester.pumpAndSettle();

        final title = tester.widget<Text>(
          find.byWidgetPredicate((w) => w is Text && w.data == longTitle),
        );
        expect(title.maxLines, isNull);
        expect(title.overflow, isNot(TextOverflow.ellipsis));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
