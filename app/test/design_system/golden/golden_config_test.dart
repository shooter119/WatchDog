import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flutter_test_config.dart' show TolerantGoldenFileComparator;

Future<Uint8List> _render100x10PngBytes(int diffPixels) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, 100, 10));
  final bgPaint = Paint()
    ..color = const Color(0xFF000000)
    ..isAntiAlias = false;
  canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 10), bgPaint);

  final fgPaint = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..isAntiAlias = false;
  for (var i = 0; i < diffPixels; i++) {
    canvas.drawRect(
      Rect.fromLTWH((i % 100).toDouble(), (i ~/ 100).toDouble(), 1, 1),
      fgPaint,
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(100, 10);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('Failed to encode 100x10 test PNG.');
    }
    return byteData.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets(
    'flutter_test_config keeps TolerantGoldenFileComparator active in golden/',
    (WidgetTester tester) async {
      expect(goldenFileComparator, isA<TolerantGoldenFileComparator>());
      expect(goldenFileComparator.runtimeType, TolerantGoldenFileComparator);
      final local = goldenFileComparator as LocalFileComparator;
      expect(
        local.basedir.path.replaceAll(r'\', '/'),
        endsWith('test/design_system/golden/'),
      );
    },
  );

  testWidgets(
    'active TolerantGoldenFileComparator passes 0.4%/0.5% diff and throws on 0.6%',
    (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'watchdog_golden_cfg_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final baseFile = File('${tempDir.path}/base.png');
      late Uint8List diff4Bytes;
      late Uint8List diff5Bytes;
      late Uint8List diff6Bytes;

      await tester.runAsync(() async {
        final baseBytes = await _render100x10PngBytes(0);
        diff4Bytes = await _render100x10PngBytes(4);
        diff5Bytes = await _render100x10PngBytes(5);
        diff6Bytes = await _render100x10PngBytes(6);

        await baseFile.writeAsBytes(baseBytes, flush: true);

        final r4 = await GoldenFileComparator.compareLists(diff4Bytes, baseBytes);
        try {
          expect(r4.passed, isFalse);
          expect(r4.diffPercent, closeTo(0.004, 1e-9));
        } finally {
          r4.dispose();
        }

        final r5 = await GoldenFileComparator.compareLists(diff5Bytes, baseBytes);
        try {
          expect(r5.passed, isFalse);
          expect(r5.diffPercent, closeTo(0.005, 1e-9));
        } finally {
          r5.dispose();
        }

        final r6 = await GoldenFileComparator.compareLists(diff6Bytes, baseBytes);
        try {
          expect(r6.passed, isFalse);
          expect(r6.diffPercent, closeTo(0.006, 1e-9));
        } finally {
          r6.dispose();
        }

        if (!autoUpdateGoldenFiles) {
          // 0) 对照组：普通 LocalFileComparator 面对 0.4% (4/1000) 差异必定抛出 FlutterError。
          final strictComparator = LocalFileComparator(
            tempDir.uri.resolve('probe_test.dart'),
          );
          await expectLater(
            strictComparator.compare(diff4Bytes, Uri.parse('base.png')),
            throwsA(isA<FlutterError>()),
          );

          // 1) 直接验证测试体内活跃的 goldenFileComparator（由 flutter_test_config.dart 安装）
          //    能够放行 0.4% (4/1000) 与 0.5% (5/1000) 差异，而不会误报。
          expect(
            await goldenFileComparator.compare(diff4Bytes, baseFile.uri),
            isTrue,
          );
          expect(
            await goldenFileComparator.compare(diff5Bytes, baseFile.uri),
            isTrue,
          );

          // 2) 使用隔离到 tempDir 的同款比较器验证 0.6% (6/1000) 必定抛出 FlutterError，
          //    避免在仓库 test/design_system/golden/failures/ 下遗留失败产物。
          final isolatedComparator = TolerantGoldenFileComparator(
            tempDir.uri.resolve('probe_test.dart'),
            precisionTolerance: 0.005,
          );
          expect(
            await isolatedComparator.compare(diff4Bytes, Uri.parse('base.png')),
            isTrue,
          );
          expect(
            await isolatedComparator.compare(diff5Bytes, Uri.parse('base.png')),
            isTrue,
          );
          await expectLater(
            isolatedComparator.compare(diff6Bytes, Uri.parse('base.png')),
            throwsA(isA<FlutterError>()),
          );
        }
      });

      if (!autoUpdateGoldenFiles) {
        // 3) 端到端通过 matchesGoldenFile 走完整 flutter_test 黄金断言链路验证 0.4% 放行。
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, 100, 10));
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 100, 10),
          Paint()
            ..color = const Color(0xFF000000)
            ..isAntiAlias = false,
        );
        for (var i = 0; i < 4; i++) {
          canvas.drawRect(
            Rect.fromLTWH(i.toDouble(), 0, 1, 1),
            Paint()
              ..color = const Color(0xFFFFFFFF)
              ..isAntiAlias = false,
          );
        }
        final picture = recorder.endRecording();
        final image4 = await tester.runAsync(() => picture.toImage(100, 10));
        addTearDown(() {
          image4?.dispose();
          picture.dispose();
        });
        await expectLater(image4, matchesGoldenFile(baseFile.uri));
      }
    },
  );
}
