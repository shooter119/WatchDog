import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/audio_service.dart';

void main() {
  test('dBFS 电平映射到录音动画范围并保留静音底噪指示', () {
    expect(normalizeAmplitudeDbfs(double.negativeInfinity), 0.15);
    expect(normalizeAmplitudeDbfs(-60), 0.15);
    expect(normalizeAmplitudeDbfs(-30), closeTo(0.5, 0.001));
    expect(normalizeAmplitudeDbfs(-12), closeTo(0.8, 0.001));
    expect(normalizeAmplitudeDbfs(0), 1.0);
    expect(normalizeAmplitudeDbfs(6), 1.0);
  });
}
