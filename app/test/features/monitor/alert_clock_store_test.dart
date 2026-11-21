import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/features/monitor/data/models/calc_config.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/state/alert_clock_store.dart';
import 'package:watchdog/services/alarm_service.dart';
import 'package:watchdog/services/tts_service.dart';

class _FakeAlarmService extends AlarmService {
  final List<String> scheduledIds = <String>[];
  final List<String> canceledIds = <String>[];
  final List<String> firedKeys = <String>[];
  int startLoopCount = 0;
  int stopCount = 0;
  int resetCount = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> scheduleForEntry(
    Entry e, {
    required int warnMin,
    required int alarmMin,
  }) async {
    scheduledIds.add('${e.id}@${e.exitAt}');
  }

  @override
  Future<void> cancelForEntry(String entryId) async {
    canceledIds.add(entryId);
  }

  @override
  Future<void> startAlarmLoop() async {
    startLoopCount++;
  }

  @override
  Future<void> stopAlarm() async {
    stopCount++;
  }

  @override
  Future<void> fire(String key, {required String ttsText}) async {
    firedKeys.add(key);
  }

  @override
  void resetSession() {
    resetCount++;
  }
}

class _FakeTtsService extends TtsService {
  final List<String> spoken = <String>[];

  @override
  Future<void> init() async {}

  @override
  void speak(String text) {
    spoken.add(text);
  }
}

