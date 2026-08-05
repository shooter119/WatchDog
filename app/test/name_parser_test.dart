import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/pages/roster_page.dart';

void main() {
  group('extractNamesFromPaste', () {
    test('每行一个姓名', () {
      expect(
        extractNamesFromPaste('李翔\n盛承华\n徐琴琴'),
        ['李翔', '盛承华', '徐琴琴'],
      );
    });

    test('两字姓名中间带空格', () {
      expect(extractNamesFromPaste('李  翔\n柯  峰'), ['李翔', '柯峰']);
    });

    test('整表复制取每行第一个单元格', () {
      const paste = '林成成\t站长\t初级专职消防员\n'
          '程晓波\t站长助理\t初级专职消防员\n'
          '郭逸\t站长助理\t初级专职消防员';
      expect(extractNamesFromPaste(paste), ['林成成', '程晓波', '郭逸']);
    });

    test('姓名与职务混排只取姓名', () {
      expect(extractNamesFromPaste('盛承华 大队长\n徐琴琴 会计助理员'), ['盛承华', '徐琴琴']);
    });

    test('四字少数民族姓名', () {
      expect(extractNamesFromPaste('甲巴 有拉\n吉布 小夫'), ['甲巴有拉', '吉布小夫']);
    });

    test('过滤职务词与无效行', () {
      expect(
        extractNamesFromPaste('站长\n战斗员\n实习\n2025.04\n李  翔\n'),
        ['李翔'],
      );
    });

    test('空文本与空白行', () {
      expect(extractNamesFromPaste('   \n\n\t'), isEmpty);
    });
  });
}
