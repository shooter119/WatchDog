import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 仅作用于 `test/design_system/golden/` 子目录的黄金截图测试配置。
///
/// 配置 0.5% (`0.005`) 像素差异容差，兼容 macOS 与 Linux CI 间的抗锯齿与阴影微差。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final GoldenFileComparator previousComparator = goldenFileComparator;
  if (previousComparator is LocalFileComparator) {
    goldenFileComparator = TolerantGoldenFileComparator(
      previousComparator.basedir.resolve('flutter_test_config.dart'),
      precisionTolerance: 0.005,
    );
  }
  await testMain();
}

/// 带像素容差的黄金截图比较器，兼容跨平台抗锯齿与阴影渲染微差。
class TolerantGoldenFileComparator extends LocalFileComparator {
  TolerantGoldenFileComparator(
    super.testFile, {
    required double precisionTolerance,
  })  : assert(
          0.0 <= precisionTolerance && precisionTolerance <= 1.0,
          'precisionTolerance must be between 0.0 and 1.0',
        ),
        _precisionTolerance = precisionTolerance;

  final double _precisionTolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    if (autoUpdateGoldenFiles) {
      await update(golden, imageBytes);
      return true;
    }

    final ComparisonResult result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    try {
      if (result.passed || result.diffPercent <= _precisionTolerance) {
        return true;
      }
      final String error = await generateFailureOutput(result, golden, basedir);
      throw FlutterError(error);
    } finally {
      result.dispose();
    }
  }
}
