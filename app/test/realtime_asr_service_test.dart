import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/chat_page.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/op_log_service.dart';
import 'package:watchdog/services/realtime_asr_service.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

class _RealHttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      'DIRECT';
}

Future<T> _withRealHttp<T>(Future<T> Function() fn) =>
    HttpOverrides.runWithHttpOverrides(fn, _RealHttpOverrides());

class _FakeAudioRecorder implements AudioRecorder {
  StreamController<Uint8List>? streamController;
  final StreamController<Amplitude> amplitudeController =
      StreamController<Amplitude>.broadcast();
  final StreamController<RecordState> stateController =
      StreamController<RecordState>.broadcast();
  bool recording = false;
  int startStreamCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    recording = true;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    startStreamCalls++;
    recording = true;
    final prev = streamController;
    streamController = StreamController<Uint8List>(
      onCancel: () => Future<void>.value(),
    );
    if (prev != null) unawaited(prev.close());
    return streamController!.stream;
  }

  void emitPcm(List<int> bytes) {
    streamController?.add(Uint8List.fromList(bytes));
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    recording = false;
    final prev = streamController;
    streamController = null;
    if (prev != null) unawaited(prev.close());
    return null;
  }

  @override
  Future<void> cancel() async {
    recording = false;
    final prev = streamController;
    streamController = null;
    if (prev != null) unawaited(prev.close());
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Stream<RecordState> onStateChanged() => stateController.stream;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      amplitudeController.stream;

  @override
  Future<bool> isRecording() async => recording;

  @override
  Future<bool> isPaused() async => false;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<List<InputDevice>> listInputDevices() async => const [];

  @override
  Future<Amplitude> getAmplitude() async => Amplitude(current: -20, max: -10);

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async => true;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await cancel();
    unawaited(amplitudeController.close());
    unawaited(stateController.close());
  }

  @override
  RecordIos? get ios => null;
}

class _FakeAudioService extends AudioService {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {}

  @override
  Stream<double> amplitudeStream() => const Stream.empty();

  @override
  Future<Uint8List> stop() async => Uint8List(0);

  @override
  Future<void> dispose() async {}
}

class _FallbackTestApi extends ApiClient {
  _FallbackTestApi({this.transcribeReply = '张三20兆帕'})
    : super(baseUrl: 'http://test', incidentId: 'inc-1');

  final String transcribeReply;
  final List<Uint8List> transcribedPayloads = <Uint8List>[];
  int parseCalls = 0;
  int chatStreamCalls = 0;

  @override
  Future<String> transcribe(Uint8List audioBytes, {String? opId}) async {
    transcribedPayloads.add(audioBytes);
    return transcribeReply;
  }

  @override
  Future<ParseResult> parse(String text, {String? opId}) async {
    parseCalls++;
    return ParseResult(
      action: 'enter',
      intent: VoiceIntent.entry,
      people: [ParsePerson(name: '张三', pressureMpa: 20)],
    );
  }

  @override
  Future<List<ChatMessage>> fetchChatMessages() async => const [];

  @override
  Future<void> sendLogs(List<Map<String, dynamic>> logs) async {}

  @override
  Future<String> sendChatMessageStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    chatStreamCalls++;
    final reply = '已收到：$message';
    onChunk(reply);
    return reply;
  }
}

