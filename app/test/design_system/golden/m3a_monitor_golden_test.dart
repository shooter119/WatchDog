@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/monitor/state/alert_clock_store.dart';
import 'package:watchdog/features/monitor/state/monitor_store.dart';
import 'package:watchdog/features/monitor/ui/entry_detail_screen.dart';
import 'package:watchdog/features/monitor/ui/monitor_page.dart';
import 'package:watchdog/services/alarm_service.dart';
import 'package:watchdog/services/tts_service.dart';

class _SilentAlarm extends AlarmService {
  @override
  Future<void> stopAlarm() async {}
}

class _SilentTts extends TtsService {
  @override
  void speak(String text) {}
}

final int _fixedNow = DateTime(2026, 5, 14, 14, 30, 0).millisecondsSinceEpoch;

List<Entry> _goldenEntries() => <Entry>[
  Entry(
    id: 'g-timeout',
    name: '赵六',
    pressureMpa: 6.0,
    durationMin: 25,
    entryAt: _fixedNow - 26 * 60000 - 15000,
    exitAt: _fixedNow - 1 * 60000 - 15000,
    source: 'voice',
    rawText: '赵六，24兆帕，9升气瓶',
    cylinderVolL: 9.0,
    consumptionLpm: 80.0,
    consumptionActualLpm: 84.5,
  ),
  Entry(
    id: 'g-alarm',
    name: '王五',
    pressureMpa: 9.0,
    durationMin: 26,
    entryAt: _fixedNow - 22 * 60000 - 30000,
    exitAt: _fixedNow + 3 * 60000 + 30000,
    source: 'voice',
    rawText: '王五，26兆帕',
    cylinderVolL: 6.8,
    consumptionLpm: 80.0,
    consumptionActualLpm: 76.2,
  ),
  Entry(
    id: 'g-caution',
    name: '李四',
    pressureMpa: 15.0,
    durationMin: 28,
    entryAt: _fixedNow - 19 * 60000,
    exitAt: _fixedNow + 8 * 60000 + 45000,
    source: 'voice',
  ),
  Entry(
    id: 'g-safe',
    name: '张三',
    pressureMpa: 24.0,
    durationMin: 30,
    entryAt: _fixedNow - 8 * 60000,
    exitAt: _fixedNow + 21 * 60000 + 10000,
    source: 'voice',
  ),
];

Future<void> _pumpGolden(
  WidgetTester tester, {
  required Brightness brightness,
  required GlobalKey captureKey,
  required Widget child,
}) async {
  const surfaceSize = Size(390, 844);
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(key: captureKey, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in <String>[
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name == 'xyz.luan/audioplayers' && call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      });
    }
  });

  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3a MonitorPage ($themeTag)', (WidgetTester tester) async {
      final monitor = MonitorStore(
        initialEntries: _goldenEntries(),
        nowMs: () => _fixedNow,
      );
      final clock = AlertClockStore(
        alarm: _SilentAlarm(),
        tts: _SilentTts(),
        entriesProvider: () => monitor.entries,
        calcConfigProvider: () => monitor.calcConfig,
        nowMs: () => _fixedNow,
      );
      addTearDown(monitor.dispose);
      addTearDown(clock.dispose);

      final captureKey = GlobalKey();
      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: Scaffold(
          body: MonitorPage(
            monitorStore: monitor,
            alertClockStore: clock,
            nowMs: () => _fixedNow,
          ),
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3a_monitor_page_$themeTag.png'),
      );
    });

    testWidgets('M3a EntryDetailScreen ($themeTag)', (
      WidgetTester tester,
    ) async {
      final monitor = MonitorStore(
        initialEntries: _goldenEntries(),
        nowMs: () => _fixedNow,
      );
      final clock = AlertClockStore(
        alarm: _SilentAlarm(),
        tts: _SilentTts(),
        entriesProvider: () => monitor.entries,
        calcConfigProvider: () => monitor.calcConfig,
        nowMs: () => _fixedNow,
      );
      addTearDown(monitor.dispose);
      addTearDown(clock.dispose);

      final captureKey = GlobalKey();
      await _pumpGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: EntryDetailScreen(
          monitorStore: monitor,
          alertClockStore: clock,
          entryId: 'g-alarm',
          nowMs: () => _fixedNow,
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3a_entry_detail_$themeTag.png'),
      );
    });
  }
}
