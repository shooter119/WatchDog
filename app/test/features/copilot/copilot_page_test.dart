import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/copilot/data/models/chat_message.dart';
import 'package:watchdog/features/copilot/data/models/vision_analysis.dart';
import 'package:watchdog/features/copilot/state/copilot_store.dart';
import 'package:watchdog/features/copilot/ui/copilot_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/realtime_asr_service.dart';

class _ScriptedChunk {
  final Duration delay;
  final String delta;
  const _ScriptedChunk(this.delay, this.delta);
}

class _StubAudioService implements AudioService {
  bool recording = false;
  int startCalls = 0;
  int stopCalls = 0;
  Uint8List stopBytes = Uint8List.fromList(List<int>.filled(128, 3));

  @override
  bool get isRecording => recording;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {
    startCalls++;
    recording = true;
  }

  @override
  Stream<double> amplitudeStream() => const Stream<double>.empty();

  @override
  Future<Uint8List> stop() async {
    stopCalls++;
    recording = false;
    return stopBytes;
  }

  @override
  Future<void> dispose() async {}
}

class _FailingRealtimeSession implements CopilotRealtimeSession {
  @override
  Future<void> start({String? opId}) async => throw StateError('connect_fail');

  @override
  Future<RealtimeAsrResult> stop() async =>
      RealtimeAsrResult(text: '', wavBytes: Uint8List(44));

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

class _Harness {
  _Harness({
    List<ChatMessage> initialHistory = const [],
    List<_ScriptedChunk> chunks = const [],
    bool hasIncidentContext = false,
    Future<List<ChatMessage>> Function()? fetchHistoryOverride,
    Future<String> Function(
      String message, {
      required void Function(String delta) onChunk,
      String? opId,
      List<ChatMessage> history,
    })?
    askOverride,
    Future<void> Function()? clearOverride,
    Future<List<ChatMessage>> Function()? legacyHistoryOverride,
    CopilotRealtimeSession? Function(CopilotRealtimeTextCallback onText)?
    createRealtimeSession,
    Future<String> Function(Uint8List bytes, {String? opId})? transcribeAudio,
    Uint8List Function(Uint8List raw)? imageCompressor,
  }) : scope = ValueNotifier<String>('unit-a|inc-a') {
    store = CopilotStore(
      audioService: audio,
      imageCompressor: imageCompressor,
      gateway: CopilotGateway(
        readScope: () => scope.value,
        scopeListenable: scope,
        hasIncidentContext: () => hasIncidentContext,
        onOpenIncidentDetails: () => openedIncidentDetails++,
        fetchHistory: fetchHistoryOverride ?? () async => initialHistory,
        askAssistantStream:
            askOverride ??
            (message, {required onChunk, opId, history = const []}) async {
              submittedQuestions.add(message);
              final buf = StringBuffer();
              for (final chunk in chunks) {
                if (chunk.delay > Duration.zero) {
                  await Future<void>.delayed(chunk.delay);
                }
                buf.write(chunk.delta);
                onChunk(chunk.delta);
              }
              return buf.toString();
            },
        cancelAssistantRequest: () => cancelledCount++,
        clearHistory: clearOverride ?? () async {
          clearRequested = true;
        },
        loadLegacyHistory: legacyHistoryOverride ?? () async => const [],
        analyzeVision: (bytes, {required mimeType, message = '', opId}) async {
          visionQuestions.add(message);
          return const VisionAnalysis(
            relevance: 'related',
            category: 'chemical',
            confidence: 0.92,
            facts: ['罐体表面有腐蚀斑痕'],
            risks: ['存在泄漏与闪燃风险'],
            toConfirm: ['罐内介质与温度'],
            suggestions: ['保持上风向警戒 50 米'],
            disclaimer: '以上为图片辅助分析，不替代现场专业判断',
          );
        },
        transcribeAudio:
            transcribeAudio ?? (bytes, {opId}) async => '语音识别现场问题',
        createRealtimeSession: createRealtimeSession,
      ),
    );
  }

