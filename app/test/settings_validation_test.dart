import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/services/settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('计算参数校验接受合法边界并拒绝非法值', () {
    expect(
      () => Settings.validateCalculationParameters(
        cylinderVolL: Settings.maxCylinderVolL,
        fullPressureMpa: Settings.maxFullPressureMpa,
        consumptionLpm: Settings.maxConsumptionLpm,
      ),
      returnsNormally,
    );
    expect(
      () => Settings.validateCalculationParameters(cylinderVolL: 0),
      throwsArgumentError,
    );
    expect(
      () => Settings.validateCalculationParameters(consumptionLpm: -1),
      throwsArgumentError,
    );
    expect(
      () => Settings.validateCalculationParameters(fullPressureMpa: 41),
      throwsArgumentError,
    );
  });

  test('阈值校验保证报警不高于提醒且不超过一天', () async {
    await expectLater(Settings.setThresholds(5, 5), completes);
    await expectLater(Settings.setThresholds(4, 5), throwsArgumentError);
    await expectLater(Settings.setThresholds(1441, 1), throwsArgumentError);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getInt('warn_min'), 5);
    expect(sp.getInt('alarm_min'), 5);
  });

  test('单项计算参数 setter 也拒绝零值', () async {
    await expectLater(Settings.setCylinderVolL(0), throwsArgumentError);
    await expectLater(Settings.setFullPressureMpa(-1), throwsArgumentError);
    await expectLater(Settings.setConsumptionLpm(0), throwsArgumentError);
  });

  test('空设置的同步快照与运行时 ASR 默认值一致', () async {
    expect((await Settings.toSyncMap())['asr_cloud_enabled'], isTrue);
    expect(await Settings.asrCloudEnabled, isTrue);
  });
}
