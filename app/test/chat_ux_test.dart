import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/features/copilot/state/copilot_reply_parser.dart';

void main() {
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
}
