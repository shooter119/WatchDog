import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/local_asr_service.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/state/app_controller.dart';

class _CountingRosterApi extends ApiClient {
  _CountingRosterApi()
    : super(baseUrl: 'http://rec', incidentId: 'test', unitId: 'test-unit');

  int firefightersRequests = 0;
  int hotwordsRequests = 0;

  @override
  Future<List<Firefighter>> fetchFirefighters() async {
    firefightersRequests++;
    return [Firefighter(id: 'f1', name: '张三')];
  }

  @override
  Future<List<Hotword>> fetchHotwords() async {
    hotwordsRequests++;
    return [Hotword(id: 'h1', word: '火情')];
  }
}

class _SlowSyncApi extends ApiClient {
  _SlowSyncApi() : super(baseUrl: 'http://rec', incidentId: 'test');

  final started = Completer<void>();
  final gate = Completer<List<Incident>>();

  @override
  Future<List<Incident>> fetchIncidents({String? status}) async {
    if (!started.isCompleted) started.complete();
    return gate.future;
  }
}

class _RecordingModelClient extends http.BaseClient {
  final requests = <Uri>[];
  final int statusCode;

  _RecordingModelClient({this.statusCode = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    if (request.url.path.endsWith('/manifest.json')) {
      final body = utf8.encode(_modelManifestBody());
      return http.StreamedResponse(
        Stream<List<int>>.value(body),
        statusCode,
        contentLength: body.length,
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(<int>[1]),
      statusCode,
      contentLength: 1,
      request: request,
    );
  }

  @override
  void close() {}
}

String _modelManifestBody() {
  const modelFiles = [
    'encoder-epoch-20-avg-1.int8.onnx',
    'decoder-epoch-20-avg-1.onnx',
    'joiner-epoch-20-avg-1.int8.onnx',
    'tokens.txt',
    'bpe.vocab',
  ];
  final digest = sha256.convert(<int>[1]).toString();
  final files = <String, Object>{
    for (final name in modelFiles)
      '${LocalAsrService.modelName}/$name': {'sizeBytes': 1, 'sha256': digest},
    'denoiser/dpdfnet2.onnx': {'sizeBytes': 1, 'sha256': digest},
  };
  return jsonEncode({
    'schemaVersion': 1,
    'modelVersion': LocalAsrService.modelName,
    'files': files,
  });
}

class _AuthLifecycleController extends AppController {
  @override
  Future<void> refreshConfig() async {}

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<void> loadRoster() async {}

  @override
  Future<void> syncSettings() async {}
}

class _SessionRefreshApi extends ApiClient {
  _SessionRefreshApi({this.result, this.error, this.gate})
    : super(
        baseUrl: 'https://example.test',
        incidentId: '',
        sessionToken: 'session-token',
      );

  final Map<String, dynamic>? result;
  final Object? error;
  final Completer<Map<String, dynamic>>? gate;
  int refreshCalls = 0;

  @override
  Future<Map<String, dynamic>> refreshSession() async {
    refreshCalls++;
    if (error != null) throw error!;
    if (gate != null) return gate!.future;
    return result!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global'),
          (_) async => null,
        );
  });

  testWidgets('名单热词并发加载只发起一组远端请求', (tester) async {
    final api = _CountingRosterApi();
    final controller = AppController()..api = api;
    addTearDown(controller.dispose);

    await Future.wait([controller.loadRoster(), controller.loadRoster()]);

    expect(api.firefightersRequests, 1);
    expect(api.hotwordsRequests, 1);
    expect(controller.firefighters.single.name, '张三');
    expect(controller.hotwords.single.word, '火情');
  });

  testWidgets('refreshNow 在已有同步进行时等待同一个 Future', (tester) async {
    final api = _SlowSyncApi();
    final controller = AppController(offlineQueueDrainer: () async {})
      ..api = api;
    addTearDown(controller.dispose);

    final first = controller.sync();
    await api.started.future;
    final second = controller.refreshNow();
    var secondCompleted = false;
    unawaited(second.then((_) => secondCompleted = true));
    await tester.pump();
    expect(secondCompleted, isFalse);

    api.gate.complete([]);
    await Future.wait([first, second]);
    expect(secondCompleted, isTrue);
  });

