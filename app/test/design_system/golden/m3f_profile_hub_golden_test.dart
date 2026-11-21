@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/settings/state/settings_store.dart';
import 'package:watchdog/features/settings/ui/profile_hub_page.dart';

Future<void> _pumpGolden(
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
        home: RepaintBoundary(key: captureKey, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SettingsStore _buildGoldenStore(Brightness brightness) {
  final themeId = brightness == Brightness.dark ? 'night-tactical' : 'daylight';
  return SettingsStore(
    gateway: SettingsGateway(
      isDebugMode: false,
      readThemeId: () => themeId,
      readRuntimeVersion: () async => '1.22.0+113',
      checkPolicyAccess: () async => true,
    ),
    identity: const SettingsIdentitySnapshot(
      authenticated: true,
      realName: '张三',
      unitName: '示例县消防救援大队 · 示例路站',
      userRole: 'admin',
      canScanAdmin: true,
      canReviewMembers: true,
      pendingMemberCount: 2,
      offlineReviewCount: 1,
      hasApi: true,
    ),
    connection: const SettingsConnectionSnapshot(
      connectionLost: false,
      syncing: false,
    ),
    update: const SettingsUpdateSnapshot(checkDone: true),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const screenChannel = MethodChannel('watchdog/screen');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'unit_id': 'unit-demo',
      'unit_name': '示例县消防救援大队 · 示例路站',
      'real_name': '张三',
      'user_role': 'admin',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, null);
  });

  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3f ProfileHubPage ($themeTag)', (WidgetTester tester) async {
      final captureKey = GlobalKey();
      final store = _buildGoldenStore(brightness);
      addTearDown(store.dispose);

      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: ProfileHubPage(
          store: store,
          autoLoad: false,
          routes: ProfileHubRoutes(
            onOpenVideoAdmin: (_) async {},
            onOpenMemberReview: (_) async {},
            onOpenRoster: (_) async {},
            onOpenUnitStations: (_) async {},
            onOpenArchivedIncidents: (_) async {},
            onOpenStats: (_) async {},
            onOpenLoginDevices: (_) async {},
            onOpenOfflineReview: (_) async {},
            onOpenAdminScanner: (_) async {},
          ),
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3f_profile_hub_$themeTag.png'),
      );
    });
  }
}
