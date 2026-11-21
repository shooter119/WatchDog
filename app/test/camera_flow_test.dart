import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/features/media/state/camera_flow_policy.dart';
import 'package:watchdog/services/camera_bridge.dart';

void main() {
  test('定位时效包含原生年龄和页面停留时间', () {
    final now = DateTime(2026, 10, 18);
    const fix = LocationFix(
      lat: 30,
      lon: 120,
      accuracyMeters: 5,
      provider: 'gps',
      ageMs: 60000,
    );
    expect(
      CameraFlowPolicy.locationExpired(
        fix,
        now,
        now.add(const Duration(minutes: 4)),
      ),
      isFalse,
    );
    expect(
      CameraFlowPolicy.locationExpired(
        fix,
        now,
        now.add(const Duration(minutes: 4, milliseconds: 1)),
      ),
      isTrue,
    );
    expect(CameraFlowPolicy.locationExpired(null, now, now), isTrue);
  });

  test('计时按真实时间差计算，跳过多个 tick 不丢秒', () {
    final start = DateTime(2026, 10, 18);
    expect(
      CameraFlowPolicy.elapsed(
        start,
        start.add(const Duration(seconds: 53, milliseconds: 420)),
      ),
      const Duration(seconds: 53, milliseconds: 420),
    );
  });
}
