import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/core/models/amap_location.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/map/ui/location_share_sheet.dart';
import 'package:watchdog/features/media/data/models/weather_info.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/services/settings.dart';

DateTime get _now => DateTime(2026, 10, 21, 10, 30);

const _amapLocation = AmapLocation(
  lat: 30.25678,
  lon: 120.12345,
  coordinate: 'gcj02',
);

LocationShareDraft _draft({double accuracy = 8, int ageMinutes = 0}) {
  return LocationShareDraft(
    incidentName: '示例仓库火灾',
    unitName: '示例县消防救援大队',
    address: '示例省示例市示例县示范路1号',
    locatedAt: _now.subtract(Duration(minutes: ageMinutes)),
    lat: 30.25,
    lon: 120.12,
    accuracyMeters: accuracy,
    amapLocation: _amapLocation,
  );
}

class _GatewayHarness {
  bool permitted = true;
  bool serviceEnabled = true;
  bool locationAvailable = true;
  int appSettingsOpened = 0;
  int locationSettingsOpened = 0;
  final copied = <String>[];
  final shared = <String>[];
  WeatherInfo weather = const WeatherInfo(
    address: '示例省示例市示例县示范路1号',
    line: '阴 · 25℃',
    amapLocation: _amapLocation,
  );
  int ageMs = 10_000;

  late final gateway = LocationShareGateway(
    requestPermission: () async => permitted,
    locationServiceEnabled: () async => serviceEnabled,
    currentLocation: () async {
      if (!locationAvailable) return null;
      return LocationFix(
        lat: 30.25,
        lon: 120.12,
        accuracyMeters: 8,
        provider: 'gps',
        ageMs: ageMs,
      );
    },
    fetchWeather: (_, _) async => weather,
    openAppSettings: () async => appSettingsOpened++,
    openLocationSettings: () async => locationSettingsOpened++,
    copyText: (text) async => copied.add(text),
    shareText: (text) async => shared.add(text),
    now: () => _now,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('分享链接与纯文本文案格式符合契约', () {
    final draft = _draft();
    expect(draft.hasAmapLocation, isTrue);
    expect(draft.markerUri.host, 'uri.amap.com');
    expect(draft.markerUri.queryParameters['coordinate'], 'gaode');

    final text = draft.toShareText(now: _now);
    expect(text, contains('警情：示例仓库火灾'));
    expect(text, contains('查看位置：'));
    expect(text, isNot(contains('驾车导航：')));
  });

  testWidgets('复制与分享使用同一完整文案，并只提示系统分享已打开', (tester) async {
    await Settings.setUnitName('示例县消防救援大队');
    final harness = _GatewayHarness();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(
          body: LocationShareSheet(
            gateway: harness.gateway,
            readIncidentName: () => '示例仓库火灾',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('定位分享'), findsOneWidget);
    expect(find.text('示例仓库火灾'), findsWidgets);
    expect(find.text('示例省示例市示例县示范路1号'), findsOneWidget);

    await tester.tap(find.byKey(const Key('location-share-copy')));
    await tester.pump();
    expect(harness.copied, hasLength(1));
    expect(find.text('完整文案已复制'), findsOneWidget);

    await tester.tap(find.byKey(const Key('location-share-submit')));
    await tester.pump();
    expect(harness.shared.single, harness.copied.single);
    expect(find.text('已打开系统分享'), findsOneWidget);
  });

  testWidgets('权限被拒、定位关闭与未获取到定位分别提供恢复路径', (tester) async {
    final denied = _GatewayHarness()..permitted = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(body: LocationShareSheet(gateway: denied.gateway)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('定位权限未授权'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-share-app-settings')));
    await tester.pump();
    expect(denied.appSettingsOpened, 1);

    final disabled = _GatewayHarness()..serviceEnabled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(
          body: LocationShareSheet(
            key: const ValueKey('disabled'),
            gateway: disabled.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('定位服务未开启'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-share-open-settings')));
    await tester.pump();
    expect(disabled.locationSettingsOpened, 1);

    final unavailable = _GatewayHarness()..locationAvailable = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(
          body: LocationShareSheet(
            key: const ValueKey('unavailable'),
            gateway: unavailable.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未获取到定位'), findsOneWidget);
  });

  testWidgets('地址失败降级 WGS84 单链接，超 2 分钟警告，超 5 分钟禁用复制与分享', (tester) async {
    final degraded = _GatewayHarness()..weather = WeatherInfo.empty;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(body: LocationShareSheet(gateway: degraded.gateway)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('地址暂不可用'), findsOneWidget);
    expect(find.textContaining('已切换为 WGS84 坐标，仍可分享查看位置'), findsOneWidget);

    final warning = _GatewayHarness()..ageMs = 3 * 60 * 1000;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(
          body: LocationShareSheet(
            key: const ValueKey('warn'),
            gateway: warning.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('定位已超过 2 分钟'), findsOneWidget);
    expect(
      tester
          .widget<CommandButton>(find.byKey(const Key('location-share-submit')))
          .enabled,
      isTrue,
    );

    final blocked = _GatewayHarness()..ageMs = 6 * 60 * 1000;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: Scaffold(
          body: LocationShareSheet(
            key: const ValueKey('blocked'),
            gateway: blocked.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('定位已超过 5 分钟'), findsOneWidget);
    expect(
      tester
          .widget<CommandButton>(find.byKey(const Key('location-share-submit')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<CommandButton>(find.byKey(const Key('location-share-copy')))
          .enabled,
      isFalse,
    );
  });

  testWidgets('360dp @ 130% 字号昼白/暗曜零溢出且操作按钮高度 >= 48dp', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final brightness in Brightness.values) {
      final harness = _GatewayHarness()..ageMs = 10 * 1000;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: LocationShareSheet(
              key: ValueKey('scale-$brightness'),
              gateway: harness.gateway,
              readIncidentName: () => '示例仓库火灾',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scrollable), findsWidgets);
      expect(
        tester.getSize(find.byKey(const Key('location-share-copy'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const Key('location-share-submit'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
    }
  });
}