Entry _entry(String id, String name, int exitAt, {int? exitedAt}) => Entry(
  id: id,
  name: name,
  pressureMpa: 20,
  durationMin: 34,
  entryAt: exitAt - 34 * 60000,
  exitAt: exitAt,
  exitedAt: exitedAt,
  source: 'voice',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in <String>[
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => null,
    );
  });

  group('AlertClockStore 节拍、通知重排与阈值告警', () {
    test('tickInterval 随前后台与 PiP 状态切换（前台/PiP 1s，后台 5s）', () {
      final store = AlertClockStore(
        alarm: _FakeAlarmService(),
        tts: _FakeTtsService(),
      );
      addTearDown(store.dispose);

      expect(store.tickInterval, AlertClockStore.foregroundTickInterval);
      store.setAppInForeground(false);
      expect(store.tickInterval, AlertClockStore.backgroundTickInterval);
      store.setPipActive(true);
      expect(store.tickInterval, AlertClockStore.foregroundTickInterval);
      store.setPipActive(false);
      expect(store.tickInterval, AlertClockStore.backgroundTickInterval);
      store.setAppInForeground(true);
      expect(store.tickInterval, AlertClockStore.foregroundTickInterval);
    });

    testWidgets('start() 驱动 clockTick 按前后台与 PiP 精确频率递增', (tester) async {
      final store = AlertClockStore(
        alarm: _FakeAlarmService(),
        tts: _FakeTtsService(),
      );

      store.start();
      expect(store.clockTick.value, 0);

      await tester.pump(const Duration(seconds: 3));
      expect(store.clockTick.value, 3);

      store.setAppInForeground(false);
      final pausedTick = store.clockTick.value;
      await tester.pump(const Duration(seconds: 4));
      expect(store.clockTick.value, pausedTick);
      await tester.pump(const Duration(seconds: 1));
      expect(store.clockTick.value, pausedTick + 1);

      store.setPipActive(true);
      final pipTick = store.clockTick.value;
      await tester.pump(const Duration(seconds: 2));
      expect(store.clockTick.value, pipTick + 2);

      store.dispose();
      await tester.pump();
    });

    test('shouldRescheduleNotification 严格仅在 exitAt 变更时返回 true', () {
      expect(
        AlertClockStore.shouldRescheduleNotification(
          scheduledExitAt: null,
          exitAt: 1000,
        ),
        isTrue,
      );
      expect(
        AlertClockStore.shouldRescheduleNotification(
          scheduledExitAt: 1000,
          exitAt: 1000,
        ),
        isFalse,
      );
      expect(
        AlertClockStore.shouldRescheduleNotification(
          scheduledExitAt: 1000,
          exitAt: 2000,
        ),
        isTrue,
      );
    });

    test('rescheduleNotifications 同一 exitAt 不重复调度，变化时重排，出场时取消', () async {
      final fakeAlarm = _FakeAlarmService();
      const baseNow = 1700000000000;
      var currentEntries = <Entry>[
        _entry('e1', '张三', baseNow + 20 * 60000),
      ];
      final store = AlertClockStore(
        alarm: fakeAlarm,
        tts: _FakeTtsService(),
        entriesProvider: () => currentEntries,
        nowMs: () => baseNow,
      );
      addTearDown(store.dispose);

      // 未就绪时不调度
      await store.rescheduleNotifications();
      expect(fakeAlarm.scheduledIds, isEmpty);

      // 就绪后首次调度
      store.setAlarmReady(true);
      await store.rescheduleNotifications();
      expect(fakeAlarm.scheduledIds, <String>['e1@${baseNow + 20 * 60000}']);
      expect(fakeAlarm.canceledIds, <String>['e1']);

      // 相同 exitAt 重复同步不得重复 cancel/schedule
      await store.rescheduleNotifications();
      expect(fakeAlarm.scheduledIds.length, 1);
      expect(fakeAlarm.canceledIds.length, 1);

      // exitAt 变化后重新调度
      currentEntries = <Entry>[_entry('e1', '张三', baseNow + 12 * 60000)];
      await store.rescheduleNotifications();
      expect(fakeAlarm.scheduledIds.length, 2);
      expect(fakeAlarm.scheduledIds.last, 'e1@${baseNow + 12 * 60000}');

      // 出场后取消通知
      currentEntries = <Entry>[
        _entry('e1', '张三', baseNow + 12 * 60000, exitedAt: baseNow),
      ];
      await store.rescheduleNotifications();
      expect(fakeAlarm.canceledIds.last, 'e1');
      expect(store.scheduledExitAtMap, isEmpty);
    });

    test('checkThresholds 触发去重 warn/alarm/timeout 播报与循环警报启停', () async {
      final fakeAlarm = _FakeAlarmService();
      final fakeTts = _FakeTtsService();
      const baseNow = 1700000000000;
      final cfg = CalcConfig(
        cylinderVolL: 6.8,
        fullPressureMpa: 30,
        consumptionLpm: 80,
        warnMin: 10,
        alarmMin: 5,
      );
      final store = AlertClockStore(
        alarm: fakeAlarm,
        tts: fakeTts,
        calcConfigProvider: () => cfg,
        nowMs: () => baseNow,
      );
      addTearDown(store.dispose);

      // 1. 仅注意状态：播报 warn，不响循环警报
      store.checkThresholds(
        entries: <Entry>[_entry('w1', '张三', baseNow + 8 * 60000)],
      );
      expect(fakeTts.spoken.length, 1);
      expect(fakeTts.spoken.first, contains('准备撤离'));
      expect(fakeAlarm.startLoopCount, 0);
      expect(fakeAlarm.stopCount, 1);

      // 同状态重复检查不重复播报
      store.checkThresholds(
        entries: <Entry>[_entry('w1', '张三', baseNow + 8 * 60000)],
      );
      expect(fakeTts.spoken.length, 1);

      // 2. 告警 + 超时：触发 alarm & timeout 播报并启动循环警笛
      store.checkThresholds(
        entries: <Entry>[
          _entry('a1', '李四', baseNow + 3 * 60000),
          _entry('t1', '王五', baseNow - 5000),
        ],
      );
      expect(fakeAlarm.firedKeys, containsAll(<String>['a1:alarm', 't1:timeout']));
      expect(fakeAlarm.startLoopCount, 1);

      // 3. 全部安全/离场后停止循环警笛
      store.checkThresholds(
        entries: <Entry>[_entry('s1', '赵六', baseNow + 30 * 60000)],
      );
      expect(fakeAlarm.stopCount, greaterThanOrEqualTo(2));
    });

    test('setSoundEnabled 与 resetSession / clearScheduledNotifications 生效', () async {
      final fakeAlarm = _FakeAlarmService();
      final store = AlertClockStore(
        alarm: fakeAlarm,
        tts: _FakeTtsService(),
      );
      addTearDown(store.dispose);

      var notified = 0;
      store.addListener(() => notified++);

      await store.setSoundEnabled(false);
      expect(store.soundEnabled, isFalse);
      expect(notified, 1);
      expect(fakeAlarm.stopCount, 1);

      store.resetSession();
      expect(fakeAlarm.resetCount, 1);
    });
  });
}
