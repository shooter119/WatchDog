import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/location_share_sheet.dart';
import 'package:watchdog/services/camera_bridge.dart';
import 'package:watchdog/services/location_share_service.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

DateTime get _now => DateTime(2026, 10, 21, 10, 30);

const _amapLocation = AmapLocation(
  lat: 29.03036,
  lon: 119.18042,
  coordinate: 'gcj02',
);

LocationShareDraft _draft({double accuracy = 8, int ageMinutes = 0}) {
  return LocationShareDraft(
    incidentName: '龙翔路仓库火灾',
    unitName: '龙游县消防救援大队',
    address: '浙江省衢州市龙游县东华街道鸡鸣路146号',
    locatedAt: _now.subtract(Duration(minutes: ageMinutes)),
    lat: 29.03,
    lon: 119.18,
    accuracyMeters: accuracy,
    amapLocation: _amapLocation,
  );
}

class _GatewayHarness {
  bool permitted = true;
  bool serviceEnabled = true;
  bool locationAvailable = true;
  int permissionRequests = 0;
  int currentLocationRequests = 0;
  int appSettingsOpened = 0;
  int locationSettingsOpened = 0;
  final copied = <String>[];
  final shared = <String>[];
  WeatherInfo weather = const WeatherInfo(
    address: '浙江省衢州市龙游县东华街道鸡鸣路146号',
    line: '阴 · 25℃',
    amapLocation: _amapLocation,
  );
  int ageMs = 10_000;

