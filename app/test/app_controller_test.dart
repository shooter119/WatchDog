import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/update_service.dart';
import 'package:watchdog/state/app_controller.dart';

void main() {
  // AppController 构造会实例化 AlarmService/TtsService（插件通道），
  // 需要 testWidgets 的测试 binding 环境（与 widget_test 一致）
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppController 更新检查状态', () {
    testWidgets('recordUpdateCheck 发现新版本：记录并通知监听者', (tester) async {
      final c = AppController();
      var notified = 0;
      c.addListener(() => notified++);
      const info = UpdateInfo(tagName: 'v9.9.9+99', apkUrl: 'x');
      c.recordUpdateCheck(info, null);
      expect(c.pendingUpdate, same(info));
      expect(c.updateCheckDone, isTrue);
      expect(c.updateCheckError, isNull);
      expect(notified, 1);
    });

    testWidgets('recordUpdateCheck 已是最新：无提示、无错误', (tester) async {
      final c = AppController();
      c.recordUpdateCheck(null, null);
      expect(c.pendingUpdate, isNull);
      expect(c.updateCheckDone, isTrue);
      expect(c.updateCheckError, isNull);
    });

    testWidgets('recordUpdateCheck 检查失败：清空新版本并记录错误', (tester) async {
      final c = AppController();
      c.recordUpdateCheck(null, '更新服务不可达（HTTP 500）');
      expect(c.pendingUpdate, isNull);
      expect(c.updateCheckDone, isTrue);
      expect(c.updateCheckError, '更新服务不可达（HTTP 500）');
    });
  });
}
