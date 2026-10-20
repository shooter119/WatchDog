import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/incident_import_page.dart';
import 'package:watchdog/theme/app_theme.dart';

const incident = Incident(
  id: 'incident-test',
  number: '默认警情',
  status: 'active',
  createdAt: 1,
  lastActivityAt: 1,
);

class ImportApi extends ApiClient {
  Map<String, dynamic>? applied;
  String? opId;
  ImportApi() : super(baseUrl: 'http://127.0.0.1', incidentId: incident.id);
  @override
  ApiClient forIncident(String id) => this;
  @override
  Future<List<Map<String, dynamic>>> fetchIncidentImports() async => [];
  Map<String, dynamic> get task => {
    'id': 'task',
    'status': 'ready',
    'source': 'text',
    'pages': [
      {
        'index': 1,
        'status': 'succeeded',
        'result': {'raw_text': '某村电表箱起火，甲站2车10人，调派乙队。'},
      },
    ],
    'draft': {
      'details': {
        'suggested_title': '某村电表箱火灾',
        'original_category': '火灾扑救',
        'location': '某村',
        'contacts': [],
      },
      'forces': [
        {'station_name': '甲站', 'vehicle_count': 2, 'personnel_count': 10},
        {'station_name': '乙队', 'vehicle_count': null, 'personnel_count': null},
      ],
      'conflicts': [],
    },
  };
  @override
  Future<Map<String, dynamic>> createIncidentImport({
    String? text,
    List<Uint8List> images = const [],
  }) async => task;
  @override
  Future<Map<String, dynamic>> fetchIncidentImport(String id) async => task;
  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() async => {
    'data': {},
    'version': 0,
  };
  @override
  Future<Incident> fetchIncident(String id) async => incident;
  @override
  Future<List<IncidentForce>> fetchIncidentForces({
    String? forIncidentId,
  }) async => [];
  @override
  Future<List<Map<String, dynamic>>> fetchUnitStations({
    bool includeInactive = false,
  }) async => [];
  @override
  Future<List<Station>> fetchStations() async => [];
  @override
  Future<Map<String, dynamic>> applyIncidentImport(
    String id,
    Map<String, dynamic> body,
    String op,
  ) async {
    applied = body;
    opId = op;
    return {'ok': true};
  }
}

class MultipleIncidentApi extends ImportApi {
  @override
  Map<String, dynamic> get task {
    final value = super.task;
    final draft = value['draft'] as Map<String, dynamic>;
    (draft['details'] as Map<String, dynamic>)['multiple_incidents'] = true;
    ((value['pages'] as List).first['result'] as Map)['suggested_title'] =
        '这是一个包含详细地址和单位名称的很长很长的警情名称用于验证窄屏选择框';
    return value;
  }
}

void main() {
  testWidgets('多警情长名称在窄屏大字体下不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: IncidentImportPage(
          api: MultipleIncidentApi(),
          incident: incident,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '甲村火灾，乙村救助');
    await tester.ensureVisible(find.text('开始分析'));
    await tester.tap(find.text('开始分析'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('文字导入需核对后应用，未知数量不编造', (tester) async {
    final api = ImportApi();
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        IncidentImportPage(api: api, incident: incident),
                  ),
                );
              },
              child: const Text('导入'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      '某村电表箱起火，甲站2车10人，调派乙队。',
    );
    await tester.tap(find.text('开始分析'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('确认导入信息'), findsOneWidget);
    expect(api.applied, isNull);
    expect(find.textContaining('车辆待补充'), findsWidgets);
    final submit = find.text('确认并更新警情');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(api.applied!['title'], '某村电表箱火灾');
    final forces = api.applied!['forces'] as List;
    expect(forces[1]['vehicle_count_known'], isFalse);
    expect(forces[1]['personnel_count_known'], isFalse);
    expect(api.opId, isNotEmpty);
  });
  testWidgets('信息导入入口提供拍照、相册和文字三种方式', (tester) async {
    final api = ImportApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: IncidentImportPage(
          api: api,
          incident: incident,
          chooseSourceOnOpen: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '拍照'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '从手机相册选择'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '文字导入'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });
}
