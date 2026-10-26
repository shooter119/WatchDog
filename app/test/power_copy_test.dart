import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/state/app_controller.dart';

void main() {
  test('同一到期时间不重复重排通知，到期时间变化才重排', () {
    // 幂等：同一次同步快照反复到达时不得白跑 cancel+schedule
    expect(
      AppController.shouldRescheduleNotification(scheduledExitAt: 1000, exitAt: 1000),
      isFalse,
    );
    // 改名/压力复核导致 exitAt 变化 -> 必须重排
    expect(
      AppController.shouldRescheduleNotification(scheduledExitAt: 1000, exitAt: 2000),
      isTrue,
    );
    // 首次调度
    expect(
      AppController.shouldRescheduleNotification(scheduledExitAt: null, exitAt: 1000),
      isTrue,
    );
  });
}
