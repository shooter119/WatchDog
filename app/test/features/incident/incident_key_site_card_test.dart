import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/ui/widgets/incident_key_site_card.dart';

class _AccessHarness extends ChangeNotifier {
  bool canRead = true;
  int epoch = 1;

  void revoke() {
    canRead = false;
    epoch++;
    notifyListeners();
  }

  void bumpEpoch() {
    epoch++;
    notifyListeners();
  }
}

Widget _wrap(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: w!,
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  const activeIncident = Incident(
    id: 'inc-ks-1',
    number: '2026-11-16-01',
    status: 'active',
    createdAt: 1,
    lastActivityAt: 1,
    keySiteLinkRevision: 3,
  );

  group('IncidentKeySiteCard', () {
    testWidgets('canReadKeySites == false 时严格隐藏不发起加载', (
      WidgetTester tester,
    ) async {
      final access = _AccessHarness()..canRead = false;
      addTearDown(access.dispose);
      var fetchCalls = 0;

      await tester.pumpWidget(
        _wrap(
          IncidentKeySiteCard(
            accessListenable: access,
            canReadKeySites: () => access.canRead,
            protectedDataEpoch: () => access.epoch,
            incident: activeIncident,
            fetchIncidentKeySite: (String id) async {
              fetchCalls++;
              return <String, dynamic>{'revision': 0};
            },
            onPickKeySite: (_) async => null,
            fetchLatestKeySite: (String id) async =>
                const KeySiteCandidate(siteId: 's1', name: '示例厂', version: 1),
            onChangeKeySiteLink: ({
              required String incidentId,
              required int revision,
              KeySiteCandidate? site,
              required String operationId,
            }) async {},
            onOpenKeySiteDetail: (_, _, _, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fetchCalls, 0);
      expect(find.text('绑定重点单位'), findsNothing);
    });

    testWidgets('未绑定态可选择重点单位并按乐观锁 revision 提交绑定', (
      WidgetTester tester,
    ) async {
      final access = _AccessHarness();
      addTearDown(access.dispose);
      var state = <String, dynamic>{'revision': 3, 'link': null};
      int? capturedRevision;
      KeySiteCandidate? capturedSite;

      await tester.pumpWidget(
        _wrap(
          IncidentKeySiteCard(
            accessListenable: access,
            canReadKeySites: () => access.canRead,
            protectedDataEpoch: () => access.epoch,
            incident: activeIncident,
            fetchIncidentKeySite: (String id) async => state,
            onPickKeySite: (_) async =>
                const KeySiteCandidate(siteId: 's1', name: '示例化工园', version: 1),
            fetchLatestKeySite: (String id) async =>
                const KeySiteCandidate(siteId: 's1', name: '示例化工园', version: 2),
            onChangeKeySiteLink: ({
              required String incidentId,
              required int revision,
              KeySiteCandidate? site,
              required String operationId,
            }) async {
              capturedRevision = revision;
              capturedSite = site;
              state = <String, dynamic>{
                'revision': revision + 1,
                'active': true,
                'newVersionAvailable': false,
                'link': <String, dynamic>{
                  'siteId': site!.siteId,
                  'name': site.name,
                  'address': '示例地址',
                  'version': site.version,
                  'linkedBy': 'm1',
                  'linkedByName': '张三',
                  'linkedAt': 10,
                },
              };
            },
            onOpenKeySiteDetail: (_, _, _, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('绑定重点单位'), findsOneWidget);
      await tester.tap(find.byKey(const Key('key-site-search')));
      await tester.pumpAndSettle();

      expect(find.text('核对重点单位'), findsOneWidget);
      expect(find.text('确认关联“示例化工园”？'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(capturedRevision, 3);
      expect(capturedSite?.version, 2);
      expect(find.text('示例化工园'), findsOneWidget);
    });

    testWidgets('确认弹窗打开期间吊销权限，立即隐藏敏感单位名称并禁止提交', (
      WidgetTester tester,
    ) async {
      final access = _AccessHarness();
      addTearDown(access.dispose);
      var changes = 0;

      await tester.pumpWidget(
        _wrap(
          IncidentKeySiteCard(
            accessListenable: access,
            canReadKeySites: () => access.canRead,
            protectedDataEpoch: () => access.epoch,
            incident: activeIncident,
            fetchIncidentKeySite: (_) async => <String, dynamic>{'revision': 1},
            onPickKeySite: (_) async =>
                const KeySiteCandidate(siteId: 's1', name: '示例涉密厂', version: 1),
            fetchLatestKeySite: (_) async =>
                const KeySiteCandidate(siteId: 's1', name: '示例涉密厂', version: 1),
            onChangeKeySiteLink: ({
              required String incidentId,
              required int revision,
              KeySiteCandidate? site,
              required String operationId,
            }) async {
              changes++;
            },
            onOpenKeySiteDetail: (_, _, _, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('key-site-search')));
      await tester.pumpAndSettle();
      expect(find.textContaining('示例涉密厂'), findsOneWidget);

      access.revoke();
      await tester.pumpAndSettle();

      expect(find.textContaining('示例涉密厂'), findsNothing);
      expect(find.text('认证已失效，请重新认证'), findsOneWidget);
      expect(find.text('确认'), findsNothing);
      expect(changes, 0);
    });

    testWidgets('已绑定态展示标签、打开详情回调与新版人工核对更新', (WidgetTester tester) async {
      final access = _AccessHarness();
      addTearDown(access.dispose);
      (String, int, String)? openedDetail;
      KeySiteCandidate? updatedTo;

      await tester.pumpWidget(
        _wrap(
          IncidentKeySiteCard(
            accessListenable: access,
            canReadKeySites: () => access.canRead,
            protectedDataEpoch: () => access.epoch,
            incident: activeIncident,
            fetchIncidentKeySite: (_) async => <String, dynamic>{
              'revision': 4,
              'active': true,
              'newVersionAvailable': true,
              'link': <String, dynamic>{
                'siteId': 's1',
                'name': '示例化工企业',
                'address': '示例工业路1号',
                'version': 1,
                'linkedBy': 'm1',
                'linkedByName': '张三',
                'linkedAt': 10,
              },
              'history': <Map<String, dynamic>>[
                <String, dynamic>{
                  'site_id': 's1',
                  'version': 1,
                  'profile': <String, dynamic>{
                    'district': '示例区',
                    'site_type': '化工企业',
                  },
                },
              ],
            },
            onPickKeySite: (_) async => null,
            fetchLatestKeySite: (_) async =>
                const KeySiteCandidate(siteId: 's1', name: '示例化工企业', version: 2),
            onChangeKeySiteLink: ({
              required String incidentId,
              required int revision,
              KeySiteCandidate? site,
              required String operationId,
            }) async {
              updatedTo = site;
            },
            onOpenKeySiteDetail: (_, String id, int version, String incId) {
              openedDetail = (id, version, incId);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('示例化工企业'), findsOneWidget);
      expect(find.text('示例区'), findsOneWidget);
      expect(find.text('化工企业'), findsOneWidget);
      expect(find.text('已有新版资料，请人工核对后更新'), findsOneWidget);

      await tester.tap(find.byKey(const Key('key-site-open')));
      await tester.pump();
      expect(openedDetail, ('s1', 1, 'inc-ks-1'));

      await tester.tap(find.byKey(const Key('key-site-update')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(updatedTo?.version, 2);
    });

    testWidgets('protectedDataEpoch 推进或 keySiteLinkRevision 变化触发重新拉取', (
      WidgetTester tester,
    ) async {
      final access = _AccessHarness();
      addTearDown(access.dispose);
      var fetchCount = 0;

      Widget buildCard(Incident inc) => _wrap(
        IncidentKeySiteCard(
          accessListenable: access,
          canReadKeySites: () => access.canRead,
          protectedDataEpoch: () => access.epoch,
          incident: inc,
          fetchIncidentKeySite: (_) async {
            fetchCount++;
            return <String, dynamic>{'revision': inc.keySiteLinkRevision};
          },
          onPickKeySite: (_) async => null,
          fetchLatestKeySite: (_) async =>
              const KeySiteCandidate(siteId: 's1', name: '示例厂', version: 1),
          onChangeKeySiteLink: ({
            required String incidentId,
            required int revision,
            KeySiteCandidate? site,
            required String operationId,
          }) async {},
          onOpenKeySiteDetail: (_, _, _, _) {},
        ),
      );

      await tester.pumpWidget(buildCard(activeIncident));
      await tester.pumpAndSettle();
      expect(fetchCount, 1);

      access.bumpEpoch();
      await tester.pumpAndSettle();
      expect(fetchCount, 2);

      await tester.pumpWidget(
        buildCard(
          const Incident(
            id: 'inc-ks-1',
            number: '2026-11-16-01',
            status: 'active',
            createdAt: 1,
            lastActivityAt: 1,
            keySiteLinkRevision: 5,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fetchCount, 3);
    });

    testWidgets('360dp @ 130% 大字号下已绑定重点单位卡零溢出且按钮热区 >= 48dp', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final access = _AccessHarness();
      addTearDown(access.dispose);

      await tester.pumpWidget(
        _wrap(
          IncidentKeySiteCard(
            accessListenable: access,
            canReadKeySites: () => access.canRead,
            protectedDataEpoch: () => access.epoch,
            incident: activeIncident,
            fetchIncidentKeySite: (_) async => <String, dynamic>{
              'revision': 2,
              'active': true,
              'newVersionAvailable': true,
              'link': <String, dynamic>{
                'siteId': 's1',
                'name': '示例开发区综合化工仓储中心',
                'address': '示例路',
                'version': 1,
                'linkedBy': 'm1',
                'linkedByName': '张三',
                'linkedAt': 10,
              },
            },
            onPickKeySite: (_) async => null,
            fetchLatestKeySite: (_) async =>
                const KeySiteCandidate(siteId: 's1', name: '示例', version: 2),
            onChangeKeySiteLink: ({
              required String incidentId,
              required int revision,
              KeySiteCandidate? site,
              required String operationId,
            }) async {},
            onOpenKeySiteDetail: (_, _, _, _) {},
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const Key('key-site-open'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const Key('key-site-change'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const Key('key-site-remove'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
