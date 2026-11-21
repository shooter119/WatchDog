import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/features/copilot/data/models/chat_message.dart';
import 'package:watchdog/features/copilot/data/models/vision_analysis.dart';
import 'package:watchdog/features/copilot/state/copilot_store.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/realtime_asr_service.dart';

class _FakeAudioService implements AudioService {
  bool permissionGranted = true;
  bool _recording = false;
  int startCalls = 0;
  int stopCalls = 0;
  Uint8List stopBytes = Uint8List.fromList(List<int>.filled(128, 7));

  @override
  bool get isRecording => _recording;

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Future<void> start() async {
    startCalls++;
    _recording = true;
  }

  @override
  Stream<double> amplitudeStream() => const Stream<double>.empty();

  @override
  Future<Uint8List> stop() async {
    stopCalls++;
    _recording = false;
    return stopBytes;
  }

  @override
  Future<void> dispose() async {}
}

class _FakeRealtimeSession implements CopilotRealtimeSession {
  _FakeRealtimeSession({
    required this.onText,
    this.startError,
    this.stopResult,
    this.stopException,
  });

  final CopilotRealtimeTextCallback onText;
  final Object? startError;
  final RealtimeAsrResult? stopResult;
  final RealtimeAsrException? stopException;
  int startCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> start({String? opId}) async {
    startCalls++;
    if (startError != null) throw startError!;
  }