  final ValueNotifier<String> scope;
  final _StubAudioService audio = _StubAudioService();
  final List<String> submittedQuestions = [];
  final List<bool> sendingStates = [];
  final List<String> visionQuestions = [];
  int cancelledCount = 0;
  int openedIncidentDetails = 0;
  bool clearRequested = false;
  late final CopilotStore store;

  void dispose() {
    store.dispose();
    scope.dispose();
  }
}

const _staleHistory = <ChatMessage>[
  ChatMessage(id: 'old-user', role: 'user', content: '旧问题', createdAt: 1),
  ChatMessage(
    id: 'old-assistant',
    role: 'assistant',
    content: '旧回答',
    createdAt: 2,
  ),
];

Future<void> _pumpCopilotPage(
  WidgetTester tester,
  _Harness harness, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  double bottomNavClearance = 4.0,
  Future<Uint8List?> Function(ImageSource source)? pickImageBytes,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildCommandTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: CopilotPage(
          store: harness.store,
          bottomNavClearance: bottomNavClearance,
          onSendingChanged: harness.sendingStates.add,
          pickImageBytes: pickImageBytes,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CopilotPage 现场阅读节奏、防抢滚与独立追问按钮（迁移 chat_ux_test）', () {
    testWidgets('流式突发分片按约 52ms/字匀速揭示而非瞬间刷屏', (tester) async {
      const reply30 = '一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉';
      final harness = _Harness(
        chunks: const [_ScriptedChunk(Duration(milliseconds: 10), reply30)],
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      await tester.pumpAndSettle();

      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      unawaited(state.submitQuestion('请简要说明撤离口令'));

      await tester.pump(const Duration(milliseconds: 5));
      expect(find.text('水元素思考中…'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 15));
      expect(find.text('水元素思考中…'), findsNothing);
      expect(find.text('一'), findsOneWidget);
      expect(find.text(reply30), findsNothing);

      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('一二'), findsOneWidget);
      expect(find.text(reply30), findsNothing);

      await tester.pump(const Duration(milliseconds: 540));
      expect(find.text('一二三四五六七八九十甲乙'), findsOneWidget);
      expect(find.text(reply30), findsNothing);
      expect(harness.sendingStates, [true]);

      await tester.pumpAndSettle();
      expect(find.text(reply30), findsOneWidget);
      expect(harness.sendingStates, [true, false]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('跨分片截断 <<<FOLLOW_UPS>>> 零闪现，完结后渲染独立 ≥48dp 追问按钮并纯净复制', (
      tester,
    ) async {
      String? copiedClipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedClipboard = (call.arguments as Map<dynamic, dynamic>)['text']
                as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final harness = _Harness(
        chunks: const [
          _ScriptedChunk(Duration(milliseconds: 10), '先断电后破拆\n'),
          _ScriptedChunk(Duration(milliseconds: 20), '<<<FOLLOW'),
          _ScriptedChunk(
            Duration(milliseconds: 20),
            '_UPS>>>\n展开详细破拆步骤\n个人防护注意事项',
          ),
        ],
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      await tester.pumpAndSettle();

      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      unawaited(state.submitQuestion('卷帘门破拆注意什么？'));

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.textContaining('FOLLOW'), findsNothing);
        expect(find.textContaining('<'), findsNothing);
        expect(find.textContaining('展开详细破拆步骤'), findsNothing);
      }

      await tester.pumpAndSettle();
      expect(find.text('先断电后破拆'), findsOneWidget);
      expect(find.text('展开详细破拆步骤'), findsOneWidget);
      expect(find.text('个人防护注意事项'), findsOneWidget);
      expect(find.textContaining('我想进一步确认'), findsNothing);

      final chip1 = find.text('展开详细破拆步骤');
      final chip2 = find.text('个人防护注意事项');
      expect(
        tester
            .getSize(
              find.ancestor(of: chip1, matching: find.byType(ConstrainedBox)).first,
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(
              find.ancestor(of: chip2, matching: find.byType(ConstrainedBox)).first,
            )
            .height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byTooltip('复制').last);
      await tester.pump();
      expect(copiedClipboard, '先断电后破拆');

      await tester.tap(chip1);
      await tester.pumpAndSettle();
      expect(harness.submittedQuestions, ['卷帘门破拆注意什么？', '展开详细破拆步骤']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('智能防抢滚：用户上滑查看前文时流式追加不再强制拉回底部', (tester) async {
      tester.view.physicalSize = const Size(390, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final now = DateTime.now().millisecondsSinceEpoch;
      final history = [
        for (var i = 0; i < 10; i++)
          ChatMessage(
            id: 'h-$i',
            role: i.isEven ? 'user' : 'assistant',
            content: '第 ${i + 1} 条历史消息，用于撑开列表产生充分滚动距离以验证防抢滚行为。',
            createdAt: now - (10 - i) * 60000,
          ),
      ];
      final longReply = List.generate(
        24,
        (i) => '第${i + 1}条火场提示：保持安全距离与气瓶监控。',
      ).join('\n');

      final harness = _Harness(
        initialHistory: history,
        chunks: [_ScriptedChunk(const Duration(milliseconds: 10), longReply)],
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      await tester.pumpAndSettle();

      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      unawaited(state.submitQuestion('请给长回复'));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 400));

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, 260));
      await tester.pump();
      final userScrollPixels = scrollable.position.pixels;
      expect(scrollable.position.extentAfter, greaterThan(64));

      await tester.pump(const Duration(milliseconds: 500));
      expect(
        scrollable.position.pixels,
        lessThan(scrollable.position.maxScrollExtent - 32),
      );
      expect((scrollable.position.pixels - userScrollPixels).abs(), lessThan(40));

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('320dp 窄屏 + 2.0 倍大字号与 360dp + 130% 字号均零溢出', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final now = DateTime.now().millisecondsSinceEpoch;
      final harness = _Harness(
        hasIncidentContext: true,
        initialHistory: [
          ChatMessage(
            id: 'a-long',
            role: 'assistant',
            content:
                '**先控火源并警戒隔离**\n- 上风向警戒50米\n- 严禁直流水直击\n<<<FOLLOW_UPS>>>\n展开高层住宅内攻排烟与防轰燃具体步骤\n穿戴重型防化服和正压式空气呼吸器要求\n气瓶余压低于十兆帕紧急撤离条件说明',
            createdAt: now,
          ),
        ],
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness, textScale: 2.0);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('chat-followup-a-long-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-followup-a-long-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-followup-a-long-2')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 360dp 窄屏 + 130% 系统字号：欢迎态 + 警情胶囊 + 文字输入条
      tester.view.physicalSize = const Size(360 * 3, 760 * 3);
      final welcomeHarness = _Harness(hasIncidentContext: true);
      addTearDown(welcomeHarness.dispose);
      await _pumpCopilotPage(tester, welcomeHarness, textScale: 1.3);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-header')), findsOneWidget);
      expect(find.byKey(const Key('chat-incident-context-pill')), findsOneWidget);
      expect(find.byKey(const Key('chat-disclaimer-footnote')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-mode-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-text-composer')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CopilotPage 并发历史守卫（迁移 chat_history_concurrency_test）', () {
    testWidgets('历史晚到时不会覆盖已经发送的本地消息', (tester) async {
      final historyCompleter = Completer<List<ChatMessage>>();
      final replyCompleter = Completer<String>();
      final harness = _Harness(
        fetchHistoryOverride: () => historyCompleter.future,
        askOverride: (msg, {required onChunk, opId, history = const []}) =>
            replyCompleter.future,
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      final sendFuture = state.submitQuestion('新问题');
      await tester.pump();
      expect(find.text('新问题'), findsOneWidget);
      expect(find.text('水元素思考中…'), findsOneWidget);

      historyCompleter.complete(_staleHistory);
      await tester.pump();
      expect(find.text('旧问题'), findsOneWidget);
      expect(find.text('旧回答'), findsOneWidget);
      expect(find.text('新问题'), findsOneWidget);
      expect(find.text('水元素思考中…'), findsOneWidget);

      replyCompleter.complete('新回答');
      await sendFuture;
      await tester.pump();
      expect(find.text('新回答'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('清空完成后历史晚到也不会恢复已删除的消息', (tester) async {
      final historyCompleter = Completer<List<ChatMessage>>();
      final replyCompleter = Completer<String>();
      final clearCompleter = Completer<void>();
      var clearCalled = false;
      final harness = _Harness(
        fetchHistoryOverride: () => historyCompleter.future,
        askOverride: (msg, {required onChunk, opId, history = const []}) =>
            replyCompleter.future,
        clearOverride: () {
          clearCalled = true;
          return clearCompleter.future;
        },
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      final sendFuture = state.submitQuestion('待清空问题');
      await tester.pump();
      replyCompleter.complete('待清空回答');
      await sendFuture;
      await tester.pump();

      await tester.tap(find.byTooltip('清空问答记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CommandButton, '清空'));
      await tester.pump();
      expect(clearCalled, isTrue);

      clearCompleter.complete();
      await tester.pumpAndSettle();
      expect(find.text('待清空问题'), findsNothing);
      expect(find.text('待清空回答'), findsNothing);

      historyCompleter.complete(_staleHistory);
      await tester.pump();
      expect(find.text('旧问题'), findsNothing);
      expect(find.text('旧回答'), findsNothing);
      expect(find.text('你好，我是水元素'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('发送中的清空入口被禁用，避免与未完成请求交叉', (tester) async {
      final replyCompleter = Completer<String>();
      final harness = _Harness(
        initialHistory: _staleHistory,
        askOverride: (msg, {required onChunk, opId, history = const []}) =>
            replyCompleter.future,
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      await tester.pump();

      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      final sendFuture = state.submitQuestion('进行中的问题');
      await tester.pump();
      final clearButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, DsIcons.clearSweep),
      );
      expect(clearButton.onPressed, isNull);

      replyCompleter.complete('进行中的回答');
      await sendFuture;
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, DsIcons.clearSweep),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('切换警情后旧回复和旧历史不会进入新警情', (tester) async {
      final histA = Completer<List<ChatMessage>>()..complete(const []);
      final histB = Completer<List<ChatMessage>>();
      final replyCompleter = Completer<String>();
      late _Harness harness;
      harness = _Harness(
        fetchHistoryOverride: () =>
            harness.scope.value == 'unit-a|inc-a' ? histA.future : histB.future,
        askOverride: (msg, {required onChunk, opId, history = const []}) =>
            replyCompleter.future,
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      await tester.pump();
      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      final request = state.submitQuestion('警情A问题');
      await tester.pump();

      harness.scope.value = 'unit-a|inc-b';
      histB.complete(const [
        ChatMessage(id: 'b1', role: 'user', content: '警情B历史', createdAt: 1),
      ]);
      await tester.pump();

      replyCompleter.complete('警情A迟到回复');
      await request;
      await tester.pump();

      expect(find.text('警情A问题'), findsNothing);
      expect(find.text('警情A迟到回复'), findsNothing);
      expect(find.text('警情B历史'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CopilotPage 录音降级、拍照识险超限与双主题切主题保草稿', () {
    testWidgets('就地录音实时流失败自动降级、50s 显示预警、60s 自动结束提问', (tester) async {
      final harness = _Harness(
        createRealtimeSession: (_) => _FailingRealtimeSession(),
        transcribeAudio: (bytes, {opId}) async => '语音测试问题',
        chunks: const [_ScriptedChunk(Duration.zero, '语音测试回复')],
      );
      addTearDown(harness.dispose);

      await _pumpCopilotPage(tester, harness);
      final state = tester.state<CopilotPageState>(find.byType(CopilotPage));
      await state.beginRecording();
      await tester.pump();

      expect(harness.audio.startCalls, 1);
      expect(find.byKey(const Key('chat-recording-limit')), findsOneWidget);
      expect(find.textContaining('最长 60 秒'), findsOneWidget);

      await tester.pump(const Duration(seconds: 50));
      expect(find.textContaining('录音还剩 10 秒'), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(harness.submittedQuestions, ['语音测试问题']);
      expect(find.text('语音测试回复'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拍照识险：超 8MB 拦截提示，合规图片走 CommandSheet 并输出 4 段结构化结果', (
      tester,
    ) async {
      final oversizeHarness = _Harness(
        imageCompressor: (_) => Uint8List(CopilotStore.maxVisionBytes + 1),
      );
      addTearDown(oversizeHarness.dispose);

      await _pumpCopilotPage(
        tester,
        oversizeHarness,
        pickImageBytes: (_) async => Uint8List.fromList([1, 2, 3]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chat-vision-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-vision-source-camera')));
      await tester.pumpAndSettle();
      expect(find.text('图片过大，请重新拍摄'), findsOneWidget);
      expect(oversizeHarness.visionQuestions, isEmpty);
      ScaffoldMessenger.of(
        tester.element(find.byType(CopilotPage)),
      ).clearSnackBars();
      await tester.pumpAndSettle();

      // 合规图片完整识险流程
      final validHarness = _Harness();
      addTearDown(validHarness.dispose);
      final sampleImg = Uint8List.fromList(
        img.encodePng(img.Image(width: 240, height: 180)),
      );
      await _pumpCopilotPage(
        tester,
        validHarness,
        pickImageBytes: (_) async => sampleImg,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chat-vision-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-vision-source-gallery')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-vision-prompt-field')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-vision-confirm-send')));
      await tester.pumpAndSettle();

      expect(validHarness.visionQuestions, ['请分析这张图片中与消防救援相关的内容。']);
      expect(find.textContaining('已确认事实'), findsOneWidget);
      expect(find.textContaining('可能风险'), findsOneWidget);
      expect(find.textContaining('待确认事项'), findsOneWidget);
      expect(find.textContaining('建议措施'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('昼白与暗曜切换保持文字输入条草稿不丢失，且警情胶囊与旧历史弹窗工作正常', (tester) async {
      final brightness = ValueNotifier<Brightness>(Brightness.light);
      final harness = _Harness(
        hasIncidentContext: true,
        legacyHistoryOverride: () async => const [
          ChatMessage(id: 'l1', role: 'user', content: '旧通用提问', createdAt: 1),
        ],
      );
      addTearDown(() {
        harness.dispose();
        brightness.dispose();
      });

      await tester.pumpWidget(
        ValueListenableBuilder<Brightness>(
          valueListenable: brightness,
          builder: (context, mode, _) => MaterialApp(
            theme: buildCommandTheme(mode),
            home: Scaffold(body: CopilotPage(store: harness.store)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 验证警情上下文胶囊 >= 48dp 并可点击
      final pillFinder = find.byKey(const Key('chat-incident-context-pill'));
      expect(tester.getSize(pillFinder).height, greaterThanOrEqualTo(48));
      await tester.tap(pillFinder);
      expect(harness.openedIncidentDetails, 1);

      // 切入文字模式并输入草稿
      await tester.tap(find.byKey(const Key('chat-mode-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('chat-text-field')),
        '待发送现场草稿',
      );
      await tester.pump();

      // 切换暗曜再切回昼白：输入模式与草稿完整保留
      brightness.value = Brightness.dark;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-text-composer')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-text-field')))
            .controller
            ?.text,
        '待发送现场草稿',
      );

      brightness.value = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-text-field')))
            .controller
            ?.text,
        '待发送现场草稿',
      );

      // 打开旧版历史通用对话弹窗
      await tester.tap(find.byTooltip('历史通用对话'));
      await tester.pumpAndSettle();
      expect(find.text('历史通用对话'), findsOneWidget);
      expect(find.textContaining('旧通用提问'), findsOneWidget);
      await tester.tap(find.widgetWithText(CommandButton, '关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