  test('模型地址归一化且拒绝不安全的外部 HTTP 地址', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'watchdog-lifecycle-',
    );
    addTearDown(() async {
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });
    final client = _RecordingModelClient();
    final service = LocalAsrService(
      supportDirectoryProvider: () async => supportDirectory,
      httpClientFactory: () => client,
      modelBaseUrl: 'https://example.test/models///',
    );
    addTearDown(service.dispose);

    await service.downloadModel();
    expect(
      client.requests
          .firstWhere(
            (request) => request.path.endsWith(
              '/${LocalAsrService.modelName}/encoder-epoch-20-avg-1.int8.onnx',
            ),
          )
          .toString(),
      'https://example.test/models/multi-zh-hans-2023-9-2/encoder-epoch-20-avg-1.int8.onnx',
    );
    expect(
      client.requests.map((request) => request.toString()),
      everyElement(startsWith('https://example.test/')),
    );

    final unsafeClient = _RecordingModelClient();
    final unsafe = LocalAsrService(
      supportDirectoryProvider: () async => supportDirectory,
      httpClientFactory: () => unsafeClient,
      modelBaseUrl: 'http://example.test/models',
    );
    addTearDown(unsafe.dispose);
    await expectLater(unsafe.downloadModel(), throwsA(isA<ArgumentError>()));
    expect(unsafeClient.requests, isEmpty);

