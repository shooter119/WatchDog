import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/org_directory.dart';
import 'package:watchdog/services/sync_reducer.dart';

void main() {
  test('旧快照没有消防站字段时保留已缓存站点', () {
    final directory = OrgDirectory()
      ..stations = const [];
    directory.applySnapshot(
      roster: {
        'firefighters': [
          {'id': 'f1', 'name': '张伟', 'source': 'builtin'},
        ],
        'hotwords': [
          {'id': 'h1', 'word': '示例大队', 'source': 'builtin'},
        ],
      },
    );
    directory.applySnapshot(
      stations: [
        {'id': 's1', 'name': '示例路站'},
      ],
    );
    directory.applySnapshot(roster: {
      'firefighters': [
        {'id': 'f1', 'name': '张伟', 'source': 'builtin'},
      ],
      'hotwords': [
        {'id': 'h1', 'word': '示例大队', 'source': 'builtin'},
      ],
    });
    expect(directory.stations.map((item) => item.name), ['示例路站']);
  });

  test('实时事件更新本组织名单和消防站，并刷新识别热词', () {
    final directory = OrgDirectory();
    expect(
      directory.applyEvent(SyncEvent(
        stream: 'unit',
        sequence: '1',
        eventId: 'e1',
        eventType: 'roster.firefighter_added',
        occurredAt: 1,
        aggregateId: 'f1',
        payload: {'id': 'f1', 'name': '张伟', 'source': 'builtin'},
      )),
      isTrue,
    );
    expect(
      directory.applyEvent(SyncEvent(
        stream: 'unit',
        sequence: '2',
        eventId: 'e2',
        eventType: 'roster.station_added',
        occurredAt: 2,
        aggregateId: 's1',
        payload: {'id': 's1', 'name': '示例路站'},
      )),
      isTrue,
    );
    expect(directory.parserNames, ['张伟']);
    expect(directory.asrTerms, containsAll(['张伟', '示例路站', '内攻']));
    expect(
      directory.applyEvent(SyncEvent(
        stream: 'unit',
        sequence: '3',
        eventId: 'e3',
        eventType: 'roster.station_removed',
        occurredAt: 3,
        aggregateId: 's1',
        payload: {'id': 's1', 'deleted': true},
      )),
      isTrue,
    );
    expect(directory.stations, isEmpty);
    expect(directory.asrTerms, isNot(contains('示例路站')));
    expect(directory.firefighters.single.name, '张伟');
  });

  test('未知实时事件和空名单不会把通用模式弄崩溃', () {
    final directory = OrgDirectory();
    expect(
      directory.applyEvent(SyncEvent(
        stream: 'unit',
        sequence: '1',
        eventId: 'e1',
        eventType: 'roster.unknown',
        occurredAt: 1,
        payload: const {},
      )),
      isFalse,
    );
    directory.applySnapshot(roster: {'firefighters': [], 'hotwords': []}, stations: []);
    expect(directory.parserNames, isEmpty);
    expect(directory.asrTerms, contains('搜救'));
    expect(directory.asrTerms, isNot(contains('张伟')));
  });
}
