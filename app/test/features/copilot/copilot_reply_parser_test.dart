import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/features/copilot/state/copilot_reply_parser.dart';
import 'package:watchdog/features/copilot/state/copilot_stream_revealer.dart';

void main() {
  group('parseAssistantReply 与 holdbackStreamingTail', () {
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
        parseAssistantReply('先断电再破拆\n<<FOLLOW_UPS', streaming: true).body,
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
        '先断电再破拆\n<<<FOLLOW_UPS>>>\n- 展开详细步骤\n2. **个人防护等级**\n「个人防护等级」\n3、撤离触发条件\n4. 第四个候选被截断',
        streaming: false,
      );
      expect(done.body, '先断电再破拆');
      expect(done.isLegacy, isFalse);
      expect(done.followUps, ['展开详细步骤', '个人防护等级', '撤离触发条件']);
    });

    test('普通小于号如 <10MPa 不被误扣留', () {
      expect(
        parseAssistantReply('余压<10MPa', streaming: true).body,
        '余压<10MPa',
      );
      expect(holdbackStreamingTail('温度<300℃时推进'), '温度<300℃时推进');
    });

    test('超长超过 40 字的候选追问被过滤，纯净复制不含追问协议', () {
      final over40 = List.filled(41, '字').join();
      final raw =
          '正文结论\n<<<FOLLOW_UPS>>>\n$over40\n有效追问一\n有效追问二';
      final parsed = parseAssistantReply(raw, streaming: false);
      expect(parsed.body, '正文结论');
      expect(parsed.followUps, ['有效追问一', '有效追问二']);
      expect(extractCleanAssistantBody(raw), '正文结论');
    });

    test('向下兼容旧版 追问：/关键追问： 协议并在流式尾部防闪现', () {
      expect(
        parseAssistantReply('先控火源\n关键追', streaming: true).body,
        '先控火源',
      );
      expect(
        parseAssistantReply('先控火源\n**关键追问**：', streaming: true).body,
        '先控火源',
      );
      expect(
        parseAssistantReply('先控火源\n追问：后续如何排烟', streaming: true).followUps,
        isEmpty,
      );

      final legacySingle = parseAssistantReply(
        '先控火源\n**关键追问**：是否确认有人员被困？',
        streaming: false,
      );
      expect(legacySingle.body, '先控火源');
      expect(legacySingle.isLegacy, isTrue);
      expect(legacySingle.followUps, ['是否确认有人员被困？']);
      expect(
        extractCleanAssistantBody('先控火源\n**关键追问**：是否确认有人员被困？'),
        '先控火源',
      );

      final emptyRest = parseAssistantReply('先控火源\n追问：   ', streaming: false);
      expect(emptyRest.body, '先控火源\n追问：   ');
      expect(emptyRest.followUps, isEmpty);
    });
  });

  group('CopilotStreamRevealer 匀速揭示器', () {
    testWidgets('立即模式（charInterval <= 0）同步输出全部可见正文', (tester) async {
      final revealed = <String>[];
      String? completed;
      final revealer = CopilotStreamRevealer(
        vsync: const TestVSync(),
        charInterval: Duration.zero,
        parseVisibleBody: (raw, {required streaming}) =>
            parseAssistantReply(raw, streaming: streaming).body,
        onReveal: (_, text) => revealed.add(text),
        onComplete: (_, full) => completed = full,
      );
      addTearDown(revealer.dispose);

      revealer.begin('s1');
      revealer.pushChunk('s1', '断电破拆\n<<<FOLLOW');
      expect(revealed.last, '断电破拆');
      revealer.pushChunk('s1', '_UPS>>>\n细节步骤');
      expect(revealed.last, '断电破拆');
      revealer.finishNetwork('s1', '断电破拆\n<<<FOLLOW_UPS>>>\n细节步骤');
      expect(completed, '断电破拆\n<<<FOLLOW_UPS>>>\n细节步骤');
      expect(revealer.isActive, isFalse);
    });

    testWidgets('52ms 节拍首字零延迟、支持字素簇并在完结后补完尾部', (tester) async {
      final revealed = <String>[];
      String? completed;
      final revealer = CopilotStreamRevealer(
        vsync: tester,
        charInterval: const Duration(milliseconds: 52),
        parseVisibleBody: (raw, {required streaming}) =>
            parseAssistantReply(raw, streaming: streaming).body,
        onReveal: (_, text) => revealed.add(text),
        onComplete: (_, full) => completed = full,
      );
      addTearDown(revealer.dispose);

      // 包含 emoji 字素簇（由多个 UTF-16 码元组成），确保按 Characters 不截断。
      const sample = '🚒火场警戒';
      revealer.begin('s2');
      revealer.pushChunk('s2', sample);
      expect(revealed, ['🚒']);
      expect(completed, isNull);

      revealer.finishNetwork('s2', '$sample\n<<<FOLLOW_UPS>>>\n追问甲');
      expect(completed, isNull);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(revealed.last, '🚒火');

      await tester.pump(const Duration(milliseconds: 260));
      expect(completed, '$sample\n<<<FOLLOW_UPS>>>\n追问甲');
      expect(revealer.isActive, isFalse);
    });
  });
}
