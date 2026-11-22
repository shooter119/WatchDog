import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/app/shell/incident_address_locator.dart';
import 'package:watchdog/models/admin_login.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/realtime_sync_client.dart';
import 'package:watchdog/services/scoped_json_cache.dart';
import 'package:watchdog/state/app_controller.dart';

class _NoopRealtimeClient extends RealtimeClient {
  _NoopRealtimeClient({
    required super.api,
    required super.onMessage,
    super.onError,
    super.onDone,
  });

  @override
  bool get connected => false;

  @override
  Future<void> connect({
    required String unitCursor,
    required String incidentCursor,
    String? incidentId,
  }) async {}

  @override
  Future<void> disconnect() async {}
}

class _IncidentInfoFakeApi extends ApiClient {
  _IncidentInfoFakeApi()
    : super(
        baseUrl: 'https://api.fireman119.xyz',
        incidentId: '',
        sessionToken: 'session-token',
        deviceId: 'dev-test',
        actorName: '张三',
        unitId: 'unit-1',
        unitCode: '1001',
      );

  bool failTitleFollowup = false;
  bool failDetailsFollowup = false;
  bool failWeather = false;
  WeatherInfo? nextWeather;

  String? updatedTitleArg;
  int? updatedTitleExpectedVersion;
  Map<String, dynamic>? updatedDetailsData;
  int? updatedDetailsExpectedVersion;

  Incident _stored = const Incident(
    id: 'inc-new-1',
    number: '20261122-001',
    title: null,
    status: 'active',
    createdAt: 1700000000000,
    lastActivityAt: 1700000000000,
    version: 1,
    info: <String, dynamic>{},
  );
  int _detailVersion = 0;

  @override
  ApiClient forIncident(String id) => this;

  @override
  Future<Incident> createIncident({
    required String realName,
    String? opId,
  }) async {
    _stored = const Incident(
      id: 'inc-new-1',
      number: '20261122-001',
      title: null,
      status: 'active',
      createdAt: 1700000000000,
      lastActivityAt: 1700000000000,
      version: 1,
      info: <String, dynamic>{},
    );
    _detailVersion = 0;
    return _stored;
  }

  @override
  Future<Incident> updateIncidentTitle(
    String id,
    String? title, {
    required int expectedVersion,
  }) async {
    if (failTitleFollowup) throw Exception('title update error');
    updatedTitleArg = title;
    updatedTitleExpectedVersion = expectedVersion;
    _stored = Incident(
      id: _stored.id,
      number: _stored.number,
      title: title,
      status: _stored.status,
      createdAt: _stored.createdAt,
      lastActivityAt: _stored.lastActivityAt,
      version: _stored.version + 1,
      info: _stored.info,
    );
    return _stored;
  }

  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() async => <String, dynamic>{
    'data': Map<String, dynamic>.from(_stored.info),
    'version': _detailVersion,
  };

  @override
  Future<Map<String, dynamic>> updateIncidentDetails(
    Map<String, dynamic> data,
    int version,
    String opId,
  ) async {
    if (failDetailsFollowup) throw Exception('details update error');
    updatedDetailsData = Map<String, dynamic>.from(data);
    updatedDetailsExpectedVersion = version;
    _detailVersion = version + 1;
    _stored = Incident(
      id: _stored.id,
      number: _stored.number,
      title: _stored.title,
      status: _stored.status,
      createdAt: _stored.createdAt,
      lastActivityAt: _stored.lastActivityAt,
      version: _stored.version,
      info: <String, dynamic>{..._stored.info, ...data},
    );
    return <String, dynamic>{'ok': true, 'version': _detailVersion};
  }

  @override
  Future<Incident> fetchIncident(String id) async => _stored;

  @override
  Future<WeatherInfo> fetchWeather({
    required double lat,
    required double lon,
  }) async {
    if (failWeather) throw Exception('weather upstream failed');
    return nextWeather ??
        const WeatherInfo(
          address: '示例市示例区示范大道188号',
          amapLocation: AmapLocation(lat: 31.234567, lon: 121.456789),
        );
  }

