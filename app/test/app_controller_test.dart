import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/update_service.dart';
import 'package:watchdog/state/app_controller.dart';

/// 模拟服务器不可达的 ApiClient（拉名单/热词必然失败）
class _NoOrgApi extends ApiClient {
  _NoOrgApi() : super(baseUrl: 'http://offline', incidentId: 'test', unitId: '');

  @override
  Future<List<Firefighter>> fetchFirefighters() async => [
    Firefighter(id: '1', name: '不该出现'),
  ];

  @override
  Future<List<Hotword>> fetchHotwords() async => [
    Hotword(id: '1', word: '不该出现'),
  ];

  @override
  Future<List<Station>> fetchStations() async => [
    Station(id: '1', name: '不该出现'),
  ];
}

class _OfflineApi extends ApiClient {
  _OfflineApi()
    : super(baseUrl: 'http://offline', incidentId: 'test', unitId: 'test-unit');

  @override
  Future<List<Firefighter>> fetchFirefighters() async =>
      throw Exception('网络不可达');

  @override
  Future<List<Hotword>> fetchHotwords() async => throw Exception('网络不可达');

  @override
  Future<List<Station>> fetchStations() async => throw Exception('网络不可达');
}

/// 记录 createNote 收到的 author，验证实名随日志提交
class _RecordingApi extends ApiClient {
  _RecordingApi() : super(baseUrl: 'http://rec', incidentId: 'test');
  String? lastAuthor;
  String? lastOpId;

  @override
  Future<Note> createNote({
    required String text,
    String? category,
    String? opId,
    String? author,
  }) async {
    lastAuthor = author;
    lastOpId = opId;
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

  testWidgets('进出场日志压缩超长操作号，保持重试稳定且不同操作不混用', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _RecordingApi();
    final c = AppController()..api = api;
    addTearDown(c.dispose);
    const longId = 'manual-exit-note-12345678-1234-1234-1234-123456789abc-1793024291000';
    Future<void> write(String id) => c.addActionLog(
      names: ['赵磊'],
      action: '出场',
      category: NoteCategory.withdraw,
      opId: id,
    );
    await write(longId);
    final first = api.lastOpId;
    expect(first!.length, lessThanOrEqualTo(64));
    await write(longId);
    expect(api.lastOpId, first);
    await write('$longId-next');
    expect(api.lastOpId, isNot(first));
    await write('exit-note-short');
    expect(api.lastOpId, 'exit-note-short');
  });

  testWidgets('倒计时 tick 独立刷新，不广播整棵页面树', (tester) async {
    final c = AppController();
    var controllerNotifications = 0;
    var clockNotifications = 0;
    c.addListener(() => controllerNotifications++);
    c.clockTick.addListener(() => clockNotifications++);

    c.clockTick.value++;

    expect(clockNotifications, 1);
    expect(controllerNotifications, 0);
    c.dispose();
  });

  testWidgets('不安全的外部服务地址回退到本地开发后端', (tester) async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'http://untrusted.example.test',
    });
    expect(await Settings.serverUrl, Settings.defaultServerUrl);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('server_url'), Settings.defaultServerUrl);
  });

  testWidgets('带查询参数的服务地址回退到本地开发后端', (tester) async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://localhost:3000?token=unsafe',
    });
    expect(await Settings.serverUrl, Settings.defaultServerUrl);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('server_url'), Settings.defaultServerUrl);
  });

  group('AppController 名单热词离线缓存', () {
    testWidgets('首次安装未认证时不加载单位姓名和热词', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = AppController();
      await c.loadRoster();
      expect(c.firefighters, isEmpty);
      expect(c.hotwords, isEmpty);
    });

    testWidgets('服务器不可达时回退本地缓存，名单热词仍可用', (tester) async {
      SharedPreferences.setMockInitialValues({
        'cached_roster_unit_id': 'test-unit',
        'cached_firefighters': '["张三","李四"]',
        'cached_hotwords': '["火情","破拆"]',
        'cached_stations': '[{"id":"s1","name":"示例路站"}]',
      });
      final c = AppController()..api = _OfflineApi();
      await c.loadRoster();
      expect(c.firefighters.map((f) => f.name), containsAll(['张三', '李四']));
      expect(c.hotwords.map((h) => h.word), containsAll(['火情', '破拆']));
      expect(c.stations.map((item) => item.name), ['示例路站']);
      expect(c.orgDirectory.asrTerms, containsAll(['张三', '李四', '火情', '示例路站', '内攻']));
      expect(c.orgDirectory.parserNames, containsAll(['张三', '李四']));
      expect(c.orgDirectory.parserNames, isNot(contains('示例路站')));
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

    testWidgets('无缓存且服务器不可达：不回退未绑定的内置名单和热词', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = AppController()..api = _OfflineApi();
      await c.loadRoster();
      expect(c.firefighters, isEmpty);
      expect(c.hotwords, isEmpty);
      expect(c.stations, isEmpty);
      expect(c.orgDirectory.parserNames, isEmpty);
      expect(c.orgDirectory.asrTerms, contains('内攻'));
      expect(c.orgDirectory.asrTerms, isNot(contains('张三')));
    });

    testWidgets('无组织用户不拉取名单，识别保持通用模式', (tester) async {
      SharedPreferences.setMockInitialValues({
        'cached_roster_unit_id': 'other-unit',
        'cached_firefighters': '["张三"]',
        'cached_stations': '[{"id":"s1","name":"示例路站"}]',
      });
      final c = AppController()..api = _NoOrgApi();
      await c.loadRoster();
      expect(c.firefighters, isEmpty);
      expect(c.stations, isEmpty);
      expect(c.orgDirectory.parserNames, isEmpty);
      expect(c.orgDirectory.asrTerms, contains('内攻'));
      expect(c.orgDirectory.asrTerms, isNot(contains('不该出现')));
      expect(c.orgDirectory.asrTerms, isNot(contains('张三')));
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
