import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/key_sites.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/key_sites_page.dart';
import 'package:watchdog/pages/incident_key_site_section.dart';
import 'package:watchdog/services/key_site_recents.dart';
import 'package:watchdog/state/app_controller.dart';

KeySiteVersion sample({int version = 1}) => KeySiteVersion(
  siteId: 'one',
  version: version,
  latestVersion: 2,
  publishedAt: 1,
  active: true,
  profile: {'name': '合成单位', 'address': '合成地址'},
  content: {
    'cards': [const KeySiteEntry(title: '已核对风险', body: '合成测试')],
    'hazards': [
      const KeySiteEntry(title: '乙醇', fields: {'location': '合成仓库'}),
    ],
  },
  attachments: [],
);

class FakeApi extends ApiClient {
  FakeApi() : super(baseUrl: 'https://example.test', incidentId: '');
  int accessCalls = 0;
  Map<String, dynamic> linkState = {'link': null, 'revision': 0, 'history': []};
  @override
  Future<Map<String, dynamic>> fetchIncidentKeySite(String id) async =>
      linkState;
  bool fail = false;
  KeySiteVersion? fixture;
  final resources = <String>[];
  bool failImages = false;
  @override
  Future<Uint8List> fetchKeySiteImage(
    String siteId,
    int version,
    String attachmentId, {
    required String resource,
    String? incident,
  }) async {
    resources.add(resource);
    if (failImages) throw const SocketException('synthetic offline');
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }

  List<(String, int?, String?)> reads = [];
  @override
  Future<Map<String, dynamic>> keySiteAccess() async {
    accessCalls++;
    return {'unitId': 'u', 'memberId': 'm'};
  }

