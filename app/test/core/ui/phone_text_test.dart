import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/ui/phone_text.dart';
import 'package:watchdog/design_system/design_system.dart';

Widget _wrapWithDs(
  Widget child, {
  Brightness brightness = Brightness.light,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    themeAnimationDuration: Duration.zero,
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('core/ui/PhoneText 渲染与拨号交互', () {
    testWidgets('无号码文本渲染为纯 Text 且不显示呼叫图标', (tester) async {
      await tester.pumpWidget(
        _wrapWithDs(const PhoneText('示例路站现场一切正常，无需支援')),
      );

      expect(find.text('示例路站现场一切正常，无需支援'), findsOneWidget);
      expect(find.byIcon(DsIcons.phone), findsNothing);
    });

    testWidgets('包含手机号时按当前 DS 主题色高亮并支持点击图标和号码文本拨号', (
      tester,
    ) async {
      final dialed = <Uri>[];

      await tester.pumpWidget(
        _wrapWithDs(
          PhoneText(
            '请联系现场联络员张三 13912345678 尽快对接',
            phoneLauncher: (uri) async {
              dialed.add(uri);
              return true;
            },
          ),
        ),
      );

      final iconFinder = find.byIcon(DsIcons.phone);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.color, DsColors.daylight.brandText);

      // 校验富文本中的高亮号码 span 样式及手势识别器
      final richText = tester.widget<Text>(find.byType(Text));
      final rootSpan = richText.textSpan! as TextSpan;
      final phoneSpan = rootSpan.children!
          .whereType<TextSpan>()
          .singleWhere((s) => s.text == '13912345678');
      expect(phoneSpan.style?.color, DsColors.daylight.brandText);
      expect(phoneSpan.style?.decoration, TextDecoration.underline);
      expect(phoneSpan.style?.fontWeight, FontWeight.w600);
      expect(
        phoneSpan.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(phoneSpan.recognizer, isA<TapGestureRecognizer>());

      // 1. 点击呼叫小图标触发拨号
      await tester.tap(iconFinder);
      await tester.pumpAndSettle();
      expect(dialed, hasLength(1));
      expect(dialed.last.toString(), 'tel:13912345678');

      // 2. 点击高亮号码文本触发拨号
      (phoneSpan.recognizer! as TapGestureRecognizer).onTap?.call();
      await tester.pumpAndSettle();
      expect(dialed, hasLength(2));
      expect(dialed.last.toString(), 'tel:13912345678');
    });

    testWidgets('支持带区号固话与多号码识别，且按清洗后号码拨打', (tester) async {
      final dialed = <Uri>[];

      await tester.pumpWidget(
        _wrapWithDs(
          PhoneText(
            '值班室 010-88889999，备用 +8613800138000',
            phoneLauncher: (uri) async {
              dialed.add(uri);
              return true;
            },
          ),
        ),
      );

      final icons = find.byIcon(DsIcons.phone);
      expect(icons, findsNWidgets(2));

      await tester.tap(icons.first);
      await tester.pumpAndSettle();
      expect(dialed.last.toString(), 'tel:01088889999');

      await tester.tap(icons.last);
      await tester.pumpAndSettle();
      expect(dialed.last.toString(), 'tel:+8613800138000');
    });

    testWidgets('showCallIcon 为 false 时隐藏图标但保留高亮与点击拨号', (tester) async {
      Uri? dialedUri;

      await tester.pumpWidget(
        _wrapWithDs(
          PhoneText(
            '联系 13912345678',
            showCallIcon: false,
            phoneLauncher: (uri) async {
              dialedUri = uri;
              return true;
            },
          ),
        ),
      );

      expect(find.byIcon(DsIcons.phone), findsNothing);
      final richText = tester.widget<Text>(find.byType(Text));
      final rootSpan = richText.textSpan! as TextSpan;
      final phoneSpan = rootSpan.children!
          .whereType<TextSpan>()
          .singleWhere((s) => s.text == '13912345678');

      (phoneSpan.recognizer! as TapGestureRecognizer).onTap?.call();
      await tester.pumpAndSettle();
      expect(dialedUri?.toString(), 'tel:13912345678');
    });

    testWidgets('长按呼叫图标复制号码到剪贴板并弹出提示', (tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map<dynamic, dynamic>)['text']
                as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(_wrapWithDs(const PhoneText('值班电话 13912345678')));

      await tester.longPress(find.byIcon(DsIcons.phone));
      await tester.pump();

      expect(copiedText, '13912345678');
      expect(find.text('已复制号码: 13912345678'), findsOneWidget);
    });

    testWidgets('切换暗曜主题与更新为无号码文本时动态响应且无异常', (tester) async {
      await tester.pumpWidget(
        _wrapWithDs(
          const PhoneText('值班电话 13912345678'),
          brightness: Brightness.dark,
        ),
      );

      final darkIcon = tester.widget<Icon>(
        find.byIcon(DsIcons.phone),
      );
      expect(darkIcon.color, DsColors.night.brandText);

      // 切换为无号码文本后应移除呼叫图标并安全清理手势识别器
      await tester.pumpWidget(
        _wrapWithDs(
          const PhoneText('已解除警情'),
          brightness: Brightness.dark,
        ),
      );

      expect(find.text('已解除警情'), findsOneWidget);
      expect(find.byIcon(DsIcons.phone), findsNothing);
    });
  });
}