class _FallbackTestController extends AppController {
  _FallbackTestController({required ApiClient api}) : super() {
    this.api = api;
    asrCloudEnabled = true;
    parseCloudEnabled = true;
    firefighters = [Firefighter(id: 'f-1', name: '张三')];
    currentIncident = Incident(
      id: 'inc-1',
      number: '2026-01',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 1,
    );
  }

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await OpLogService.instance.init();
    await OpLogService.instance.setSyncEnabled(false);
    await OpLogService.instance.clearLocal();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global'),
          (_) async => null,
        );
  });

  group('RealtimeAsrService 解耦与弱网兜底', () {
    test(
      'start() 在本地麦克风就绪后立即返回，建连期间开头音频完整缓冲并在握手后自动冲刷',
      () => _withRealHttp(() async {
        final receivedTexts = <String>[];
        final receivedBinaryBytes = <int>[];
        final controlMessages = <Map<String, dynamic>>[];
        final serverDone = Completer<void>();

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sub = server.listen((request) async {
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          final ws = await WebSocketTransformer.upgrade(request);
          ws.listen((data) {
            if (data is String) {
              final msg = Map<String, dynamic>.from(jsonDecode(data) as Map);
              controlMessages.add(msg);
              if (msg['type'] == 'stop') {
                ws.add(jsonEncode({'type': 'final', 'text': '张三20兆帕'}));
                ws.add(jsonEncode({'type': 'done'}));
                if (!serverDone.isCompleted) serverDone.complete();
              }
            } else if (data is List<int>) {
              receivedBinaryBytes.addAll(data);
              if (receivedBinaryBytes.length >= 3200) {
                ws.add(jsonEncode({'type': 'partial', 'text': '张三'}));
              }
            }
          });
        });
        addTearDown(() async {
          await sub.cancel();
          await server.close(force: true);
        });

        final socketGate = Completer<WebSocket>();
        final recorder = _FakeAudioRecorder();
        final api = ApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          incidentId: 'inc-1',
        );
        addTearDown(api.dispose);

        final service = RealtimeAsrService(
          api: api,
          recorder: recorder,
          onText: (text, {required finalText}) => receivedTexts.add(text),
          socketFactory: (url, {headers, compression = CompressionOptions.compressionDefault}) =>
              socketGate.future,
        );
        addTearDown(service.dispose);

        // start() 不阻塞在慢速 WebSocket 握手上。
        await service.start(opId: 'op-buffered');
        expect(recorder.startStreamCalls, 1);
        expect(socketGate.isCompleted, isFalse);

        // 在 WebSocket 尚在建连期间录下 4000 字节开头音频。
        recorder.emitPcm(List<int>.filled(2000, 1));
        recorder.emitPcm(List<int>.filled(2000, 2));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(receivedBinaryBytes, isEmpty);

        // 握手完成：应立即发送 start 并冲刷满包的 3200 字节开头音频。
        final clientWs = await WebSocket.connect(
          'ws://127.0.0.1:${server.port}/api/asr/stream',
        );
        socketGate.complete(clientWs);
        await service.pendingConnectTask;
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(controlMessages.first['type'], 'start');
        expect(controlMessages.first['opId'], 'op-buffered');
        expect(receivedBinaryBytes.length, 3200);
        expect(receivedBinaryBytes.sublist(0, 2000), everyElement(1));
        expect(receivedBinaryBytes.sublist(2000, 3200), everyElement(2));

        // 继续录入 2400 字节并停止，剩余音频也应完整送达。
        recorder.emitPcm(List<int>.filled(2400, 3));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final result = await service.stop();
        await serverDone.future.timeout(const Duration(seconds: 2));

        expect(result.text, '张三20兆帕');
        expect(result.wavBytes.length, 44 + 6400);
        expect(receivedBinaryBytes.length, 6400);
        expect(receivedTexts, containsAllInOrder(['张三', '张三20兆帕']));
        expect(controlMessages.map((m) => m['type']), ['start', 'stop']);
      }),
    );

    test(
      'WebSocket 握手挂起期间松手 stop() 不阻塞超时，自动关闭迟到连接并返回完整 WAV',
      () => _withRealHttp(() async {
        final serverClosed = Completer<void>();
        final serverControlMessages = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sub = server.listen((request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final ws = await WebSocketTransformer.upgrade(request);
            ws.listen(
              (data) {
                if (data is String) serverControlMessages.add(data);
              },
              onDone: () {
                if (!serverClosed.isCompleted) serverClosed.complete();
              },
            );
          }
        });
        addTearDown(() async {
          await sub.cancel();
          await server.close(force: true);
        });

        final hangingSocket = Completer<WebSocket>();
        final recorder = _FakeAudioRecorder();
        final api = ApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          incidentId: 'inc-1',
        );
        addTearDown(api.dispose);

        final service = RealtimeAsrService(
          api: api,
          recorder: recorder,
          socketFactory: (url, {headers, compression = CompressionOptions.compressionDefault}) =>
              hangingSocket.future,
        );
        addTearDown(service.dispose);

        await service.start(opId: 'op-hang');
        final connectTask = service.pendingConnectTask;
        recorder.emitPcm(List<int>.filled(1600, 7));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sw = Stopwatch()..start();
        RealtimeAsrException? caught;
        try {
          await service.stop();
        } on RealtimeAsrException catch (error) {
          caught = error;
        }
        sw.stop();

        expect(caught, isNotNull);
        expect(sw.elapsedMilliseconds, lessThan(1000));
        expect(caught!.result.wavBytes.length, 44 + 1600);
        expect(
          caught.result.wavBytes.sublist(44),
          everyElement(7),
        );

        // 迟到 socket 完成时应立即被关闭且不会发送 start。
        final lateWs = await WebSocket.connect(
          'ws://127.0.0.1:${server.port}/api/asr/stream',
        );
        hangingSocket.complete(lateWs);
        await connectTask;
        await serverClosed.future.timeout(const Duration(seconds: 2));
        await lateWs.done.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(lateWs.readyState, WebSocket.closed);
        expect(serverControlMessages, isEmpty);
      }),
    );

    test(
      '录音中途 WebSocket 异常断开不触发未捕获 Zone 异常，并保留断连后录音供兜底',
      () async {
        final zoneErrors = <Object>[];
        await runZonedGuarded<Future<void>>(() async {
          await _withRealHttp(() async {
            final serverDropped = Completer<void>();
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final sub = server.listen((request) async {
              if (WebSocketTransformer.isUpgradeRequest(request)) {
                final ws = await WebSocketTransformer.upgrade(request);
                ws.listen((data) {
                  if (data is String) {
                    ws.close(1011, 'upstream drop');
                    if (!serverDropped.isCompleted) serverDropped.complete();
                  }
                });
              }
            });
            addTearDown(() async {
              await sub.cancel();
              await server.close(force: true);
            });

            final recorder = _FakeAudioRecorder();
            final api = ApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          incidentId: 'inc-1',
        );
            addTearDown(api.dispose);

            final service = RealtimeAsrService(
              api: api,
              recorder: recorder,
              socketFactory:
                  (
                    _, {
                    headers,
                    compression = CompressionOptions.compressionDefault,
                  }) => WebSocket.connect(
                    'ws://127.0.0.1:${server.port}/api/asr/stream',
                  ),
            );
            addTearDown(service.dispose);

            await service.start(opId: 'op-drop');
            recorder.emitPcm(List<int>.filled(800, 4));
            await service.pendingConnectTask;
            await serverDropped.future.timeout(const Duration(seconds: 2));
            await Future<void>.delayed(const Duration(milliseconds: 50));

            // 断连后用户继续说话，音频仍必须保留在 wavBytes 中。
            recorder.emitPcm(List<int>.filled(1200, 5));
            await Future<void>.delayed(const Duration(milliseconds: 20));

            RealtimeAsrException? caught;
            try {
              await service.stop();
            } on RealtimeAsrException catch (error) {
              caught = error;
            }
            expect(caught, isNotNull);
            expect(caught!.result.wavBytes.length, 44 + 2000);
          });
        }, (error, stack) => zoneErrors.add(error));

        expect(zoneErrors, isEmpty);
      },
    );
  });

  group('HomePage 与 ChatPage 实时流超时/失败自动回退批量转写', () {
    testWidgets(
      'HomePage 实时 WebSocket 挂起时按下立即进入录音态，松手自动回退批量识别',
      timeout: const Timeout(Duration(seconds: 15)),
      (tester) async {
        final api = _FallbackTestApi(transcribeReply: '张三20兆帕');
        final controller = _FallbackTestController(api: api);
        addTearDown(() {
          controller.dispose();
          api.dispose();
        });
        final recorder = _FakeAudioRecorder();
        final hangingSocket = Completer<WebSocket>();
        final recordingStates = <bool>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: HomePage(
                controller: controller,
                audioService: _FakeAudioService(),
                onRecordingChanged: recordingStates.add,
                realtimeAsrFactory: (a, onText) => RealtimeAsrService(
                  api: a,
                  onText: onText,
                  recorder: recorder,
                  socketFactory:
                      (
                        url, {
                        headers,
                        compression = CompressionOptions.compressionDefault,
                      }) => hangingSocket.future,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final state = tester.state<HomePageState>(find.byType(HomePage));
        await state.beginRecording();
        await tester.pump();

        // WebSocket 仍未就绪，但页面已瞬时进入录音态。
        expect(hangingSocket.isCompleted, isFalse);
        expect(recordingStates, [true]);
        expect(find.byKey(const Key('home-recording-limit')), findsOneWidget);

        recorder.emitPcm(List<int>.filled(1600, 9));
        await tester.pump();

        var finished = false;
        final finishFuture = state.finishRecording().whenComplete(() {
          finished = true;
        });
        hangingSocket.completeError(
          const SocketException('aborted after stop'),
        );
        for (var i = 0; i < 20 && !finished; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(finished, isTrue);
        await finishFuture;
        await tester.pump();

        expect(recordingStates, [true, false]);
        expect(api.transcribedPayloads, hasLength(1));
        expect(api.transcribedPayloads.single.length, 44 + 1600);
        expect(api.parseCalls, 1);
        expect(find.text('张三'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'ChatPage 实时 WebSocket 挂起时按下立即进入录音态，松手自动回退批量识别并提问',
      timeout: const Timeout(Duration(seconds: 15)),
      (tester) async {
        final api = _FallbackTestApi(transcribeReply: '高倍数泡沫怎么使用？');
        final controller = _FallbackTestController(api: api);
        addTearDown(() {
          controller.dispose();
          api.dispose();
        });
        final recorder = _FakeAudioRecorder();
        final hangingSocket = Completer<WebSocket>();
        final recordingStates = <bool>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ChatPage(
                controller: controller,
                audioService: _FakeAudioService(),
                onRecordingChanged: recordingStates.add,
                realtimeAsrFactory: (a, onText) => RealtimeAsrService(
                  api: a,
                  onText: onText,
                  recorder: recorder,
                  socketFactory:
                      (
                        url, {
                        headers,
                        compression = CompressionOptions.compressionDefault,
                      }) => hangingSocket.future,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final state = tester.state<ChatPageState>(find.byType(ChatPage));
        await state.beginRecording();
        await tester.pump();

        expect(hangingSocket.isCompleted, isFalse);
        expect(recordingStates, [true]);
        expect(find.byKey(const Key('chat-recording-limit')), findsOneWidget);

        recorder.emitPcm(List<int>.filled(1600, 6));
        await tester.pump();

        var chatFinished = false;
        final chatFinishFuture = state.finishRecording().whenComplete(() {
          chatFinished = true;
        });
        hangingSocket.completeError(
          const SocketException('aborted after stop'),
        );
        for (var i = 0; i < 20 && !chatFinished; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(chatFinished, isTrue);
        await chatFinishFuture;
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump();

        expect(recordingStates, [true, false]);
        expect(api.transcribedPayloads, hasLength(1));
        expect(api.transcribedPayloads.single.length, 44 + 1600);
        expect(api.chatStreamCalls, 1);
        expect(find.text('高倍数泡沫怎么使用？'), findsOneWidget);
        expect(find.text('已收到：高倍数泡沫怎么使用？'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
