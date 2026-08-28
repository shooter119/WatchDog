import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/services/chat_history.dart';

void main() {
  test('并发追加不会因读改写竞态丢失问答', () async {
    SharedPreferences.setMockInitialValues({});

    await Future.wait([
      ChatHistory.appendExchange(question: '问题一', reply: '回答一', createdAt: 1),
      ChatHistory.appendExchange(question: '问题二', reply: '回答二', createdAt: 2),
    ]);

    final messages = await ChatHistory.load();
    expect(messages.map((message) => message.content).toList(), [
      '问题一',
      '回答一',
      '问题二',
      '回答二',
    ]);
  });

  test('清空会在已排队写入之后生效', () async {
    SharedPreferences.setMockInitialValues({});
    final append = ChatHistory.appendExchange(
      question: '待清空问题',
      reply: '待清空回答',
      createdAt: 3,
    );
    final clear = ChatHistory.clear();
    await Future.wait([append, clear]);

    expect(await ChatHistory.load(), isEmpty);
  });
}
