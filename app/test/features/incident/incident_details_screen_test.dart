import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/data/incident_import_repository.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/ui/incident_details_screen.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_basic_info_sheet.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_details_edit_sheet.dart';

class _FakeImportRepository extends IncidentImportRepository {
  _FakeImportRepository()
    : super(ApiHttpTransport(const ApiConfig(baseUrl: 'http://127.0.0.1', incidentId: 'inc-details')));

  Map<String, dynamic> detailPayload = <String, dynamic>{
    'data': <String, dynamic>{
      'original_category': '一级抢险救援',
      'location': '示例区示范街道重点单位北门',
      'situation': '现场有人员被困，救援通道已展开。',
      'contacts': <Map<String, dynamic>>[
        <String, dynamic>{'role': '值班员', 'name': '张三', 'phone': '13800138000'},
        <String, dynamic>{'role': '物业', 'name': '李四', 'phone': '138****8001'},
      ],
      'risks': <String>['建筑外墙玻璃存在高空坠落风险'],
    },
    'version': 2,
    'imports': <Map<String, dynamic>>[
      <String, dynamic>{
        'source': 'text',
        'actor_name': '张三',
        'pages': <Map<String, dynamic>>[
          <String, dynamic>{'index': 1, 'raw_text': '119接警单正文记录'},
        ],
      },
    ],
    'observations': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'obs-1',
        'captured_at': 1762329600000,
        'source_type': 'video',
        'transcript': '三楼东侧窗口有一名老人被困，正在升梯救援',
      },
    ],
  };

  Map<String, dynamic>? lastUpdatedData;
  int? lastUpdatedVersion;

  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() async =>
      Map<String, dynamic>.from(detailPayload);

  @override
  Future<Map<String, dynamic>> updateIncidentDetails(
    Map<String, dynamic> data,
    int version,
    String opId,
  ) async {
    lastUpdatedData = Map<String, dynamic>.from(data);
    lastUpdatedVersion = version;
    detailPayload = <String, dynamic>{
      ...detailPayload,
      'data': <String, dynamic>{
        ...(detailPayload['data'] as Map<String, dynamic>),
        ...data,
      },
      'version': version + 1,
    };
    return <String, dynamic>{'ok': true, 'version': version + 1};
  }
}

const Incident _incident = Incident(
  id: 'inc-details',
  number: '测试警情',
  title: '示范街道抢险救援',
  status: 'active',
  createdAt: 1,
  lastActivityAt: 1,
);

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
    home: child,
  );
}

