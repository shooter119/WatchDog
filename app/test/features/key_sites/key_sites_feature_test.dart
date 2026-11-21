import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/key_sites/data/models/key_sites.dart';
import 'package:watchdog/features/key_sites/ui/key_site_detail_page.dart';
import 'package:watchdog/features/key_sites/ui/key_site_document_page.dart';
import 'package:watchdog/features/key_sites/ui/key_site_gate.dart';
import 'package:watchdog/features/key_sites/ui/key_site_module_page.dart';
import 'package:watchdog/features/key_sites/ui/key_sites_page.dart';
import 'package:watchdog/services/key_site_recents.dart';

KeySiteVersion _sampleSite({int version = 1, bool active = true}) =>
    KeySiteVersion(
      siteId: 'one',
      version: version,
      latestVersion: 2,
      publishedAt: DateTime(2026, 6, 1, 14, 30).millisecondsSinceEpoch,
      active: active,
      profile: const <String, dynamic>{
        'name': '合成单位',
        'address': '合成地址',
        'district': '东区',
        'site_type': '化工企业',
      },
      content: const <String, List<KeySiteEntry>>{
        'cards': <KeySiteEntry>[
          KeySiteEntry(title: '已核对风险', body: '合成测试'),
        ],
        'plans': <KeySiteEntry>[
          KeySiteEntry(title: '储罐区初期火灾处置预案', body: '优先冷却邻近罐体'),
        ],
        'hazards': <KeySiteEntry>[
          KeySiteEntry(
            title: '乙醇',
            fields: <String, String>{'location': '合成仓库'},
          ),
        ],
      },
      attachments: const <Map<String, dynamic>>[],
    );

class _FakeKeySiteHarness extends ChangeNotifier {
  final KeySiteRecents recents = KeySiteRecents();
  bool allowed = true;
  int epoch = 0;
  int accessCalls = 0;
  bool failList = false;
  bool failImages = false;
  KeySiteVersion? fixture;
  List<Map<String, dynamic>> sitesList = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'one',
      'name': '合成单位',
      'address': '合成地址',
      'district': '东区',
      'site_type': '化工企业',
      'published_version': 1,
    },
  ];
  final List<String> resources = <String>[];
  final List<(String, int?, String?)> reads = <(String, int?, String?)>[];

  late final KeySiteGateway gateway = KeySiteGateway(
    accessListenable: this,
    canReadKeySites: () => allowed,
    readProtectedDataEpoch: () => epoch,
    readServerBaseUrl: () => 'https://example.test',
    readClientIdentity: () => this,
    recents: recents,
    keySiteAccess: () async {
      accessCalls++;
      return const <String, dynamic>{'unitId': 'u', 'memberId': 'm'};
    },
    keySiteFilters: () async => const <String, dynamic>{
      'districts': <String>['东区'],
      'types': <String>['化工企业'],
    },
    fetchKeySites: ({
      String search = '',
      String district = '',
      String type = '',
      int offset = 0,
    }) async {
      if (failList) throw const SocketException('offline');
      return <String, dynamic>{'sites': sitesList, 'hasMore': false};
    },
    fetchRecentKeySites: (ids) async => const <KeySiteSummary>[],
    fetchKeySite: (id, {int? version, String? incident}) async {
      reads.add((id, version, incident));
      return fixture ?? _sampleSite(version: version ?? 2);
    },
    fetchKeySiteImage: (
      siteId,
      version,
      attachmentId, {
      required String resource,
      String? incident,
    }) async {
      resources.add(resource);
      if (failImages) throw const SocketException('synthetic offline');
      return Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    },
  );

  void revoke() {
    allowed = false;
    epoch++;
    notifyListeners();
  }

  void bumpEpoch() {
    epoch++;
    notifyListeners();
  }
}

