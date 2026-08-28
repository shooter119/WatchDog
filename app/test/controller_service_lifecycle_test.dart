import 'dart:async';
import 'dart:io';

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
  _CountingRosterApi() : super(baseUrl: 'http://rec', incidentId: 'test');

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
      client.requests.first.toString(),
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
      client.requests.first.toString(),
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
  });
}