  @override
  Future<Map<String, dynamic>> fetchSyncBootstrap({
    String? forIncidentId,
  }) async => <String, dynamic>{
    'cursors': const <String, dynamic>{'unit': '1', 'incident': '1'},
    'unit': const <String, dynamic>{'id': 'unit-1', 'name': '示例市消防救援大队'},
    'roster': const <String, dynamic>{
      'firefighters': <dynamic>[],
      'hotwords': <dynamic>[],
    },
    'stations': const <dynamic>[],
    'active_incidents': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': _stored.id,
        'number': _stored.number,
        'title': _stored.title,
        'status': _stored.status,
        'created_at': _stored.createdAt,
        'last_activity_at': _stored.lastActivityAt,
        'version': _stored.version,
        'info': _stored.info,
      },
    ],
  };

  @override
  Future<List<IncidentForce>> fetchIncidentForces({
    String? forIncidentId,
  }) async => const <IncidentForce>[];

  @override
  Future<CalcConfig> fetchConfig() async => CalcConfig(
    cylinderVolL: 6.8,
    fullPressureMpa: 30,
    consumptionLpm: 80,
    warnMin: 10,
    alarmMin: 5,
  );

  @override
  Future<Map<String, dynamic>> refreshSession() async => <String, dynamic>{
    'expires_at': DateTime.now()
        .add(const Duration(hours: 8))
        .millisecondsSinceEpoch,
  };

  @override
  Future<void> sendLogs(List<Map<String, dynamic>> entries) async {}

  @override
  Future<AdminCapability?> fetchAdminCapability() async => null;

  @override
  Future<bool> fetchMemberReviewCapability() async => false;

  @override
  Future<Map<String, dynamic>> fetchUserSettings() async => <String, dynamic>{
    'updatedAt': 0,
    'settings': const <String, dynamic>{},
  };

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void setupChannels({
    bool hasPermission = true,
    bool requestPermissionResult = true,
    bool serviceEnabled = true,
    Map<String, Object?>? locationFix,
  }) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('watchdog/screen'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('watchdog/location'),
      (MethodCall call) async {
        return switch (call.method) {
          'hasPermission' => hasPermission,
          'requestPermission' => requestPermissionResult,
          'serviceEnabled' => serviceEnabled,
          'getLocation' => locationFix,
          _ => null,
        };
      },
    );
  }

  setUp(() {
    ScopedJsonCache.resetForTest();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_url': 'https://api.fireman119.xyz',
      'real_name': '张三',
      'unit_id': 'unit-1',
      'unit_code': '1001',
      'unit_name': '示例市消防救援大队',
      'session_token': 'session-token',
      'session_expires_at': DateTime.now()
          .add(const Duration(hours: 8))
          .millisecondsSinceEpoch,
    });
    setupChannels();
  });

  AppController createController(_IncidentInfoFakeApi api) {
    return AppController(
      apiFactory:
          ({
            required baseUrl,
            required incidentId,
            required sessionToken,
            required deviceId,
            required actorName,
            required unitId,
            required unitCode,
            onAuthenticationFailure,
          }) => api,
      syncClientFactory: ({required api, required onMessage, onError, onDone}) =>
          _NoopRealtimeClient(
            api: api,
            onMessage: onMessage,
            onError: onError,
            onDone: onDone,
          ),
    );
  }

  group('AppController 自建警情与基本信息扩展', () {
    testWidgets('createIncident 同步标题/地点/大类/字符串坐标并立即更新当前与活跃列表', (
      WidgetTester tester,
    ) async {
      final api = _IncidentInfoFakeApi();
      final controller = createController(api);
      try {
        await controller.init();
        await tester.pump();

        final created = await controller.createIncident(
          title: '示例工业园厂房火灾',
          location: '示例大道88号',
          disasterCategory: 'rescue',
          latitude: 31.2304,
          longitude: 121.4737,
        );
        await tester.pump();

        expect(api.updatedTitleArg, '示例工业园厂房火灾');
        expect(api.updatedDetailsExpectedVersion, 0);
        expect(api.updatedDetailsData, <String, dynamic>{
          'location': '示例大道88号',
          'disaster_category': 'rescue',
          'latitude': '31.230400',
          'longitude': '121.473700',
        });
        expect(created.title, '示例工业园厂房火灾');
        expect(created.effectiveLocation, '示例大道88号');
        expect(controller.currentIncident?.effectiveLocation, '示例大道88号');
        expect(controller.activeIncidents.first.title, '示例工业园厂房火灾');
      } finally {
        controller.dispose();
        await tester.pump();
      }
    });

    testWidgets('createIncident 附加标题或详情更新失败时不阻断已建档警情返回', (
      WidgetTester tester,
    ) async {
      final api = _IncidentInfoFakeApi()
        ..failTitleFollowup = true
        ..failDetailsFollowup = true;
      final controller = createController(api);
      try {
        await controller.init();
        await tester.pump();

        final created = await controller.createIncident(
          title: '故障容错测试',
          location: '示例路1号',
        );
        await tester.pump();

        expect(created.id, 'inc-new-1');
        expect(controller.currentIncident?.id, 'inc-new-1');
      } finally {
        controller.dispose();
        await tester.pump();
      }
    });

    testWidgets('updateCurrentBasicInfo 按详情版本号更新标题、事发地点与字符串坐标', (
      WidgetTester tester,
    ) async {
      final api = _IncidentInfoFakeApi();
      final controller = createController(api);
      try {
        await controller.init();
        await tester.pump();
        await controller.createIncident();
        await tester.pump();

        final updated = await controller.updateCurrentBasicInfo(
          title: '示例物流园东门火灾',
          location: '示例大道99号东门',
          latitude: 30.123456,
          longitude: 120.654321,
        );
        await tester.pump();

        expect(api.updatedTitleArg, '示例物流园东门火灾');
        expect(api.updatedDetailsExpectedVersion, 0);
        expect(api.updatedDetailsData, <String, dynamic>{
          'location': '示例大道99号东门',
          'latitude': '30.123456',
          'longitude': '120.654321',
        });
        expect(updated.title, '示例物流园东门火灾');
        expect(updated.effectiveLocation, '示例大道99号东门');
        expect(controller.currentIncident?.info['latitude'], '30.123456');
        expect(controller.activeIncidents.first.effectiveLocation, '示例大道99号东门');

        // 第二次更新仅修改坐标与地点应携带递增值 version = 1
        await controller.updateCurrentBasicInfo(
          title: '示例物流园东门火灾',
          location: '示例大道100号北门',
        );
        expect(api.updatedDetailsExpectedVersion, 1);
      } finally {
        controller.dispose();
        await tester.pump();
      }
    });
  });

  group('locateCurrentIncidentAddress 一键定位解析', () {
    testWidgets('非 Android 平台返回不支持提示，Android 分支完整覆盖权限/开关/超时/成功与降级', (
      WidgetTester tester,
    ) async {
      final api = _IncidentInfoFakeApi();
      final controller = createController(api)..api = api;
      try {
        // 1. 非 Android 平台
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final unsupported = await locateCurrentIncidentAddress(controller);
        expect(unsupported.errorMessage, contains('暂不支持系统定位'));

        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        // 2. 权限被拒
        setupChannels(hasPermission: false, requestPermissionResult: false);
        final denied = await locateCurrentIncidentAddress(controller);
        expect(denied.errorMessage, contains('未授予位置权限'));

        // 3. 定位开关未开
        setupChannels(hasPermission: true, serviceEnabled: false);
        final disabled = await locateCurrentIncidentAddress(controller);
        expect(disabled.errorMessage, contains('系统定位服务未开启'));

        // 4. 定位超时/返回空
        setupChannels(
          hasPermission: true,
          serviceEnabled: true,
          locationFix: null,
        );
        final timedOut = await locateCurrentIncidentAddress(controller);
        expect(timedOut.errorMessage, contains('定位超时或信号较弱'));

        // 5. 成功获取位置与高德反地理地址及 GCJ-02 坐标
        setupChannels(
          hasPermission: true,
          serviceEnabled: true,
          locationFix: <String, Object?>{
            'lat': 31.2304,
            'lon': 121.4737,
            'accuracy': 12.0,
            'provider': 'gps',
            'ageMs': 100,
          },
        );
        final ok = await locateCurrentIncidentAddress(controller);
        expect(ok.errorMessage, isNull);
        expect(ok.address, '示例市示例区示范大道188号');
        expect(ok.latitude, 31.234567);
        expect(ok.longitude, 121.456789);

        // 6. 反地理服务异常时保留坐标并提示手动补充
        api.failWeather = true;
        final fallback = await locateCurrentIncidentAddress(controller);
        expect(fallback.address, isEmpty);
        expect(fallback.latitude, 31.2304);
        expect(fallback.longitude, 121.4737);
        expect(fallback.errorMessage, contains('已获取当前坐标'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        controller.dispose();
        await tester.pump();
      }
    });
  });
}