    final missingClient = _RecordingModelClient(statusCode: 404);
    final missing = LocalAsrService(
      supportDirectoryProvider: () async => supportDirectory,
      httpClientFactory: () => missingClient,
      modelBaseUrl: 'https://example.test/models',
    );
    addTearDown(missing.dispose);
    await expectLater(missing.downloadModel(), throwsA(isA<StateError>()));
    expect(missingClient.requests, hasLength(1));
  });

  test('未显式覆盖时模型地址跟随运行时服务器', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'watchdog-runtime-model-',
    );
    addTearDown(() async {
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://self-hosted.example/firewatch',
    });
    final client = _RecordingModelClient();
    final service = LocalAsrService(
      supportDirectoryProvider: () async => supportDirectory,
      httpClientFactory: () => client,
    );
    addTearDown(service.dispose);

    await service.downloadModel();

    expect(
      client.requests
          .firstWhere(
            (request) => request.path.endsWith(
              '/${LocalAsrService.modelName}/encoder-epoch-20-avg-1.int8.onnx',
            ),
          )
          .toString(),
      'https://self-hosted.example/firewatch/models/${LocalAsrService.modelName}/encoder-epoch-20-avg-1.int8.onnx',
    );
    expect(
      client.requests,
      everyElement(
        predicate<Uri>(
          (uri) => uri.toString().startsWith(
            'https://self-hosted.example/firewatch/models/',
          ),
        ),
      ),
    );
  });

  test('设置 URL 与令牌读取会去除危险查询参数和首尾空白', () async {
    expect(Settings.isSafeHttpUrl('https://example.test/api'), isTrue);
    expect(Settings.isSafeHttpUrl('http://example.test/api'), isFalse);
    expect(Settings.isSafeHttpUrl('https://example.test/api?token=x'), isFalse);
    expect(Settings.isSafeHttpUrl('https://user@example.test/api'), isFalse);

    await Settings.setServerUrl('https://example.test/api///');
    expect(await Settings.serverUrl, 'https://example.test/api');

    await Settings.setApiToken('  configured-token  ');
    expect(await Settings.apiToken, 'configured-token');
    await Settings.setApiToken('   ');
    expect(await Settings.apiToken, isEmpty);

    await Settings.setSessionToken('  session-token  ');
    expect(await Settings.sessionToken, 'session-token');
    final sp = await SharedPreferences.getInstance();
    // 测试平台没有原生 Keystore，SecureStore 会兼容落到 mock preferences。
    expect(sp.getString('session_token'), 'session-token');
    await Settings.setSessionToken('   ');
    expect(await Settings.sessionToken, isEmpty);
    expect(sp.getString('session_token'), isNull);
  });

  test('仅有效会话恢复认证状态，主动退出清除令牌', () async {
    SharedPreferences.setMockInitialValues({
      'real_name': '测试人员',
      'unit_id': 'unit-a',
      'unit_code': '1234',
      'unit_name': '测试单位',
      'api_token': 'api-token',
    });
    final unauthenticated = _AuthLifecycleController();
    await unauthenticated.init();
    expect(unauthenticated.needsAuthentication, isTrue);
    unauthenticated.dispose();

    await Settings.setSessionToken('session-token');
    await Settings.setSessionExpiresAt(
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    final authenticated = _AuthLifecycleController();
    addTearDown(authenticated.dispose);
    await authenticated.init();
    expect(authenticated.needsAuthentication, isFalse);

    await authenticated.leaveUnit();
    expect(authenticated.needsAuthentication, isTrue);
    expect(await Settings.sessionToken, isEmpty);
  });

  test('会话临近过期时续期并保存新的 expires_at', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'real_name': '测试人员',
      'unit_id': 'unit-a',
      'unit_code': '1234',
      'unit_name': '测试单位',
      'session_token': 'session-token',
      'session_expires_at': now + const Duration(minutes: 30).inMilliseconds,
    });
    final api = _SessionRefreshApi(
      result: {'expires_at': now + const Duration(hours: 8).inMilliseconds},
    );
    final controller = _AuthLifecycleController()..api = api;
    addTearDown(controller.dispose);

    await controller.init();
    await controller.handleAppResumed();

    expect(api.refreshCalls, 1);
    expect(
      await Settings.sessionExpiresAt,
      now + const Duration(hours: 8).inMilliseconds,
    );
  });

  test('过期会话启动时回认证页并保留单位姓名但清除验证码', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'real_name': '测试人员',
      'unit_id': 'unit-a',
      'unit_code': '1234',
      'unit_name': '测试单位',
      'session_token': 'expired-token',
      'session_expires_at': now - 1,
      'current_incident_id': 'incident-a',
    });
    final controller = _AuthLifecycleController();
    addTearDown(controller.dispose);

    await controller.init();

    expect(controller.needsAuthentication, isTrue);
    expect(await Settings.sessionToken, isEmpty);
    expect(await Settings.sessionExpiresAt, 0);
    expect(await Settings.currentIncidentId, isEmpty);
    expect(await Settings.unitId, isEmpty);
    expect(await Settings.unitCode, isEmpty);
    expect(await Settings.unitName, '测试单位');
    expect(await Settings.realName, '测试人员');
  });

  test('并发会话续期只发起一次请求', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'real_name': '测试人员',
      'unit_id': 'unit-a',
      'unit_name': '测试单位',
      'session_token': 'session-token',
      'session_expires_at': now + const Duration(minutes: 30).inMilliseconds,
    });
    final gate = Completer<Map<String, dynamic>>();
    final api = _SessionRefreshApi(gate: gate);
    final controller = _AuthLifecycleController()..api = api;
    addTearDown(controller.dispose);
    await controller.init();

    final first = controller.handleAppResumed();
    final second = controller.handleAppResumed();
    gate.complete({
      'expires_at': now + const Duration(hours: 8).inMilliseconds,
    });
    await Future.wait([first, second]);

    expect(api.refreshCalls, 1);
  });

  test('续期返回 SESSION_EXPIRED 时统一清理且保留身份预填', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'real_name': '测试人员',
      'unit_id': 'unit-a',
      'unit_code': '1234',
      'unit_name': '测试单位',
      'session_token': 'session-token',
      'session_expires_at': now + const Duration(minutes: 30).inMilliseconds,
      'current_incident_id': 'incident-a',
    });
    final api = _SessionRefreshApi(
      error: ApiException(
        '认证会话已过期，请重新认证',
        statusCode: 401,
        code: 'SESSION_EXPIRED',
      ),
    );
    final controller = _AuthLifecycleController()..api = api;
    addTearDown(controller.dispose);
    await controller.init();

    await Future.wait([
      controller.handleAppResumed(),
      controller.handleAppResumed(),
    ]);

    expect(api.refreshCalls, 1);
    expect(controller.needsAuthentication, isTrue);
    expect(await Settings.sessionToken, isEmpty);
    expect(await Settings.unitCode, isEmpty);
    expect(await Settings.unitName, '测试单位');
    expect(await Settings.realName, '测试人员');
  });
}