  @override
  Future<Map<String, dynamic>> fetchKeySites({
    String search = '',
    String district = '',
    String type = '',
    int offset = 0,
  }) async {
    if (fail) throw const SocketException('offline');
    return {
      'sites': [
        {
          'id': 'one',
          'name': '合成单位',
          'address': '合成地址',
          'published_version': 1,
        },
      ],
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> keySiteFilters() async => {
    'districts': ['东区'],
    'types': ['工厂'],
  };
  @override
  Future<KeySiteVersion> fetchKeySite(
    String id, {
    int? version,
    String? incident,
  }) async {
    reads.add((id, version, incident));
    return fixture ?? sample(version: version ?? 2);
  }

  @override
  Future<List<KeySiteSummary>> fetchRecentKeySites(List<String> ids) async =>
      [];
}

class FakeController extends AppController {
  @override
  final keySiteRecents = KeySiteRecents();
  int changes = 0;
  KeySiteVersion? lastSelected;
  @override
  Future<void> changeKeySiteLink(
    String incidentId, {
    required int revision,
    required String operationId,
    KeySiteVersion? site,
  }) async {
    changes++;
    lastSelected = site;
  }

  bool allowed = true;
  int epoch = 0;
  FakeController(FakeApi client) {
    api = client;
  }
  @override
  bool get canReadKeySites => allowed;
  @override
  int get protectedDataEpoch => epoch;
  void revoke() {
    allowed = false;
    epoch++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test('最近查看只保存标识时间，按成员隔离并阻止退出后的迟到写入', () async {
    final store = KeySiteRecents();
    final one = store.begin(server: 'test', unitId: 'u', memberId: 'm1');
    await store.viewed(one, 'a', at: 1);
    await store.viewed(one, 'b', at: 2);
    await store.viewed(one, 'a', at: 3);
    expect(await store.read(one), ['a', 'b']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      (jsonDecode(prefs.getString(one)!) as List).first.keys,
      unorderedEquals(['id', 'viewedAt']),
    );
    final two = store.begin(server: 'test', unitId: 'u', memberId: 'm2');
    expect(await store.read(two), isEmpty);
    final clearing = store.clearAll();
    await store.viewed(two, 'late');
    await clearing;
    expect(
      prefs.getKeys().where((k) => k.startsWith('key_site_recent_v1:')),
      isEmpty,
    );
  });
  test('最近查看最多二十条且并发写入顺序稳定', () async {
    final store = KeySiteRecents();
    final scope = store.begin(server: 'test', unitId: 'u', memberId: 'm');
    await Future.wait(
      List.generate(25, (i) => store.viewed(scope, '$i', at: i)),
    );
    final result = await store.read(scope);
    expect(result.length, 20);
    expect(result.first, '24');
    expect(result.last, '5');
  });
  testWidgets('列表在线显示，认证撤销立即销毁内容，普通状态通知不重复请求', (tester) async {
    final api = FakeApi();
    final controller = FakeController(api);
    await tester.pumpWidget(
      MaterialApp(home: KeySitesPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('合成单位'), findsOneWidget);
    controller.notifyListeners();
    await tester.pump();
    expect(api.accessCalls, 1);
    controller.revoke();
    await tester.pumpAndSettle();
    expect(find.text('合成单位'), findsNothing);
    expect(find.textContaining('仅已认证'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('断网独立提示并可重试', (tester) async {
    final api = FakeApi()..fail = true;
    final controller = FakeController(api);
    await tester.pumpWidget(
      MaterialApp(home: KeySitesPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('网络未连接'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('合成单位'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('警情及模块始终读取固定版本，认证撤销清除正文', (tester) async {
    final api = FakeApi();
    final controller = FakeController(api);
    await tester.pumpWidget(
      MaterialApp(
        home: KeySitePage(
          controller: controller,
          siteId: 'one',
          version: 1,
          incidentId: 'i',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.reads.single, ('one', 1, 'i'));
    expect(find.textContaining('本警情仍引用 v1'), findsOneWidget);
    await tester.tap(find.text('作战信息卡'));
    await tester.pumpAndSettle();
    expect(api.reads.last, ('one', 1, 'i'));
    expect(find.text('已核对风险'), findsOneWidget);
    controller.revoke();
    await tester.pumpAndSettle();
    expect(find.text('已核对风险'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('危险品按名称位置筛选，大字号横屏无溢出', (tester) async {
    tester.view.physicalSize = const Size(900, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi();
    final controller = FakeController(api);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.3)),
          child: child!,
        ),
        home: KeySiteModulePage(
          controller: controller,
          site: sample(),
          module: 'hazards',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('乙醇'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '仓库');
    await tester.pump();
    expect(find.text('乙醇'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '汽油');
    await tester.pump();
    expect(find.text('暂无资料'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('标准储罐显示中文字段且按编号搜索，设计容积不冒充实际储量', (tester) async {
    final api = FakeApi();
    api.fixture = KeySiteVersion(
      siteId: 'one',
      version: 1,
      latestVersion: 1,
      publishedAt: 1,
      active: true,
      profile: {'name': '合成单位'},
      content: {
        'hazards': [
          KeySiteEntry.fromJson({
            'kind': 'storageTank',
            'title': '合成介质',
            'fields': {
              'tankNumber': 'T-TEST',
              'designVolume': '42',
              'designPressure': '-0.0005/0.008',
              'quantity': '',
            },
          }),
        ],
      },
      attachments: [],
    );
    final controller = FakeController(api);
    await tester.pumpWidget(
      MaterialApp(
        home: KeySiteModulePage(
          controller: controller,
          site: api.fixture!,
          module: 'hazards',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('储罐'), findsOneWidget);
    expect(find.text('储罐编号：T-TEST'), findsOneWidget);
    expect(find.text('储罐容积（m³，非实际储量）：42'), findsOneWidget);
    expect(find.textContaining('实际储量（原文及单位）：'), findsNothing);
    await tester.enterText(find.byType(TextField), 'T-TEST');
    await tester.pump();
    expect(find.text('合成介质'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('地图使用来源页对应的鉴权瓦片，切页与恢复全图保持可操作', (tester) async {
    final api = FakeApi();
    final controller = FakeController(api);
    final attachment = <String, dynamic>{
      'id': 'map',
      'filename': '合成分区图.pdf',
      'metadata': {
        'pages': 2,
        'mapPages': {
          '1': {'width': 256, 'height': 256, 'maxZoom': 0},
          '2': {'width': 256, 'height': 256, 'maxZoom': 0},
        },
      },
    };
    final site = KeySiteVersion(
      siteId: 'one',
      version: 1,
      latestVersion: 1,
      publishedAt: 1,
      active: true,
      profile: {'name': '合成单位'},
      content: {},
      attachments: [attachment],
    );
    api.fixture = site;
    await tester.pumpWidget(
      MaterialApp(
        home: KeySiteDocumentPage(
          controller: controller,
          site: site,
          attachment: attachment,
          initialPage: 2,
          map: true,
          incidentId: 'i',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.resources, contains('maps/2/tiles/0/0/0.jpg'));
    expect(api.resources.where((r) => r.startsWith('pages/')), isEmpty);
    await tester.tap(find.byTooltip('上一页'));
    await tester.pumpAndSettle();
    expect(api.resources, contains('maps/1/tiles/0/0/0.jpg'));
    await tester.tap(find.text('恢复全图'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    controller.revoke();
    await tester.pumpAndSettle();
    expect(find.text('合成分区图.pdf'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });

  testWidgets('地图缩至全图时，加载错误和重试在像素变换之外保持可读可点', (tester) async {
    final api = FakeApi()..failImages = true;
    final controller = FakeController(api);
    final attachment = <String, dynamic>{
      'id': 'map',
      'filename': '合成大图.pdf',
      'metadata': {
        'pages': 1,
        'mapPages': {
          '1': {'width': 6000, 'height': 3000, 'maxZoom': 5},
        },
      },
    };
    final site = KeySiteVersion(
      siteId: 'one',
      version: 1,
      latestVersion: 1,
      publishedAt: 1,
      active: true,
      profile: {'name': '合成单位'},
      content: {},
      attachments: [attachment],
    );
    api.fixture = site;
    await tester.pumpWidget(
      MaterialApp(
        home: KeySiteDocumentPage(
          controller: controller,
          site: site,
          attachment: attachment,
          map: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('网络未连接'), findsOneWidget);
    final retry = find.widgetWithText(TextButton, '重试地图');
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    final before = api.resources.length;
    api.failImages = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(api.resources.length, greaterThan(before));
    expect(find.text('重试地图'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });

  testWidgets('警情关联必须搜索并核对名称地址后确认，取消不写入', (tester) async {
    final api = FakeApi();
    final controller = FakeController(api);
    const incident = Incident(
      id: 'i',
      number: '合成警情',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncidentKeySiteSection(
            controller: controller,
            incident: incident,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索并关联'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成单位'));
    await tester.pumpAndSettle();
    expect(find.text('核对重点单位'), findsOneWidget);
    expect(find.textContaining('合成地址'), findsOneWidget);
    expect(controller.changes, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.changes, 0);
    await tester.tap(find.text('搜索并关联'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成单位'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(controller.changes, 1);
    expect(controller.lastSelected!.version, 2);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });

  testWidgets('扫码之外的资料确认弹窗也随认证失效清除姓名地址', (tester) async {
    final api = FakeApi();
    final controller = FakeController(api);
    const incident = Incident(
      id: 'i',
      number: '合成警情',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncidentKeySiteSection(
            controller: controller,
            incident: incident,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索并关联'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成单位'));
    await tester.pumpAndSettle();
    controller.revoke();
    await tester.pumpAndSettle();
    expect(find.textContaining('合成地址'), findsNothing);
    expect(find.text('确认'), findsNothing);
    expect(controller.changes, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });

  test('警情快照兼容旧响应并解析版本关联', () {
    expect(Incident.fromJson({'id': 'i'}).keySiteLink, isNull);
    final current = Incident.fromJson({
      'id': 'i',
      'key_site_link_revision': 3,
      'key_site_link': {
        'siteId': 's',
        'name': '合成单位',
        'address': '地址',
        'version': 2,
        'linkedBy': 'm',
        'linkedAt': 4,
      },
    });
    expect(current.keySiteLink!.version, 2);
    expect(current.keySiteLinkRevision, 3);
  });
}