  @override
  Future<RealtimeAsrResult> stop() async {
    if (stopException != null) throw stopException!;
    return stopResult ??
        RealtimeAsrResult(text: '默认实时文本', wavBytes: Uint8List(64));
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

CopilotStore _buildStore({
  ValueNotifier<String>? scopeNotifier,
  Future<List<ChatMessage>> Function()? fetchHistory,
  Future<String> Function(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history,
  })?
  askAssistantStream,
  VoidCallback? cancelAssistantRequest,
  Future<void> Function()? clearHistory,
  Future<VisionAnalysis> Function(
    Uint8List bytes, {
    required String mimeType,
    String message,
    String? opId,
  })?
  analyzeVision,
  Future<String> Function(Uint8List bytes, {String? opId})? transcribeAudio,
  AudioService? audioService,
  CopilotRealtimeSession? Function(CopilotRealtimeTextCallback onText)?
  createRealtimeSession,
  Duration requestTimeout = const Duration(seconds: 45),
  Uint8List Function(Uint8List raw)? imageCompressor,
}) {
  final scope = scopeNotifier ?? ValueNotifier<String>('unit-a|inc-1');
  return CopilotStore(
    audioService: audioService ?? _FakeAudioService(),
    requestTimeout: requestTimeout,
    imageCompressor: imageCompressor,
    gateway: CopilotGateway(
      readScope: () => scope.value,
      scopeListenable: scope,
      fetchHistory: fetchHistory ?? () async => const [],
      askAssistantStream:
          askAssistantStream ??
          (msg, {required onChunk, opId, history = const []}) async {
            onChunk('收到：$msg');
            return '收到：$msg';
          },
      cancelAssistantRequest: cancelAssistantRequest ?? () {},
      clearHistory: clearHistory ?? () async {},
      analyzeVision:
          analyzeVision ??
          (bytes, {required mimeType, message = '', opId}) async =>
              const VisionAnalysis(
                relevance: 'related',
                category: 'fire',
                confidence: 0.9,
                facts: ['可见浓烟'],
                risks: ['轰燃风险'],
                toConfirm: ['楼层人数'],
                suggestions: ['佩戴空呼'],
                disclaimer: '以上为图片辅助分析，不替代现场专业判断',
              ),
      transcribeAudio: transcribeAudio ?? (bytes, {opId}) async => '批量转写问题',
      createRealtimeSession: createRealtimeSession,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CopilotStore 作用域、并发与超时守卫', () {
    test('45s 超时主动取消底层请求并清理空思考占位', () async {
      var cancelled = false;
      final stuck = Completer<String>();
      final store = _buildStore(
        requestTimeout: const Duration(milliseconds: 30),
        askAssistantStream: (msg, {required onChunk, opId, history = const []}) =>
            stuck.future,
        cancelAssistantRequest: () => cancelled = true,
      );
      addTearDown(store.dispose);

      await store.submitQuestion('超时测试');
      expect(cancelled, isTrue);
      expect(store.sending, isFalse);
      expect(store.error, contains('超时'));
      expect(store.messages.length, 1);
      expect(store.messages.single.role, 'user');
    });

    test('作用域切换隔离历史与在途回复', () async {
      final scope = ValueNotifier<String>('scope-a');
      final histA = Completer<List<ChatMessage>>();
      final histB = Completer<List<ChatMessage>>();
      final replyA = Completer<String>();

      final store = _buildStore(
        scopeNotifier: scope,
        fetchHistory: () =>
            scope.value == 'scope-a' ? histA.future : histB.future,
        askAssistantStream: (msg, {required onChunk, opId, history = const []}) =>
            replyA.future,
      );
      addTearDown(() {
        store.dispose();
        scope.dispose();
      });

      final loadA = store.loadHistory();
      final askA = store.submitQuestion('甲警情问题');
      scope.value = 'scope-b';
      histB.complete(const [
        ChatMessage(id: 'b1', role: 'user', content: '乙历史', createdAt: 2),
      ]);
      await Future<void>.delayed(Duration.zero);

      histA.complete(const [
        ChatMessage(id: 'a1', role: 'user', content: '甲旧历史', createdAt: 1),
      ]);
      replyA.complete('甲迟到回复');
      await Future.wait([loadA, askA]);

      expect(store.scope, 'scope-b');
      expect(store.messages.map((m) => m.content).toList(), ['乙历史']);
    });
  });

  group('CopilotStore 拍照压缩与识险', () {
    test('大于 1600px 图片压缩为宽 1600px JPEG，损坏图与超 8MB 图被拦截', () {
      final store = _buildStore();
      addTearDown(store.dispose);

      final invalid = store.prepareVisionImage(Uint8List.fromList([1, 2, 3]));
      expect(invalid.isValid, isFalse);
      expect(invalid.errorMessage, '无法读取图片，请重新选择');

      final wide = img.Image(width: 2000, height: 1000);
      final encodedPng = Uint8List.fromList(img.encodePng(wide));
      final compressed = store.prepareVisionImage(encodedPng);
      expect(compressed.isValid, isTrue);
      final decoded = img.decodeJpg(compressed.bytes!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 1600);

      final oversizeStore = _buildStore(
        imageCompressor: (_) => Uint8List(CopilotStore.maxVisionBytes + 1),
      );
      addTearDown(oversizeStore.dispose);
      final tooLarge = oversizeStore.prepareVisionImage(Uint8List.fromList([1]));
      expect(tooLarge.isValid, isFalse);
      expect(tooLarge.errorMessage, '图片过大，请重新拍摄');
    });

    test('submitVisionImage 生成 4 段结构化识险与免责声明', () async {
      final store = _buildStore();
      addTearDown(store.dispose);

      final ok = await store.submitVisionImage(
        Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        question: '确认浓烟风险',
      );
      expect(ok, isTrue);
      expect(store.messages.length, 2);
      expect(store.messages[0].content, '图片分析：确认浓烟风险');
      final body = store.messages[1].content;
      expect(body, contains('**图片相关性：相关**'));
      expect(body, contains('### 已确认事实'));
      expect(body, contains('### 可能风险'));
      expect(body, contains('### 待确认事项'));
      expect(body, contains('### 建议措施'));
      expect(body, contains('> 以上为图片辅助分析，不替代现场专业判断'));
    });
  });

  group('CopilotStore 60s 就地录音与降级守卫', () {
    test('实时识别连接失败自动降级至 AudioService 并在结束后批量转写提问', () async {
      final audio = _FakeAudioService();
      final submitted = <String>[];
      final store = _buildStore(
        audioService: audio,
        createRealtimeSession: (onText) => _FakeRealtimeSession(
          onText: onText,
          startError: StateError('ws_connect_failed'),
        ),
        transcribeAudio: (bytes, {opId}) async => '降级识别的现场问题',
        askAssistantStream: (msg, {required onChunk, opId, history = const []}) async {
          submitted.add(msg);
          return '收到回答';
        },
      );
      addTearDown(store.dispose);

      await store.beginRecording();
      expect(store.recording, isTrue);
      expect(audio.startCalls, 1);

      await store.finishRecording();
      await Future<void>.delayed(Duration.zero);
      expect(audio.stopCalls, 1);
      expect(submitted, ['降级识别的现场问题']);
    });

    test('实时流返回空文本且 WAV <= 44B 时判空，不调用批量转写并提示重录', () async {
      var batchCalls = 0;
      final notices = <String>[];
      final store = _buildStore(
        createRealtimeSession: (onText) => _FakeRealtimeSession(
          onText: onText,
          stopResult: RealtimeAsrResult(text: '   ', wavBytes: Uint8List(44)),
        ),
        transcribeAudio: (bytes, {opId}) async {
          batchCalls++;
          return '不应触发';
        },
      );
      store.attachUi(onNotice: (msg, {duration = Duration.zero}) => notices.add(msg));
      addTearDown(store.dispose);

      await store.beginRecording();
      await store.finishRecording();
      expect(batchCalls, 0);
      expect(notices, contains('未识别到语音，请再说一次'));
    });

    test('实时流 stop 抛出 RealtimeAsrException 且有效 WAV > 44B 时降级批量转写', () async {
      final submitted = <String>[];
      final store = _buildStore(
        createRealtimeSession: (onText) => _FakeRealtimeSession(
          onText: onText,
          stopException: RealtimeAsrException(
            'socket_closed',
            RealtimeAsrResult(text: '', wavBytes: Uint8List(200)),
          ),
        ),
        transcribeAudio: (bytes, {opId}) async => '补救批量识别结果',
        askAssistantStream: (msg, {required onChunk, opId, history = const []}) async {
          submitted.add(msg);
          return 'ok';
        },
      );
      addTearDown(store.dispose);

      await store.beginRecording();
      await store.finishRecording();
      await Future<void>.delayed(Duration.zero);
      expect(submitted, ['补救批量识别结果']);
    });

    testWidgets('60 秒录音上限在 50 秒进入预警并于 60 秒自动结束提交', (tester) async {
      final audio = _FakeAudioService();
      final submitted = <String>[];
      final store = _buildStore(
        audioService: audio,
        transcribeAudio: (bytes, {opId}) async => '满时长语音问题',
        askAssistantStream:
            (msg, {required onChunk, opId, history = const []}) async {
              submitted.add(msg);
              return '自动回复';
            },
      );
      addTearDown(store.dispose);

      await store.beginRecording();
      expect(store.recording, isTrue);
      expect(store.isRecordingWarning, isFalse);

      await tester.pump(const Duration(seconds: 50));
      expect(store.recording, isTrue);
      expect(store.isRecordingWarning, isTrue);
      expect(store.recordingRemainingSeconds, 10);

      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(store.recording, isFalse);
      expect(audio.stopCalls, 1);
      expect(submitted, ['满时长语音问题']);
    });
  });
}
