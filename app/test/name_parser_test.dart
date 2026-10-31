import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/pages/roster_page.dart';

void main() {
  group('extractNamesFromPaste', () {
    test('每行一个姓名', () {
      expect(
        extractNamesFromPaste('张伟\n李娜\n赵磊'),
        ['张伟', '李娜', '赵磊'],
      );
    });

    test('两字姓名中间带空格', () {
      expect(extractNamesFromPaste('张  伟\n李  娜'), ['张伟', '李娜']);
    });

    test('整表复制取每行第一个单元格', () {
      const paste = '张伟\t站长\t初级专职消防员\n'
          '李娜\t站长助理\t初级专职消防员\n'
          '赵磊\t站长助理\t初级专职消防员';
      expect(extractNamesFromPaste(paste), ['张伟', '李娜', '赵磊']);
    });

    test('姓名与职务混排只取姓名', () {
      expect(extractNamesFromPaste('张伟 大队长\n李娜 会计助理员'), ['张伟', '李娜']);
    });

    test('四字少数民族姓名', () {
      expect(extractNamesFromPaste('赵钱 孙李\n周吴 郑王'), ['赵钱孙李', '周吴郑王']);
    });

    test('过滤职务词与无效行', () {
      expect(
        extractNamesFromPaste('站长\n战斗员\n实习\n2025.04\n张  伟\n'),
        ['张伟'],
      );
    });

    test('空文本与空白行', () {
      expect(extractNamesFromPaste('   \n\n\t'), isEmpty);
    });
  });
}
