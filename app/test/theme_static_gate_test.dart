import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 静态门禁：主题色不能在 `const` 上下文或 `static final` 字段里被固化。
///
/// 编译器能抓住 `const` 报错，但抓不住 `static final` 缓存的旧颜色；
/// 这条测试把两条都用文本门禁锁住，防止以后又有人写出"切主题不生效"。
void main() {
  test('lib 中不得把 AppColors 固化到 const 上下文或静态字段', () {
    final offenders = <String>[];
    final constPattern = RegExp(r'\bconst\b[^;\n]*AppColors\.');
    final staticPattern = RegExp(
      r'static\s+(?:final|const|late\s+final)[^;\n]*AppColors\.',
    );

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final code = line.trimLeft();
        // 跳过注释行（文档里可能举例说明反模式）。
        if (code.startsWith('//') || code.startsWith('///')) continue;
        if (constPattern.hasMatch(line)) {
          offenders.add('${entity.path}:${i + 1} const 上下文');
        }
        if (staticPattern.hasMatch(line)) {
          offenders.add('${entity.path}:${i + 1} 静态字段');
        }
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
