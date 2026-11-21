import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/chat_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

class _ScriptedChunk {
  final Duration delay;
  final String delta;
  const _ScriptedChunk(this.delay, this.delta);
}

class _ScriptedChatController extends AppController {
  final List<ChatMessage> initialHistory;
  final List<_ScriptedChunk> chunks;
  final List<String> submittedQuestions = [];
  final List<bool> sendingStates = [];

  _ScriptedChatController({
    this.initialHistory = const [],
    this.chunks = const [],
  });

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => initialHistory;

  @override
  Future<String> askAssistantStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
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
  }

  @override
  void cancelAssistantRequest() {}
}

class _NoopAudioService extends AudioService {
  @override
  Future<void> dispose() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('parseAssistantReply 与流式拦截', () {
    test('流式阶段扣留 <<<FOLLOW_UPS>>> 不完整前缀并完整隐藏候选区', () {
      expect(
        parseAssistantReply('先断电再破拆\n<', streaming: true).body,
        '先断电再破拆',
      );
      expect(
        parseAssistantReply('先断电再破拆\n<<<FOLLOW', streaming: true).body,
        '先断电再破拆',
      );
      expect(
        parseAssistantReply('先断电再破拆\n<<<FOLLOW_UPS>>', streaming: true).body,
        '先断电再破拆',
      );
      expect(
        parseAssistantReply(
          '先断电再破拆\n<<<FOLLOW_UPS>>>\n展开详细步骤',
          streaming: true,
        ).followUps,
        isEmpty,
      );

      final done = parseAssistantReply(
        '先断电再破拆\n<<<FOLLOW_UPS>>>\n- 展开详细步骤\n2. 个人防护等级\n个人防护等级',
        streaming: false,
      );
      expect(done.body, '先断电再破拆');
      expect(done.isLegacy, isFalse);
      expect(done.followUps, ['展开详细步骤', '个人防护等级']);
    });

    test('普通小于号如 <10MPa 不被误扣留', () {
      expect(
        parseAssistantReply('余压<10MPa', streaming: true).body,
        '余压<10MPa',
      );
    });
  });

  group('ChatPage 现场阅读节奏、防抢滚与独立追问按钮', () {
    testWidgets('流式突发分片按约 52ms/字匀速揭示而非瞬间刷屏', (tester) async {
      const reply30 = '一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉';
      expect(reply30.length, 30);

      final controller = _ScriptedChatController(
        chunks: const [_ScriptedChunk(Duration(milliseconds: 10), reply30)],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ChatPage(
              controller: controller,
              audioService: _NoopAudioService(),
              onSendingChanged: controller.sendingStates.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<ChatPageState>(find.byType(ChatPage));
      unawaited(state.submitQuestion('请简要说明撤离口令'));

      await tester.pump(const Duration(milliseconds: 5));
      expect(find.text('水元素思考中…'), findsOneWidget);

      // t=20ms: 首个字符立即上屏（零首字等待），并锚定 Ticker 起始帧
      await tester.pump(const Duration(milliseconds: 15));
      expect(find.text('水元素思考中…'), findsNothing);
      expect(find.text('一'), findsOneWidget);
      expect(find.text(reply30), findsNothing);

      // +60ms: 52ms 间隔下约揭示第 2 个字，远未刷出全部 30 字
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('一二'), findsOneWidget);
      expect(find.text(reply30), findsNothing);

      // +540ms（累计 ~600ms）: 约揭示到第 12 字（1 + 600 ~/ 52 = 12）
      await tester.pump(const Duration(milliseconds: 540));
      expect(find.text('一二三四五六七八九十甲乙'), findsOneWidget);
      expect(find.text(reply30), findsNothing);
      expect(controller.sendingStates, [true]);

      // 等匀速揭示全部完成
      await tester.pumpAndSettle();
      expect(find.text(reply30), findsOneWidget);
      expect(controller.sendingStates, [true, false]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('跨分片截断 <<<FOLLOW_UPS>>> 零闪现，完结后渲染独立多按钮并支持纯净复制', (tester) async {
      String? copiedClipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            copiedClipboard = args['text'] as String?;
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

      final controller = _ScriptedChatController(
        chunks: const [
          _ScriptedChunk(Duration(milliseconds: 10), '先断电后破拆\n'),
          _ScriptedChunk(Duration(milliseconds: 20), '<<<FOLLOW'),
          _ScriptedChunk(
            Duration(milliseconds: 20),
            '_UPS>>>\n展开详细破拆步骤\n个人防护注意事项',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ChatPage(
              controller: controller,
              audioService: _NoopAudioService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<ChatPageState>(find.byType(ChatPage));
      unawaited(state.submitQuestion('卷帘门破拆注意什么？'));

      // 推进流式阶段，跨分片边界时气泡不得出现任何标记字符或追问文字
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
      expect(tester.getSize(find.ancestor(of: chip1, matching: find.byType(ConstrainedBox)).first).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.ancestor(of: chip2, matching: find.byType(ConstrainedBox)).first).height, greaterThanOrEqualTo(48));

      // 点击复制按钮仅复制纯净正文
      await tester.tap(find.byTooltip('复制').last);
      await tester.pump();
      expect(copiedClipboard, '先断电后破拆');

      // 点击第一颗独立追问按钮发起新提问
      await tester.tap(chip1);
      await tester.pumpAndSettle();
      expect(controller.submittedQuestions, ['卷帘门破拆注意什么？', '展开详细破拆步骤']);
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

      final controller = _ScriptedChatController(
        initialHistory: history,
        chunks: [_ScriptedChunk(const Duration(milliseconds: 10), longReply)],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ChatPage(
              controller: controller,
              audioService: _NoopAudioService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<ChatPageState>(find.byType(ChatPage));
      unawaited(state.submitQuestion('请给长回复'));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 400));

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      // 模拟用户手动下拉查看上方历史（页面内容向下拖、视口向上滚动）
      await tester.drag(find.byType(ListView), const Offset(0, 260));
      await tester.pump();
      final userScrollPixels = scrollable.position.pixels;
      expect(scrollable.position.extentAfter, greaterThan(64));

      // 继续推进流式字符揭示，验证不会被抢滚回 maxScrollExtent
      await tester.pump(const Duration(milliseconds: 500));
      expect(scrollable.position.pixels, lessThan(scrollable.position.maxScrollExtent - 32));
      expect((scrollable.position.pixels - userScrollPixels).abs(), lessThan(40));

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('320dp 窄屏与 2.0 倍大字号下 3 个长追问按钮不发生布局溢出', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final now = DateTime.now().millisecondsSinceEpoch;
      final controller = _ScriptedChatController(
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

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2.0),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: ChatPage(
              controller: controller,
              audioService: _NoopAudioService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('chat-followup-a-long-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-followup-a-long-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-followup-a-long-2')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