Widget _wrapDs(
  Widget home, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: home,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('KeySiteRecents 冻结服务契约', () {
    test('最近查看只保存标识时间，按成员隔离并阻止退出后的迟到写入', () async {
      final store = KeySiteRecents();
      final one = store.begin(server: 'test', unitId: 'u', memberId: 'm1');
      await store.viewed(one, 'a', at: 1);
      await store.viewed(one, 'b', at: 2);
      await store.viewed(one, 'a', at: 3);
      expect(await store.read(one), <String>['a', 'b']);

      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(prefs.getString(one)!) as List;
      expect(
        (decoded.first as Map).keys,
        unorderedEquals(<String>['id', 'viewedAt']),
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
        List<Future<void>>.generate(25, (i) => store.viewed(scope, '$i', at: i)),
      );
      final result = await store.read(scope);
      expect(result.length, 20);
      expect(result.first, '24');
      expect(result.last, '5');
    });
  });

  group('KeySiteGate 与列表/详情/模块/文档交互', () {
    testWidgets('列表在线显示，认证撤销与代际递增立即销毁内容，普通通知不重复请求', (
      tester,
    ) async {
      final harness = _FakeKeySiteHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrapDs(KeySitesPage(gateway: harness.gateway)));
      await tester.pumpAndSettle();

      expect(find.text('合成单位'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('site-group-东区')), findsOneWidget);

      // 普通状态通知不应重跑 keySiteAccess
      harness.notifyListeners();
      await tester.pump();
      expect(harness.accessCalls, 1);

      // protectedDataEpoch 递增会立即重建并重新校验权限
      harness.bumpEpoch();
      await tester.pumpAndSettle();
      expect(harness.accessCalls, 2);

      // 撤销权限立即销毁正文并切到游客拦截提示
      harness.revoke();
      await tester.pumpAndSettle();
      expect(find.text('合成单位'), findsNothing);
      expect(find.textContaining('仅已认证'), findsOneWidget);
    });

    testWidgets('断网独立提示并可重试', (tester) async {
      final harness = _FakeKeySiteHarness()..failList = true;
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrapDs(KeySitesPage(gateway: harness.gateway)));
      await tester.pumpAndSettle();

      expect(find.textContaining('网络未连接'), findsOneWidget);
      harness.failList = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('合成单位'), findsOneWidget);
    });

    testWidgets('警情绑定模式标题正确且点击返回选中摘要', (tester) async {
      final harness = _FakeKeySiteHarness();
      addTearDown(harness.dispose);
      KeySiteSummary? picked;

      await tester.pumpWidget(
        _wrapDs(
          Builder(
            builder: (context) => Scaffold(
              body: CommandButton(
                label: '打开选择',
                onPressed: () async {
                  picked = await Navigator.push<KeySiteSummary>(
                    context,
                    MaterialPageRoute<KeySiteSummary>(
                      builder: (_) => KeySitesPage(
                        gateway: harness.gateway,
                        selectForIncident: true,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开选择'));
      await tester.pumpAndSettle();
      expect(find.text('绑定重点单位'), findsOneWidget);

      await tester.tap(find.text('合成单位'));
      await tester.pumpAndSettle();
      expect(picked?.id, 'one');
      expect(picked?.name, '合成单位');
    });

    testWidgets('警情及模块始终读取固定版本，认证撤销清除正文', (tester) async {
      final harness = _FakeKeySiteHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _wrapDs(
          KeySiteDetailPage(
            gateway: harness.gateway,
            siteId: 'one',
            version: 1,
            incidentId: 'inc-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(harness.reads.single, ('one', 1, 'inc-1'));
      expect(find.textContaining('本警情仍引用 v1'), findsOneWidget);

      await tester.tap(find.text('作战信息卡'));
      await tester.pumpAndSettle();

      expect(harness.reads.last, ('one', 1, 'inc-1'));
      expect(find.text('已核对风险'), findsOneWidget);
      expect(find.text('人工核对资料，未附原文来源'), findsNothing);
      expect(find.textContaining('原文出处'), findsNothing);

      harness.revoke();
      await tester.pumpAndSettle();
      expect(find.text('已核对风险'), findsNothing);
    });

    testWidgets('危险品按名称位置筛选，大字号横屏无溢出', (tester) async {
      tester.view.physicalSize = const Size(900, 420);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final harness = _FakeKeySiteHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _wrapDs(
          KeySiteModulePage(
            gateway: harness.gateway,
            site: _sampleSite(),
            module: 'hazards',
          ),
          textScale: 1.3,
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
    });

    testWidgets('标准储罐显示中文字段且按编号搜索，设计容积不冒充实际储量', (tester) async {
      final harness = _FakeKeySiteHarness();
      addTearDown(harness.dispose);
      final tankSite = KeySiteVersion(
        siteId: 'one',
        version: 1,
        latestVersion: 1,
        publishedAt: 1,
        active: true,
        profile: const <String, dynamic>{'name': '合成单位'},
        content: <String, List<KeySiteEntry>>{
          'hazards': <KeySiteEntry>[
            KeySiteEntry.fromJson(const <String, dynamic>{
              'kind': 'storageTank',
              'title': '合成介质',
              'fields': <String, dynamic>{
                'tankNumber': 'T-TEST',
                'designVolume': '42',
                'designPressure': '-0.0005/0.008',
                'quantity': '',
              },
            }),
          ],
        },
        attachments: const <Map<String, dynamic>>[],
      );
      harness.fixture = tankSite;

      await tester.pumpWidget(
        _wrapDs(
          KeySiteModulePage(
            gateway: harness.gateway,
            site: tankSite,
            module: 'hazards',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('储罐'), findsOneWidget);
      expect(find.text('储罐编号：T-TEST'), findsOneWidget);
      expect(find.text('储罐容积（m³，非实际储量）：42'), findsOneWidget);
      expect(find.textContaining('实际储量（含单位）：'), findsNothing);

      await tester.enterText(find.byType(TextField), 'T-TEST');
      await tester.pump();
      expect(find.text('合成介质'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已发布资料隐藏原文出处但地图保留查看入口，并走鉴权瓦片', (tester) async {
      final harness = _FakeKeySiteHarness();
      addTearDown(harness.dispose);
      final attachment = <String, dynamic>{
        'id': 'map',
        'filename': '合成分区图.pdf',
        'metadata': <String, dynamic>{
          'pages': 2,
          'mapPages': <String, dynamic>{
            '1': const <String, dynamic>{
              'width': 256,
              'height': 256,
              'maxZoom': 0,
            },
            '2': const <String, dynamic>{
              'width': 256,
              'height': 256,
              'maxZoom': 0,
            },
          },
        },
      };
      final site = KeySiteVersion(
        siteId: 'one',
        version: 1,
        latestVersion: 1,
        publishedAt: 1,
        active: true,
        profile: const <String, dynamic>{'name': '合成单位'},
        content: const <String, List<KeySiteEntry>>{
          'cards': <KeySiteEntry>[
            KeySiteEntry(
              title: '已核对风险',
              body: '只展示核对后的正文',
              sources: <KeySiteSource>[
                KeySiteSource(
                  attachmentId: 'map',
                  page: 1,
                  paragraph: '不应展示的段落',
                ),
              ],
            ),
          ],
          'maps': <KeySiteEntry>[
            KeySiteEntry(
              title: '合成分区图',
              sources: <KeySiteSource>[
                KeySiteSource(attachmentId: 'map', page: 2),
              ],
            ),
          ],
        },
        attachments: <Map<String, dynamic>>[attachment],
      );
      harness.fixture = site;

      await tester.pumpWidget(
        _wrapDs(
          KeySiteModulePage(
            gateway: harness.gateway,
            site: site,
            module: 'cards',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('只展示核对后的正文'), findsOneWidget);
      expect(find.textContaining('原文出处'), findsNothing);
      expect(find.textContaining('不应展示的段落'), findsNothing);

      await tester.pumpWidget(
        _wrapDs(
          KeySiteModulePage(
            gateway: harness.gateway,
            site: site,
            module: 'maps',
            incidentId: 'inc-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('查看地图'), findsOneWidget);

      await tester.tap(find.text('查看地图'));
      await tester.pumpAndSettle();
      expect(harness.resources, contains('maps/2/tiles/0/0/0.jpg'));
      expect(harness.resources.where((r) => r.startsWith('pages/')), isEmpty);

      await tester.tap(find.byTooltip('上一页'));
      await tester.pumpAndSettle();
      expect(harness.resources, contains('maps/1/tiles/0/0/0.jpg'));

      await tester.tap(find.text('恢复全图'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      harness.revoke();
      await tester.pumpAndSettle();
      expect(find.text('合成分区图.pdf'), findsNothing);
    });

    testWidgets('地图缩至全图时，加载错误和重试位于像素变换之外且触控高度 >= 48dp', (
      tester,
    ) async {
      final harness = _FakeKeySiteHarness()..failImages = true;
      addTearDown(harness.dispose);
      final attachment = <String, dynamic>{
        'id': 'map',
        'filename': '合成大图.pdf',
        'metadata': <String, dynamic>{
          'pages': 1,
          'mapPages': <String, dynamic>{
            '1': const <String, dynamic>{
              'width': 6000,
              'height': 3000,
              'maxZoom': 5,
            },
          },
        },
      };
      final site = KeySiteVersion(
        siteId: 'one',
        version: 1,
        latestVersion: 1,
        publishedAt: 1,
        active: true,
        profile: const <String, dynamic>{'name': '合成单位'},
        content: const <String, List<KeySiteEntry>>{},
        attachments: <Map<String, dynamic>>[attachment],
      );
      harness.fixture = site;

      await tester.pumpWidget(
        _wrapDs(
          KeySiteDocumentPage(
            gateway: harness.gateway,
            site: site,
            attachment: attachment,
            map: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('网络未连接'), findsOneWidget);
      final banner = find.byKey(const ValueKey<String>('key-site-map-error-banner'));
      expect(banner, findsOneWidget);
      // 错误横幅不在 InteractiveViewer 子树内部
      expect(
        find.descendant(of: find.byType(InteractiveViewer), matching: banner),
        findsNothing,
      );

      final retryBtn = find.widgetWithText(CommandButton, '重试地图');
      expect(tester.getSize(retryBtn).height, greaterThanOrEqualTo(48));

      final before = harness.resources.length;
      harness.failImages = false;
      await tester.tap(retryBtn);
      await tester.pumpAndSettle();
      expect(harness.resources.length, greaterThan(before));
      expect(find.text('重试地图'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('360dp @ 130% 字体缩放双主题零溢出门禁', () {
    testWidgets('列表页、详情页、模块页在 360dp @ 130% 昼白与暗曜均零溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final harness = _FakeKeySiteHarness();
      addTearDown(harness.dispose);

      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _wrapDs(
            KeySitesPage(gateway: harness.gateway),
            brightness: brightness,
            textScale: 1.3,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('合成单位'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          _wrapDs(
            KeySiteDetailPage(
              gateway: harness.gateway,
              siteId: 'one',
              version: 1,
            ),
            brightness: brightness,
            textScale: 1.3,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('作战信息卡'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          _wrapDs(
            KeySiteModulePage(
              gateway: harness.gateway,
              site: _sampleSite(),
              module: 'plans',
            ),
            brightness: brightness,
            textScale: 1.3,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('预案目录'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  });
}
