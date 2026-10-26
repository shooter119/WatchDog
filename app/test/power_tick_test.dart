import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/state/app_controller.dart';

class _FakeTickController extends AppController {
  _FakeTickController() : super() {
    currentIncident = const Incident(
      id: 'test-incident',
      number: '2026-8-9-8-59',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 1,
    );
  }

  @override
  bool get needsAuthentication => false;

  @override
  Future<void> sync() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
  });

  test('未 startSync 时 tickInterval 随前后台与 PiP 状态切换', () async {
    final controller = _FakeTickController();
    addTearDown(controller.dispose);

    expect(controller.tickInterval, AppController.foregroundTickInterval);
    expect(controller.tickInterval, const Duration(seconds: 1));

    controller.handleAppPaused();
    expect(controller.tickInterval, AppController.backgroundTickInterval);
    expect(controller.tickInterval, const Duration(seconds: 5));

    controller.setPipActive(true);
    expect(controller.tickInterval, AppController.foregroundTickInterval);
    expect(controller.tickInterval, const Duration(seconds: 1));

    controller.setPipActive(false);
    expect(controller.tickInterval, AppController.backgroundTickInterval);
    expect(controller.tickInterval, const Duration(seconds: 5));

    await controller.handleAppResumed();
    expect(controller.tickInterval, AppController.foregroundTickInterval);
    expect(controller.tickInterval, const Duration(seconds: 1));
  });

  testWidgets('startSync 后定时器按前后台与 PiP 状态切换实际触发频率', (tester) async {
    final controller = _FakeTickController();

    controller.startSync();
    expect(controller.clockTick.value, 0);

    await tester.pump(const Duration(seconds: 3));
    expect(controller.clockTick.value, 3);

    controller.handleAppPaused();
    final afterPause = controller.clockTick.value;
    await tester.pump(const Duration(seconds: 4));
    expect(controller.clockTick.value, afterPause);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.clockTick.value, afterPause + 1);

    controller.setPipActive(true);
    final afterPipOn = controller.clockTick.value;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.clockTick.value, afterPipOn + 2);

    controller.setPipActive(false);
    final afterPipOff = controller.clockTick.value;
    await tester.pump(const Duration(seconds: 4));
    expect(controller.clockTick.value, afterPipOff);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.clockTick.value, afterPipOff + 1);

    await controller.handleAppResumed();
    final afterResume = controller.clockTick.value;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.clockTick.value, afterResume + 2);
    controller.dispose();
    await tester.pump();
  });
}
