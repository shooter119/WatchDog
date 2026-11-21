import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';

Future<void> _pumpPrototypeGolden(
  WidgetTester tester, {
  required Brightness brightness,
  required GlobalKey captureKey,
  required Widget child,
}) async {
  const surfaceSize = Size(390, 844);
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(
          key: captureKey,
          child: child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('CommandHomePreview ($themeTag)',
        (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpPrototypeGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: const CommandHomePreview(),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_proto_command_home_$themeTag.png'),
      );
    });

    testWidgets('MonitorPreview ($themeTag)', (WidgetTester tester) async {
      final captureKey = GlobalKey();
      await _pumpPrototypeGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: const MonitorPreview(liveTick: false),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/ds_proto_monitor_$themeTag.png'),
      );
    });
  }
}
