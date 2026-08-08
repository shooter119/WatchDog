import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';

void main() {
  group('SseLineParser 流式解析', () {
    test('单 chunk 内完整事件', () {
      final p = SseLineParser();
      final ev = p.push('data: {"content":"你好"}\n\n');
      expect(ev.length, 1);
      expect(ev.first.content, '你好');
      expect(ev.first.done, isFalse);
    });

    test('跨 chunk 边界半行缓冲', () {
      final p = SseLineParser();
      expect(p.push('data: {"content":"你').length, 0);
      final ev = p.push('好"}\n\n');
      expect(ev.length, 1);
      expect(ev.first.content, '你好');
    });

    test('多个事件一次到达按顺序产出', () {
      final p = SseLineParser();
      final ev = p.push('data: {"content":"先"}\n\ndata: {"content":"后"}\n\n');
      expect(ev.map((e) => e.content).toList(), ['先', '后']);
    });

    test('[DONE] 结束事件', () {
      final p = SseLineParser();
      final ev = p.push('data: {"content":"末"}\n\ndata: [DONE]\n\n');
      expect(ev.length, 2);
      expect(ev[0].content, '末');
      expect(ev[1].done, isTrue);
    });

    test('服务端错误事件', () {
      final p = SseLineParser();
      final ev = p.push('data: {"error":"LLM 未配置"}\n\n');
      expect(ev.length, 1);
      expect(ev.first.error, 'LLM 未配置');
    });

    test('忽略非 data 行与无法解析的行', () {
      final p = SseLineParser();
      final ev = p.push('keep-alive: 1\n: comment\ndata: not-json\n\ndata: {"content":"ok"}\n\n');
      expect(ev.map((e) => e.content).toList(), ['ok']);
    });

    test('CRLF 行尾（\\r\\n）正常解析', () {
      final p = SseLineParser();
      final ev = p.push('data: {"content":"a"}\r\ndata: {"content":"b"}\r\n\r\n');
      expect(ev.map((e) => e.content).toList(), ['a', 'b']);
    });
  });
}
