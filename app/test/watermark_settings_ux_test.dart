import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/pages/watermark_settings_page.dart';
import 'package:watchdog/services/watermark_settings.dart';

Future<void> openPage(
  WidgetTester tester, {
  double scale = 1,
  String unitName = '衢州市消防救援支队',
}) async {
  SharedPreferences.setMockInitialValues({'unit_name': unitName});
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
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
  testWidgets('空抬头使用登录单位，编辑同步预览', (tester) async {
    await openPage(tester);
    expect(find.text('衢州市消防救援支队'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '通信保障分队');
    await tester.pump();
    expect(find.text('通信保障分队'), findsNWidgets(2));
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(find.text('衢州市消防救援支队'), findsOneWidget);
  });

  testWidgets('离开确认支持继续编辑、保存并离开与持久化', (tester) async {
    await openPage(tester);
    await tester.enterText(find.byType(TextField).first, '测试单位');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('水印设置尚未保存'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('测试单位'), findsNWidgets(2));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并离开'));
    await tester.pumpAndSettle();
    expect((await WatermarkSettings.load()).unitTitle, '测试单位');
    expect(find.text('打开设置'), findsOneWidget);
  });

  testWidgets('放弃修改不写入本地', (tester) async {
    await openPage(tester);
    await tester.enterText(find.byType(TextField).first, '未保存单位');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect((await WatermarkSettings.load()).unitTitle, isEmpty);
    expect(find.text('打开设置'), findsOneWidget);
  });

  testWidgets('天气开关联动预览并保存', (tester) async {
    await openPage(tester);
    final tile = find.widgetWithText(SwitchListTile, '天气');
    await tester.scrollUntilVisible(
      tile,
      240,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(tile);
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect((await WatermarkSettings.load()).showWeather, isFalse);
    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(find.text('晴 21℃ 东南风2级 湿度87%'), findsNothing);
  });

  testWidgets('没有登录单位时明确提示抬头缺失', (tester) async {
    await openPage(tester, unitName: '');
    expect(find.text('未填写单位抬头'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '临时支援单位');
    await tester.pump();
    expect(find.text('临时支援单位'), findsNWidgets(2));
  });

  testWidgets('预览蓝条白字对比度至少 4.5', (tester) async {
    await openPage(tester);
    final title = tester.widget<Text>(find.text('衢州市消防救援支队'));
    final bar = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('衢州市消防救援支队'),
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.color != null,
            ),
          )
          .first,
    );
    final foreground = title.style!.color!.computeLuminance();
    final background = bar.color!.computeLuminance();
    expect(
      (foreground + 0.05) / (background + 0.05),
      greaterThanOrEqualTo(4.5),
    );
  });

  for (final scale in [1.5, 2.0]) {
    testWidgets('320dp 字号 $scale 全页无溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await openPage(tester, scale: scale);
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
      await tester.enterText(
        find.byType(TextField).first,
        '很长的单位名称用于确认顶部蓝条在大字号下能够换行显示全部文字',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (var i = 0; i < 14; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -250));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      final title = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == '很长的单位名称用于确认顶部蓝条在大字号下能够换行显示全部文字',
        ),
      );
      expect(title.maxLines, isNull);
      expect(title.overflow, isNot(TextOverflow.ellipsis));
      expect(tester.takeException(), isNull);
    });
  }
}
