import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/phone_caller.dart';
import 'package:watchdog/widgets/phone_text.dart';

void main() {
  group('PhoneCaller 基础服务测试', () {
    test('normalizePhone 正确清洗格式符号', () {
      expect(PhoneCaller.normalizePhone(' 138-1234-5678 '), '13812345678');
      expect(PhoneCaller.normalizePhone('0570 - 8888999'), '05708888999');
      expect(PhoneCaller.normalizePhone(''), '');
    });

    test('isValidPhoneNumber 格式有效性判定', () {
      expect(PhoneCaller.isValidPhoneNumber('13812345678'), isTrue);
      expect(PhoneCaller.isValidPhoneNumber('19900001111'), isTrue);
      expect(PhoneCaller.isValidPhoneNumber('05708888999'), isTrue);
      expect(PhoneCaller.isValidPhoneNumber('8888999'), isTrue);
      expect(PhoneCaller.isValidPhoneNumber('123'), isFalse);
      expect(PhoneCaller.isValidPhoneNumber('abc'), isFalse);
    });

    test('dial 调起系统拨号盘', () async {
      Uri? dialedUri;
      final ok = await PhoneCaller.dial(
        null,
        ' 138-1234-5678 ',
        launcher: (uri) async {
          dialedUri = uri;
          return true;
        },
      );

      expect(ok, isTrue);
      expect(dialedUri, isNotNull);
      expect(dialedUri.toString(), 'tel:13812345678');
    });
  });

  group('PhoneText 部件渲染与交互测试', () {
    testWidgets('无号码文本正常渲染为纯 Text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PhoneText('现场一切正常，无需支援'),
          ),
        ),
      );

      expect(find.text('现场一切正常，无需支援'), findsOneWidget);
      expect(find.byIcon(Icons.phone_in_talk_outlined), findsNothing);
    });

    testWidgets('包含手机号时高亮且点击呼叫小图标触发拨号', (tester) async {
      Uri? dialedUri;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhoneText(
              '请联系现场负责人小张 13912345678 尽快对接',
              phoneLauncher: (uri) async {
                dialedUri = uri;
                return true;
              },
            ),
          ),
        ),
      );

      // 文本拆分为富文本，应渲染电话小图标
      expect(find.byIcon(Icons.phone_in_talk_outlined), findsOneWidget);

      // 点击电话小图标
      await tester.tap(find.byIcon(Icons.phone_in_talk_outlined));
      await tester.pumpAndSettle();

      expect(dialedUri, isNotNull);
      expect(dialedUri.toString(), 'tel:13912345678');
    });
  });
}
