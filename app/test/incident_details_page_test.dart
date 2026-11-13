import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/incident_details_page.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

const _incident = Incident(
  id: 'incident-details-test',
  number: '测试警情',
  status: 'active',
  createdAt: 1,
  lastActivityAt: 1,
);

class _DetailsApi extends ApiClient {
  _DetailsApi() : super(baseUrl: 'http://127.0.0.1', incidentId: _incident.id);

  @override
  ApiClient forIncident(String id) => this;

  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() async => {
    'data': {
      'original_category': '一级抢险救援',
      'location': '长宁区某街道靠近高架桥的重点单位北门',
      'situation': '现场有人员被困，救援通道已展开。',
      'contacts': [
        {'role': '值班员', 'name': '张三', 'phone': '13800138000'},
      ],
    },
    'version': 1,
    'imports': [],
    'observations': [
      {
        'id': 'obs-1',
        'captured_at': 1762329600000,
        'source_type': 'video',
        'transcript': '三楼东侧窗口有一名老人被困，正在升梯救援',
      },
    ],
  };
}

class _DetailsController extends AppController {
  int exitCalls = 0;
  int archiveCalls = 0;

  @override
  Future<void> exitCurrentIncident() async {
    exitCalls++;
  }

  @override
  Future<void> archiveCurrent() async {
    archiveCalls++;
  }
}

void main() {
  testWidgets('联系方式显示完整号码并可点击打开拨号', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final launched = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: IncidentDetailsPage(
          api: _DetailsApi(),
          incident: _incident,
          phoneLauncher: (uri) async {
            launched.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('13800138000'), findsOneWidget);
    expect(find.text('138••••8000'), findsNothing);
    expect(find.text('岗位人员与联系方式'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('13800138000'));
    await tester.pump();

    expect(launched, [Uri(scheme: 'tel', path: '13800138000')]);
  });

  testWidgets('渲染现场情况并展示录像语音记录明细', (tester) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: IncidentDetailsPage(
          api: _DetailsApi(),
          incident: _incident,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('现场情况'), findsOneWidget);
    expect(find.text('现场有人员被困，救援通道已展开。'), findsOneWidget);
    expect(find.text('录像语音记录 (1)'), findsOneWidget);

    await tester.tap(find.text('录像语音记录 (1)'));
    await tester.pumpAndSettle();

    expect(find.textContaining('三楼东侧窗口有一名老人被困'), findsOneWidget);
    expect(find.textContaining('· 录像语音'), findsOneWidget);
  });

  testWidgets('活动警情在详情页底部提供退出与归档入口且需二次确认', (tester) async {
    final controller = _DetailsController();
    addTearDown(controller.dispose);
    final api = _DetailsApi();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: IncidentDetailsPage(
          api: api,
          incident: _incident,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('details-exit-incident')),
      200,
    );
    expect(find.byKey(const Key('details-exit-incident')), findsOneWidget);
    expect(find.byKey(const Key('details-archive-incident')), findsOneWidget);

    await tester.tap(find.byKey(const Key('details-exit-incident')));
    await tester.pumpAndSettle();
    expect(find.text('确认退出'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.exitCalls, 0);

    await tester.tap(find.byKey(const Key('details-archive-incident')));
    await tester.pumpAndSettle();
    expect(find.text('确认归档'), findsOneWidget);
    await tester.tap(find.text('确认归档'));
    await tester.pumpAndSettle();
    expect(controller.archiveCalls, 1);
  });

  testWidgets('单机游客模式无 api 时也可本地渲染警情详情', (tester) async {
    const localIncident = Incident(
      id: 'guest-inc',
      number: '单机测试警情',
      title: '示例镇仓库火情',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 1,
      info: {'location': '示例县示例镇示例村', 'situation': '演练场景处置'},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const IncidentDetailsPage(incident: localIncident),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('示例镇仓库火情'), findsOneWidget);
    expect(find.text('示例县示例镇示例村'), findsOneWidget);
    expect(find.text('演练场景处置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
