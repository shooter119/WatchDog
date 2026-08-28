import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/offline_queue.dart';

void main() {
  test('损坏 payload 被隔离保留，不能阻塞其他警情和合法操作', () async {
    final quarantined = <Map<String, Object?>>[];
    final uploads = <String, List<String>>{};
    final removed = <String>[];

    final rows = <Map<String, Object?>>[
      {
        'id': 1,
        'incident_id': 'incident-a',
        'type': 'note',
        'occurred_at': 100,
        'client_op_id': 'bad-op',
        'payload': '{"text":',
        'created_at': 100,
      },
      {
        'id': 2,
        'incident_id': 'incident-a',
        'type': 'note',
        'occurred_at': 101,
        'client_op_id': 'valid-a',
        'payload': '{"text":"合法记录"}',
        'created_at': 101,
      },
      {
        'id': 3,
        'incident_id': 'incident-b',
        'type': 'entry',
        'occurred_at': 102,
        'client_op_id': 'valid-b',
        'payload': '{"name":"张伟"}',
        'created_at': 102,
      },
    ];

    await drainOfflineOperationRows(
      rows,
      upload: (incidentId, operations) async {
        uploads[incidentId] = operations
            .map((operation) => operation['client_op_id'].toString())
            .toList();
        return {
          'results': [
            for (final operation in operations)
              {'client_op_id': operation['client_op_id'], 'accepted': true},
          ],
        };
      },
      quarantine: (row, _) async => quarantined.add(row),
      removeAccepted: (clientOpId) async => removed.add(clientOpId),
    );

    expect(uploads, {
      'incident-a': ['valid-a'],
      'incident-b': ['valid-b'],
    });
    expect(removed, containsAllInOrder(['valid-a', 'valid-b']));
    expect(quarantined, hasLength(1));
    expect(quarantined.single['id'], 1);
    expect(quarantined.single['client_op_id'], 'bad-op');
    expect(quarantined.single['payload'], '{"text":');
    expect(uploads.values.expand((ids) => ids), isNot(contains('bad-op')));
  });

  test('隔离失败时保留原行，且仍继续补传合法行', () async {
    final uploads = <String>[];
    final rows = <Map<String, Object?>>[
      {
        'id': 10,
        'incident_id': 'incident-a',
        'type': 'note',
        'occurred_at': 100,
        'client_op_id': 'bad-op',
        'payload': 'not-json',
        'created_at': 100,
      },
      {
        'id': 11,
        'incident_id': 'incident-b',
        'type': 'note',
        'occurred_at': 101,
        'client_op_id': 'valid-b',
        'payload': '{"text":"合法记录"}',
        'created_at': 101,
      },
    ];

    await drainOfflineOperationRows(
      rows,
      upload: (incidentId, _) async {
        uploads.add(incidentId);
        return {
          'results': [
            {'client_op_id': 'valid-b', 'accepted': true},
          ],
        };
      },
      quarantine: (_, __) async => throw StateError('隔离存储暂不可用'),
      removeAccepted: (_) async {},
    );

    expect(uploads, ['incident-b']);
    expect(rows.first['payload'], 'not-json');
  });
}