  late final gateway = LocationShareGateway(
    requestPermission: () async {
      permissionRequests++;
      return permitted;
    },
    locationServiceEnabled: () async => serviceEnabled,
    currentLocation: () async {
      currentLocationRequests++;
      if (!locationAvailable) return null;
      return LocationFix(
        lat: 29.03,
        lon: 119.18,
        accuracyMeters: 8,
        provider: 'gps',
        ageMs: ageMs,
      );
    },
    fetchWeather: (_, _) async => weather,
    openAppSettings: () async {
      appSettingsOpened++;
    },
    openLocationSettings: () async {
      locationSettingsOpened++;
    },
    copyText: (text) async {
      copied.add(text);
    },
    shareText: (text) async {
      shared.add(text);
    },
    now: () => _now,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('分享链接使用正确经纬度顺序和降级规则', () {
    final draft = _draft();
    expect(draft.markerUri.host, 'uri.amap.com');
    expect(draft.markerUri.path, '/marker');
    expect(draft.markerUri.queryParameters['position'], '119.180000,29.030000');
    expect(draft.markerUri.queryParameters['coordinate'], 'wgs84');
    expect(draft.markerUri.queryParameters['src'], 'watchdog');
    expect(draft.markerUri.queryParameters['callnative'], '0');

    final navigation = draft.navigationUri!;
    expect(navigation.path, '/navigation');
    expect(navigation.queryParameters['from'], '');
    expect(navigation.queryParameters['to'], '119.180420,29.030360,龙翔路仓库火灾');
    expect(navigation.queryParameters.containsKey('coordinate'), isFalse);
    expect(navigation.queryParameters['src'], 'watchdog');
    expect(navigation.queryParameters['callnative'], '0');

    final degraded = LocationShareDraft(
      incidentName: draft.incidentName,
      unitName: draft.unitName,
      address: '',
      locatedAt: draft.locatedAt,
      lat: draft.lat,
      lon: draft.lon,
      accuracyMeters: draft.accuracyMeters,
      amapLocation: null,
    );
    expect(degraded.navigationUri, isNull);
    expect(degraded.markerUri.toString(), contains('coordinate=wgs84'));
  });

  test('分享文案按固定顺序输出、链接独立成行且不包含发送人', () {
    final text = _draft().toShareText(now: _now);
    final fields = [
      '警情：龙翔路仓库火灾',
      '单位：龙游县消防救援大队',
      '位置：浙江省衢州市龙游县东华街道鸡鸣路146号',
      '时间：2026-10-21 10:30',
      '精度：约 8.0 米',
      'WGS84：29.030000, 119.180000',
      '查看位置：',
      'https://uri.amap.com/marker?',
      '驾车导航：',
      'https://uri.amap.com/navigation?',
    ];
    var previous = -1;
    for (final field in fields) {
      final index = text.indexOf(field);
      expect(index, greaterThan(previous), reason: field);
      previous = index;
    }
    expect(text, isNot(contains('发送人')));
    expect(text, isNot(contains('姓名')));
    expect('coordinate=wgs84'.allMatches(text), hasLength(1));
  });

  test('天气响应防御性解析高德坐标字段', () {
    final info = WeatherInfo.fromJson({
      'address': '测试地址',
      'line': '晴 · 28℃',
      'amapLocation': {
        'lat': 29.03036,
        'lon': 119.18042,
        'coordinate': 'gcj02',
      },
      'coordinateDegraded': false,
      'degraded': false,
    });
    expect(info.address, '测试地址');
    expect(info.amapLocation?.lat, 29.03036);
    expect(info.amapLocation?.lon, 119.18042);
    expect(info.amapLocation?.coordinate, 'gcj02');
    expect(info.coordinateDegraded, isFalse);
    expect(WeatherInfo.fromJson({'amapLocation': 'bad'}).amapLocation, isNull);
  });

  testWidgets('复制与分享使用同一完整文案，并只提示系统分享已打开', (tester) async {
    await Settings.setUnitName('龙游县消防救援大队');
    final harness = _GatewayHarness();
    final controller = AppController()
      ..currentIncident = const Incident(
        id: 'i1',
        number: '2026-10-21-001',
        title: '龙翔路仓库火灾',
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LocationShareSheet(
            controller: controller,
            gateway: harness.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('定位分享'), findsOneWidget);
    expect(find.text('龙翔路仓库火灾'), findsWidgets);
    expect(find.text('浙江省衢州市龙游县东华街道鸡鸣路146号'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-share-copy')));
    await tester.pump();
    expect(harness.copied, hasLength(1));
    expect(harness.copied.single, contains('查看位置：'));
    expect(find.text('完整文案已复制'), findsOneWidget);

    await tester.tap(find.byKey(const Key('location-share-submit')));
    await tester.pump();
    expect(harness.shared.single, harness.copied.single);
    expect(find.text('已打开系统分享'), findsOneWidget);
    expect(find.textContaining('微信已收到'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('权限被拒提供重新申请和应用设置恢复路径', (tester) async {
    final harness = _GatewayHarness()..permitted = false;
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LocationShareSheet(
            controller: controller,
            gateway: harness.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('定位权限未授权'), findsOneWidget);
    expect(find.text('重新申请定位权限'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-share-app-settings')));
    await tester.pump();
    expect(harness.appSettingsOpened, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('系统定位关闭时提供定位设置入口', (tester) async {
    final harness = _GatewayHarness()..serviceEnabled = false;
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LocationShareSheet(
            controller: controller,
            gateway: harness.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('定位服务未开启'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-share-open-settings')));
    await tester.pump();
    expect(harness.locationSettingsOpened, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('地址失败仍可分享 WGS84，高德坐标缺失时隐藏导航', (tester) async {
    final harness = _GatewayHarness()..weather = WeatherInfo.empty;
    final controller = AppController()
      ..currentIncident = const Incident(
        id: 'i1',
        number: '编号',
        title: '测试警情',
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LocationShareSheet(
            controller: controller,
            gateway: harness.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('地址暂不可用'), findsOneWidget);
    expect(find.textContaining('仍可分享 WGS84 查看位置；驾车导航已隐藏'), findsOneWidget);
    expect(find.textContaining('驾车导航：\n'), findsNothing);
    expect(find.byKey(const Key('location-share-copy')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('超过两分钟提示风险，超过五分钟禁止复制和分享', (tester) async {
    final warningHarness = _GatewayHarness()..ageMs = 3 * 60 * 1000;
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LocationShareSheet(
            controller: controller,
            gateway: warningHarness.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('定位已超过 2 分钟'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('location-share-submit')))
          .onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox());
    final blockedHarness = _GatewayHarness()..ageMs = 6 * 60 * 1000;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LocationShareSheet(
            controller: controller,
            gateway: blockedHarness.gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('定位已超过 5 分钟'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('location-share-submit')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('location-share-copy')))
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('短屏 1.3 倍字体保持可滚动且操作按钮高度不少于 48', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = _GatewayHarness()..ageMs = 10 * 1000;
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: LocationShareSheet(
            controller: controller,
            gateway: harness.gateway,
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

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
