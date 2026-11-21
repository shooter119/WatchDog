@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/auth/state/onboarding_flow_store.dart';
import 'package:watchdog/features/auth/ui/unit_auth_page.dart';

Future<void> _pumpGoldenSurface(
  WidgetTester tester, {
  required Brightness brightness,
  required GlobalKey captureKey,
  required Widget child,
  Size surfaceSize = const Size(390, 844),
}) async {
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(key: captureKey, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'unit_name': '示例县消防救援大队',
      'real_name': '张三',
    });
  });

  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3g 单位实名认证页 ($themeTag)', (tester) async {
      final store = OnboardingFlowStore(
        authenticationRequired: true,
        pendingPollInterval: null,
        onAuthenticate: (_, _, _) async {},
        onApply: (_, _, _, {stationName, phone, applyReason}) async =>
            <String, dynamic>{'status': 'pending'},
        onEnterGuestMode: () async {},
      );
      addTearDown(store.dispose);
      await store.hydrate();

      final captureKey = GlobalKey();
      await _pumpGoldenSurface(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: UnitAuthPage(store: store),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3g_unit_auth_$themeTag.png'),
      );
    });
  }
}
