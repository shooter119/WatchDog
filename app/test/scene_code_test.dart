import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/scene_code.dart';

void main() {
  group('场景码词表', () {
    test('与后端 FRUIT_NAMES 一致：30 个两字水果，无重复', () {
      expect(kFruitSceneNames.length, 30);
      expect(kFruitSceneNames.toSet().length, 30);
      for (final f in kFruitSceneNames) {
        expect(f, hasLength(2), reason: '$f 应为两字水果名');
      }
      expect(kFruitSceneNames, contains('苹果'));
      expect(kFruitSceneNames, contains('蜜橘'));
    });
  });

  group('isValidSceneCode 核验', () {
    test('水果词表内通过', () {
      for (final f in kFruitSceneNames) {
        expect(isValidSceneCode(f), isTrue, reason: f);
      }
    });

    test('trim 后匹配', () {
      expect(isValidSceneCode(' 苹果 '), isTrue);
    });

    test('历史 default 兼容', () {
      expect(isValidSceneCode('default'), isTrue);
    });

    test('乱码/任意输入拒绝', () {
      expect(isValidSceneCode('ABC123'), isFalse);
      expect(isValidSceneCode('随便乱写'), isFalse);
      expect(isValidSceneCode(''), isFalse);
      expect(isValidSceneCode('  '), isFalse);
      expect(isValidSceneCode('apple'), isFalse);
      expect(isValidSceneCode('苹果汁'), isFalse);
    });
  });

  group('isPlausibleSceneCode 前置校验', () {
    test('空/纯空格/超长拦截', () {
      expect(isPlausibleSceneCode(''), isFalse);
      expect(isPlausibleSceneCode('   '), isFalse);
      expect(isPlausibleSceneCode('a' * 33), isFalse);
    });

    test('常规输入放行（合法性交给服务器核验）', () {
      expect(isPlausibleSceneCode('苹果'), isTrue);
      expect(isPlausibleSceneCode('ABC123'), isTrue);
      expect(isPlausibleSceneCode('firestation-1'), isTrue);
      expect(isPlausibleSceneCode(' 香蕉 '), isTrue);
    });
  });

  group('generateSceneCode 首装生成', () {
    test('生成结果必在水果词表内', () {
      for (var i = 0; i < 50; i++) {
        expect(kFruitSceneNames, contains(generateSceneCode()));
      }
    });
  });
}
