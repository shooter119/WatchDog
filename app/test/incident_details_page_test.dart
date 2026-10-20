import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/incident_details_page.dart';
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
  };
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
}