void main() {
  group('IncidentDetailsScreen', () {
    testWidgets('展示联系方式完整号码并可点击拨号，脱敏号码不显示拨打钮', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final dialed = <Uri>[];
      await tester.pumpWidget(
        _wrap(
          IncidentDetailsScreen(
            incident: _incident,
            importRepository: _FakeImportRepository(),
            phoneLauncher: (Uri uri) async {
              dialed.add(uri);
              return true;
            },
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('岗位人员与联系方式'), findsOneWidget);
      expect(find.text('13800138000'), findsOneWidget);
      expect(find.text('138****8001'), findsOneWidget);
      expect(find.text('拨打'), findsOneWidget);

      await tester.tap(find.text('13800138000'));
      await tester.pump();
      expect(dialed, <Uri>[Uri(scheme: 'tel', path: '13800138000')]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('展示现场情况、录像语音记录与导入历史并可展开查阅', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          IncidentDetailsScreen(
            incident: _incident,
            importRepository: _FakeImportRepository(),
            keySiteSlot: const SurfaceCard(
              key: Key('injected-key-site-slot'),
              child: Text('重点单位槽位'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('injected-key-site-slot')), findsOneWidget);
      expect(find.text('现场有人员被困，救援通道已展开。'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('录像语音记录 (1)'), 200);
      await tester.ensureVisible(find.text('录像语音记录 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('录像语音记录 (1)'), findsOneWidget);
      await tester.tap(find.text('录像语音记录 (1)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('三楼东侧窗口有一名老人被困'), findsOneWidget);
      expect(find.textContaining('· 录像语音'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('文字导入记录'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('文字导入记录'), findsOneWidget);
    });

    testWidgets('编辑警情资料通过 CommandSheet 提交并携带乐观锁版本号', (
      WidgetTester tester,
    ) async {
      final repo = _FakeImportRepository();
      var updatedCount = 0;

      await tester.pumpWidget(
        _wrap(
          IncidentDetailsScreen(
            incident: _incident,
            importRepository: repo,
            onDetailsUpdated: () => updatedCount++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-details-edit-btn')));
      await tester.pumpAndSettle();
      expect(find.text('修改警情资料'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('incident-detail-field-location')),
        '示例区新路99号',
      );
      await tester.tap(find.byKey(const Key('incident-details-edit-save-btn')));
      await tester.pumpAndSettle();

      expect(repo.lastUpdatedVersion, 2);
      expect(repo.lastUpdatedData?['location'], '示例区新路99号');
      expect(updatedCount, 1);
      expect(find.text('示例区新路99号'), findsOneWidget);
    });

    testWidgets('活动警情底部退出与归档按钮需经 CommandSheet 二次确认', (
      WidgetTester tester,
    ) async {
      var exits = 0;
      var archives = 0;

      await tester.pumpWidget(
        _wrap(
          IncidentDetailsScreen(
            incident: _incident,
            importRepository: _FakeImportRepository(),
            onExitIncident: () async => exits++,
            onArchiveIncident: () async => archives++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('details-exit-incident')),
        200,
      );
      await tester.tap(find.byKey(const Key('details-exit-incident')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(exits, 0);

      await tester.scrollUntilVisible(
        find.byKey(const Key('details-archive-incident')),
        200,
      );
      await tester.tap(find.byKey(const Key('details-archive-incident')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('incident-archive-confirm-btn')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('incident-archive-confirm-btn')));
      await tester.pumpAndSettle();
      expect(archives, 1);
    });

    testWidgets('单机游客模式无 importRepository 时本地渲染 incident.info', (
      WidgetTester tester,
    ) async {
      const localIncident = Incident(
        id: 'guest-inc',
        number: '单机测试警情',
        title: '示例镇仓库火情',
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
        info: <String, dynamic>{
          'location': '示例县示例镇示例村',
          'situation': '演练场景处置',
        },
      );

      await tester.pumpWidget(
        _wrap(const IncidentDetailsScreen(incident: localIncident)),
      );
      await tester.pumpAndSettle();

      expect(find.text('示例镇仓库火情'), findsOneWidget);
      expect(find.text('示例县示例镇示例村'), findsOneWidget);
      expect(find.text('演练场景处置'), findsOneWidget);
      expect(find.byKey(const Key('incident-details-edit-btn')), findsNothing);
    });

    testWidgets('空资料活跃警情显示「手动填写资料」按钮，事发地点置顶且支持一键定位提交坐标', (
      WidgetTester tester,
    ) async {
      expect(incidentDetailFieldLabels.keys.first, 'location');
      expect(incidentDetailFieldLabels['location'], '事发地点');

      final repo = _FakeImportRepository()
        ..detailPayload = <String, dynamic>{
          'data': <String, dynamic>{},
          'version': 0,
          'imports': const <dynamic>[],
          'observations': const <dynamic>[],
        };
      var updatedCount = 0;

      await tester.pumpWidget(
        _wrap(
          IncidentDetailsScreen(
            incident: _incident,
            importRepository: repo,
            onLocateAddress: () async => const IncidentLocatedAddress(
              address: '示例区示范路168号',
              latitude: 31.2304,
              longitude: 121.4737,
            ),
            onDetailsUpdated: () => updatedCount++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('手动填写资料'), findsOneWidget);
      await tester.tap(find.text('手动填写资料'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-details-edit-save-btn')));
      await tester.pumpAndSettle();

      expect(repo.lastUpdatedVersion, 0);
      expect(repo.lastUpdatedData?['location'], '示例区示范路168号');
      expect(repo.lastUpdatedData?['latitude'], '31.230400');
      expect(repo.lastUpdatedData?['longitude'], '121.473700');
      expect(updatedCount, 1);
      expect(find.text('示例区示范路168号'), findsOneWidget);
    });

    testWidgets('主标题置顶于重点单位之上，清洗 ISO 接警时间、去重重复联系人与重复摘要，且归档按钮克制展示', (
      WidgetTester tester,
    ) async {
      final repo = _FakeImportRepository()
        ..detailPayload = <String, dynamic>{
          'data': <String, dynamic>{
            'location': '示例县示范街道1号楼',
            'event_summary': '示范街道抢险救援',
            'original_category': '火灾扑救',
            'level': '一级',
            'specific_type': '电线起火',
            'received_at': '2026-11-24T21:19:40+08:00',
            'administrative_area': '示例县',
            'dispatch_summary': '3车 1站（主调：示例路站）',
            'situation': '现场明火已扑灭，正在排烟降温。',
            'contacts': <Map<String, dynamic>>[
              <String, dynamic>{
                'role': '报警人',
                'name': '报警人',
                'phone': '13800138000',
              },
            ],
          },
          'version': 1,
          'imports': const <dynamic>[],
          'observations': const <dynamic>[],
        };

      await tester.pumpWidget(
        _wrap(
          IncidentDetailsScreen(
            incident: _incident,
            importRepository: repo,
            keySiteSlot: const SurfaceCard(
              key: Key('injected-key-site-slot'),
              child: Text('重点单位槽位'),
            ),
            onExitIncident: () async {},
            onArchiveIncident: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 主标题位于重点单位槽位上方
      final titleTop = tester
          .getTopLeft(find.byKey(const Key('incident-details-title')))
          .dy;
      final keySiteTop = tester
          .getTopLeft(find.byKey(const Key('injected-key-site-slot')))
          .dy;
      expect(titleTop, lessThan(keySiteTop));

      // 2. 与主标题完全一致的事件摘要自动去重
      expect(find.text('事件摘要'), findsNothing);

      // 3. ISO-8601 接警时间已清洗为可读格式
      expect(find.text('2026-11-24T21:19:40+08:00'), findsNothing);
      expect(find.text('2026-11-24 21:19:40'), findsOneWidget);

      // 4. 联系人 role 与 name 同值去重
      expect(find.text('报警人 · 报警人'), findsNothing);
      expect(find.text('报警人'), findsOneWidget);

      // 5. 归档按钮使用克制的 dangerOutlined 变体
      await tester.scrollUntilVisible(
        find.byKey(const Key('details-archive-incident')),
        200,
      );
      final archiveBtn = tester.widget<CommandButton>(
        find.byKey(const Key('details-archive-incident')),
      );
      expect(archiveBtn.variant, CommandButtonVariant.dangerOutlined);
      expect(tester.takeException(), isNull);
    });
  });
}
