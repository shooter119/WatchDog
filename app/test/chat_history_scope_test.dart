import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/chat_history.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('不同单位警情互不串历史，清空不会影响其他作用域', () async {
    await ChatHistory.appendExchange(
      scope: 'server|unit-a|user|incident-a',
      question: '甲警情',
      reply: '甲回复',
      createdAt: 1,
    );
    await ChatHistory.appendExchange(
      scope: 'server|unit-a|user|incident-b',
      question: '乙警情',
      reply: '乙回复',
      createdAt: 2,
    );
    await ChatHistory.appendExchange(
      question: '旧通用',
      reply: '旧回复',
      createdAt: 3,
    );
    expect(
      (await ChatHistory.load(
        scope: 'server|unit-a|user|incident-a',
      )).first.content,
      '甲警情',
    );
    expect(
      await ChatHistory.load(scope: 'server|unit-b|user|incident-a'),
      isEmpty,
    );
    expect((await ChatHistory.load()).first.content, '旧通用');
    await ChatHistory.clear(scope: 'server|unit-a|user|incident-a');
    expect(
      await ChatHistory.load(scope: 'server|unit-a|user|incident-a'),
      isEmpty,
    );
    expect(
      (await ChatHistory.load(scope: 'server|unit-a|user|incident-b')).length,
      2,
    );
  });
}
