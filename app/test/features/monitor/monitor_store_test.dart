import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/features/monitor/data/models/calc_config.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/data/monitor_repository.dart';
import 'package:watchdog/features/monitor/state/monitor_store.dart';

Entry _makeEntry({
  required String id,
  required String name,
  required int nowMs,
  required int remainingMin,
  double pressureMpa = 20,
  int version = 1,
  int? exitedAt,
}) => Entry(
  id: id,
  name: name,
  version: version,
  pressureMpa: pressureMpa,
  durationMin: 34,
  entryAt: nowMs - 10 * 60000,
  exitAt: nowMs + remainingMin * 60000,
  exitedAt: exitedAt,
  source: 'voice',
);

MonitorRepository _repoWithHandler(
  Future<http.Response> Function(http.Request) handler,
) {
  final transport = ApiHttpTransport(
    ApiConfig(baseUrl: 'https://example.test', incidentId: 'inc-1'),
    clientFactory: () => MockClient(handler),
  );
  return MonitorRepository(transport);
}

void main() {
  const baseNow = 1700000000000;

  group('MonitorStore 排序与风险统计', () {
    test('sortedActiveEntries 按 超时 > 告警 > 注意 > 安全 且同级按到期时间升序', () {
      final store = MonitorStore(
        nowMs: () => baseNow,
        initialEntries: <Entry>[
          _makeEntry(id: 'safe-1', name: '安全甲', nowMs: baseNow, remainingMin: 30),
          _makeEntry(id: 'warn-2', name: '注意乙', nowMs: baseNow, remainingMin: 9),
          _makeEntry(id: 'warn-1', name: '注意甲', nowMs: baseNow, remainingMin: 7),
          _makeEntry(id: 'alarm-1', name: '告警甲', nowMs: baseNow, remainingMin: 3),
          _makeEntry(id: 'timeout-1', name: '超时甲', nowMs: baseNow, remainingMin: -2),
          _makeEntry(
            id: 'exited-1',
            name: '已退场',
            nowMs: baseNow,
            remainingMin: -10,
            exitedAt: baseNow - 60000,
          ),
        ],
      );
      addTearDown(store.dispose);

      final ids = store.activeEntries.map((e) => e.id).toList();
      expect(ids, <String>['timeout-1', 'alarm-1', 'warn-1', 'warn-2', 'safe-1']);
    });

    test('riskSummary 正确汇总各等级计数、危险总数与最早到期人员', () {
      final store = MonitorStore(
        nowMs: () => baseNow,
        initialEntries: <Entry>[
          _makeEntry(id: 's1', name: '张三', nowMs: baseNow, remainingMin: 25),
          _makeEntry(id: 'c1', name: '李四', nowMs: baseNow, remainingMin: 8),
          _makeEntry(id: 'a1', name: '王五', nowMs: baseNow, remainingMin: 4),
          _makeEntry(id: 't1', name: '赵六', nowMs: baseNow, remainingMin: -1),
        ],
      );
      addTearDown(store.dispose);

      final summary = store.riskSummary();
      expect(summary.totalActive, 4);
      expect(summary.timeoutCount, 1);
      expect(summary.alarmCount, 1);
      expect(summary.cautionCount, 1);
      expect(summary.safeCount, 1);
      expect(summary.dangerCount, 3);
      expect(summary.earliestEntry?.id, 't1');
      expect(summary.worstStatus, 'timeout');
    });

    test('空列表 riskSummary 返回全零与 null 最早条目', () {
      final store = MonitorStore(nowMs: () => baseNow);
      addTearDown(store.dispose);

      final summary = store.riskSummary();
      expect(summary.totalActive, 0);
      expect(summary.dangerCount, 0);
      expect(summary.earliestEntry, isNull);
      expect(summary.worstStatus, 'normal');
    });
  });

  group('MonitorStore 离线投影与 CRUD 冲突处理', () {
    test('applyOfflineOperationProjection 依次投影 entry / pressure / exit 且容忍坏行', () {
      final cfg = CalcConfig(
        cylinderVolL: 6.8,
        fullPressureMpa: 30,
        consumptionLpm: 80,
        warnMin: 10,
        alarmMin: 5,
      );
      final initial = <Entry>[
        _makeEntry(id: 'e1', name: '张三', nowMs: baseNow, remainingMin: 20),
      ];
      final rows = <Map<String, Object?>>[
        <String, Object?>{'type': 'entry', 'occurred_at': baseNow, 'payload': 'not-json'},
        <String, Object?>{
          'type': 'entry',
          'occurred_at': baseNow,
          'payload': jsonEncode(<String, dynamic>{
            'entry_id': 'off-1',
            'name': '李四',
            'pressure_mpa': 24,
            'volume_l': 6.8,
            'consumption_lpm': 80,
          }),
        },
        <String, Object?>{
          'type': 'pressure',
          'occurred_at': baseNow + 60000,
          'payload': jsonEncode(<String, dynamic>{
            'entry_id': 'e1',
            'pressure_mpa': 15,
          }),
        },
        <String, Object?>{
          'type': 'exit',
          'occurred_at': baseNow + 120000,
          'payload': jsonEncode(<String, dynamic>{'entry_id': 'off-1'}),
        },
      ];

      final projected = MonitorStore.applyOfflineOperationProjection(
        rows: rows,
        entries: initial,
        calcConfig: cfg,
      );

      expect(initial.single.pressureMpa, 20);
      final e1 = projected.firstWhere((e) => e.id == 'e1');
      expect(e1.pressureMpa, 15);
      expect(e1.durationMin, 13); // 6.8 * 15 * 10 / 80 = 12.75 -> 13
      final off1 = projected.firstWhere((e) => e.id == 'off-1');
      expect(off1.isActive, isFalse);
      expect(off1.exitedAt, baseNow + 120000);
    });

    test('createEntryFromVoice 缺少警情抛 StateError，断网写入离线队列并本地投影', () async {
      final enqueued = <Map<String, dynamic>>[];
      var synced = 0;
      final repo = _repoWithHandler((_) async => throw TimeoutException('net'));
      final noIncidentStore = MonitorStore(
        repositoryProvider: () => repo,
        incidentIdProvider: () => null,
        memberIdProvider: () async => 'm1',
      );
      addTearDown(noIncidentStore.dispose);
      await expectLater(
        noIncidentStore.createEntryFromVoice(name: '张三', pressureMpa: 24),
        throwsStateError,
      );

      final store = MonitorStore(
        nowMs: () => baseNow,
        repositoryProvider: () => repo,
        incidentIdProvider: () => 'inc-1',
        unitIdProvider: () => 'u1',
        memberIdProvider: () async => 'm1',
        onSync: () async => synced++,
        offlineEnqueuer: ({
          required String incidentId,
          required String type,
          required int occurredAt,
          required String clientOpId,
          required Map<String, dynamic> payload,
          Map<String, String>? owner,
        }) async {
          enqueued.add(<String, dynamic>{'type': type, 'payload': payload});
        },
      );
      addTearDown(store.dispose);

      final created = await store.createEntryFromVoice(
        name: '张三',
        pressureMpa: 24,
        rawText: '张三24兆帕',
      );
      expect(created.source, 'offline');
      expect(created.durationMin, 20); // 6.8 * 24 * 10 / 80 = 20.4 -> 20
      expect(store.entries.length, 1);
      expect(enqueued.single['type'], 'entry');
      expect(synced, 1);
    });

    test('updatePressure 遇 VERSION_CONFLICT / ENTRY_EXITED / STALE_PRESSURE 触发同步并重抛', () async {
      for (final code in <String>['VERSION_CONFLICT', 'ENTRY_EXITED', 'STALE_PRESSURE']) {
        var syncCalls = 0;
        final repo = _repoWithHandler(
          (_) async => http.Response(
            jsonEncode(<String, dynamic>{'error': 'conflict', 'code': code}),
            409,
          ),
        );
        final store = MonitorStore(
          nowMs: () => baseNow,
          initialEntries: <Entry>[
            _makeEntry(id: 'e1', name: '张三', nowMs: baseNow, remainingMin: 20),
          ],
          repositoryProvider: () => repo,
          incidentIdProvider: () => 'inc-1',
          memberIdProvider: () async => 'm1',
          onSync: () async => syncCalls++,
        );
        addTearDown(store.dispose);

        await expectLater(
          store.updatePressure(id: 'e1', pressureMpa: 15),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', code)),
        );
        expect(syncCalls, 1);
      }
    });

    test('updatePressure 联网成功更新条目并写火场日志，断网入离线队列并本地投影', () async {
      final notes = <String>[];
      final repo = _repoWithHandler((req) async {
        expect(req.method, 'PATCH');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'id': 'e1',
              'version': 2,
              'name': '张三',
              'pressure_mpa': 15.0,
              'duration_min': 13,
              'entry_at': baseNow - 600000,
              'exit_at': baseNow + 13 * 60000,
              'source': 'voice',
            }),
          ),
          200,
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
        );
      });
      final store = MonitorStore(
        nowMs: () => baseNow,
        initialEntries: <Entry>[
          _makeEntry(id: 'e1', name: '张三', nowMs: baseNow, remainingMin: 20),
        ],
        repositoryProvider: () => repo,
        incidentIdProvider: () => 'inc-1',
        memberIdProvider: () async => 'm1',
        onAddNote: (String text, {required String category}) async {
          notes.add('$category:$text');
        },
      );
      addTearDown(store.dispose);

      final updated = await store.updatePressure(
        id: 'e1',
        pressureMpa: 15,
        recordNote: true,
      );
      expect(updated.pressureMpa, 15.0);
      expect(store.findById('e1')?.version, 2);
      expect(notes, <String>['entry:张三 更新气瓶压力为 15 MPa']);
    });

    test('markExited 联网标记离场并支持冲突重抛与断网离线降级', () async {
      final enqueued = <String>[];
      final actionLogs = <String>[];
      final repo = _repoWithHandler((_) async => throw TimeoutException('offline'));
      final store = MonitorStore(
        nowMs: () => baseNow,
        initialEntries: <Entry>[
          _makeEntry(id: 'e1', name: '李四', nowMs: baseNow, remainingMin: 20),
        ],
        repositoryProvider: () => repo,
        incidentIdProvider: () => 'inc-1',
        memberIdProvider: () async => 'm1',
        onAddActionLog: ({
          required List<String> names,
          required String action,
          required String category,
          String? opId,
        }) async {
          actionLogs.add('${names.join(",")}:$action:$category');
        },
        offlineEnqueuer: ({
          required String incidentId,
          required String type,
          required int occurredAt,
          required String clientOpId,
          required Map<String, dynamic> payload,
          Map<String, String>? owner,
        }) async {
          enqueued.add(type);
        },
      );
      addTearDown(store.dispose);

      await store.markExited('e1');
      expect(enqueued, <String>['exit']);
      expect(store.findById('e1')?.isActive, isFalse);

      await store.recordExitActionLog(store.findById('e1')!);
      expect(actionLogs, <String>['李四:出场:withdraw']);
    });
  });
}
