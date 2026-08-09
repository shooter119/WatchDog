import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/update_service.dart';
import 'package:watchdog/state/app_controller.dart';

/// 模拟服务器不可达的 ApiClient（拉名单/热词必然失败）
class _OfflineApi extends ApiClient {
  _OfflineApi() : super(baseUrl: 'http://offline', incidentId: 'test');

  @override
  Future<List<Firefighter>> fetchFirefighters() async => throw Exception('网络不可达');

  @override
  Future<List<Hotword>> fetchHotwords() async => throw Exception('网络不可达');
}

/// 记录 createNote 收到的 author，验证实名随日志提交
class _RecordingApi extends ApiClient {
  _RecordingApi() : super(baseUrl: 'http://rec', incidentId: 'test');
  String? lastAuthor;

  @override
  Future<Note> createNote({required String text, String? category, String? opId, String? author}) async {
    lastAuthor = author;
    return Note(
      id: 'n1',
      text: text,
      category: category ?? NoteCategory.other,
      author: author ?? '',
      createdAt: 1,
      updatedAt: 1,
    );
  }
}

void main() {
  // AppController 构造会实例化 AlarmService/TtsService（插件通道），
  // 需要 testWidgets 的测试 binding 环境（与 widget_test 一致）
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppController 名单热词离线缓存', () {
    testWidgets('首次安装即有内置名单和热词，不依赖警情或服务器', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = AppController();
      await c.loadRoster();
      expect(c.firefighters.length, 95);
      expect(c.hotwords.length, 11);
    });

    testWidgets('服务器不可达时回退本地缓存，名单热词仍可用', (tester) async {
      SharedPreferences.setMockInitialValues({
        'cached_firefighters': '["张三","李四"]',
        'cached_hotwords': '["火情","破拆"]',
      });
      final c = AppController()..api = _OfflineApi();
      await c.loadRoster();
      expect(c.firefighters.map((f) => f.name), containsAll(['张三', '李四']));
      expect(c.hotwords.map((h) => h.word), containsAll(['火情', '破拆']));
      // 本地识别热词来源可用（名单 → 人名热词）
      expect(c.firefighters, isNotEmpty);
    });

    testWidgets('addNote 携带本地实名作者，随日志提交', (tester) async {
      SharedPreferences.setMockInitialValues({'real_name': '李娜'});
      final api = _RecordingApi();
      final c = AppController()..api = api;
      await c.addNote('实名日志测试');
      expect(api.lastAuthor, '李娜');
      // 未填实名 → 不携带 author（服务器按设备查/匿名）
      SharedPreferences.setMockInitialValues({'real_name': ''});
      final api2 = _RecordingApi();
      final c2 = AppController()..api = api2;
      await c2.addNote('匿名日志测试');
      expect(api2.lastAuthor, isEmpty);
    });

    testWidgets('无缓存且服务器不可达：回退内置默认名单和热词', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = AppController()..api = _OfflineApi();
      await c.loadRoster();
      expect(c.firefighters.length, 95);
      expect(c.hotwords.length, 11);
    });
  });

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
