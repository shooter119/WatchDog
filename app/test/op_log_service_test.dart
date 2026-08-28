import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/op_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('连续记录后清空按调用顺序持久化，不留下旧快照', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = OpLogService.instance;
    addTearDown(() async {
      await service.setSyncEnabled(true);
      await service.clearLocal();
    });
    await service.init();
    await service.clearLocal();
    await service.setSyncEnabled(false);

    for (var i = 0; i < 8; i++) {
      service.record('op-$i', 'stage', 'message-$i', sync: false);
    }
    await service.clearLocal();

    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('op_logs_v1');
    expect(raw, isNotNull);
    expect(jsonDecode(raw!), isEmpty);
    expect(service.logs, isEmpty);
  });
}
