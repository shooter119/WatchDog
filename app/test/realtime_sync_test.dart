import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/sync_reducer.dart';

SyncEvent event({
  required String sequence,
  String stream = 'incident',
  String eventId = 'event-1',
  String eventType = 'note.created',
}) => SyncEvent(
  stream: stream,
  sequence: sequence,
  eventId: eventId,
  eventType: eventType,
  occurredAt: 1,
  payload: const {},
);

void main() {
  test('实时 reducer 接受十进制字符串游标的连续事件', () {
    final reducer = SyncReducer();
    expect(reducer.accept(event(sequence: '42'), expectedCursor: '41'), isTrue);
    expect(reducer.accept(event(sequence: '43', eventId: 'event-2'), expectedCursor: '42'), isTrue);
  });

  test('实时 reducer 拒绝重复事件和游标缺口', () {
    final reducer = SyncReducer();
    final first = event(sequence: '8');
    expect(reducer.accept(first, expectedCursor: '7'), isTrue);
    expect(reducer.accept(first, expectedCursor: '8'), isFalse);
    expect(reducer.accept(event(sequence: '10', eventId: 'event-10'), expectedCursor: '8'), isFalse);
  });

  test('单位流和警情流分别维护连续游标', () {
    final reducer = SyncReducer();
    expect(reducer.accept(event(sequence: '2', stream: 'unit'), expectedCursor: '1'), isTrue);
    expect(reducer.accept(event(sequence: '1', stream: 'incident', eventId: 'incident-1'), expectedCursor: '0'), isTrue);
  });

  test('名单快照转换为本地模型', () {
    final roster = <String, dynamic>{
      'firefighters': [
        {'id': 'f1', 'name': '张伟', 'source': 'builtin'},
      ],
      'hotwords': [
        {'id': 'h1', 'word': '空气呼吸器', 'source': 'user'},
      ],
    };
    expect(SyncReducer.rosterNames(roster).single.name, '张伟');
    expect(SyncReducer.rosterHotwords(roster).single.word, '空气呼吸器');
  });
}
