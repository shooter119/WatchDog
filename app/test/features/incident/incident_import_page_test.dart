import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/data/models/incident_force.dart';
import 'package:watchdog/features/incident/state/incident_import_store.dart';
import 'package:watchdog/features/incident/ui/incident_import_page.dart';

const Incident _testIncident = Incident(
  id: 'incident-test',
  number: '默认警情',
  status: 'active',
  createdAt: 1,
  lastActivityAt: 1,
);

class _FakeImportGateway implements IncidentImportGateway {
  Map<String, dynamic>? appliedBody;
  String? appliedOpId;
  int applyAttempts = 0;
  int cancelCalls = 0;
  int retryCalls = 0;
  bool failFirstApplyWith500 = false;
  bool startWithFailedPage = false;
  bool multipleIncidents = false;
  List<Map<String, dynamic>> resumeList = const <Map<String, dynamic>>[];

  Map<String, dynamic> _readyTask() {
    final details = <String, dynamic>{
      'suggested_title': '某村电表箱火灾',
      'original_category': '火灾扑救',
      'location': '某村',
      'contacts': const <dynamic>[],
      if (multipleIncidents) 'multiple_incidents': true,
    };
    return <String, dynamic>{
      'id': 'task-1',
      'status': 'ready',
      'source': 'text',
      'pages': <Map<String, dynamic>>[
        <String, dynamic>{
          'index': 1,
          'status': 'succeeded',
          'result': <String, dynamic>{
            'raw_text': '某村电表箱起火，甲站2车10人，调派乙队。',
            if (multipleIncidents)
              'suggested_title': '这是一个包含详细地址和单位名称的很长很长的警情名称用于验证窄屏选择框',
          },
        },
      ],
      'draft': <String, dynamic>{
        'details': details,
        'forces': <Map<String, dynamic>>[
          <String, dynamic>{'station_name': '甲站', 'vehicle_count': 2, 'personnel_count': 10},
          <String, dynamic>{'station_name': '乙队', 'vehicle_count': null, 'personnel_count': null},
        ],
        'conflicts': const <dynamic>[],
      },
    };
  }

  Map<String, dynamic> _failedTask() => <String, dynamic>{
    'id': 'task-1',
    'status': 'failed',
    'source': 'images',
    'pages': <Map<String, dynamic>>[
      <String, dynamic>{'index': 1, 'status': 'failed'},
    ],
  };

  @override
  String get cacheScope => '';

  @override
  Future<List<Map<String, dynamic>>> fetchIncidentImports() async => resumeList;

  @override
  Future<Map<String, dynamic>> createIncidentImport({
    String? text,
    List<Uint8List> images = const <Uint8List>[],
  }) async => startWithFailedPage ? _failedTask() : _readyTask();

  @override
  Future<Map<String, dynamic>> fetchIncidentImport(String taskId) async =>
      startWithFailedPage ? _failedTask() : _readyTask();

  @override
  Future<Uint8List> fetchImportImage(String taskId, int page) async =>
      Uint8List.fromList(<int>[1, 2, 3]);

  @override
  Future<Map<String, dynamic>> retryIncidentImport(String taskId, List<int> pages) async {
    retryCalls++;
    startWithFailedPage = false;
    return <String, dynamic>{
      'id': taskId,
      'status': 'processing',
      'source': 'images',
      'pages': <Map<String, dynamic>>[
        <String, dynamic>{'index': 1, 'status': 'processing'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> cancelIncidentImport(String taskId) async {
    cancelCalls++;
    return <String, dynamic>{'ok': true};
  }

  @override
  Future<Map<String, dynamic>> applyIncidentImport(
    String taskId,
    Map<String, dynamic> body,
    String opId,
  ) async {
    applyAttempts++;
    if (failFirstApplyWith500 && applyAttempts == 1) {
      throw ApiException('网络超时', statusCode: 503);
    }
    appliedBody = body;
    appliedOpId = opId;
    return <String, dynamic>{'ok': true};
  }

  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() async =>
      <String, dynamic>{'data': <String, dynamic>{}, 'version': 0};

  @override
  Future<Incident> fetchIncident(String incidentId) async => _testIncident;

  @override
  Future<List<IncidentForce>> fetchIncidentForces() async => const <IncidentForce>[];

  @override
  Future<List<ImportStationOption>> fetchStationOptions() async => const <ImportStationOption>[
    ImportStationOption(id: 'u-1', name: '示例路消防站', isUnitStation: true),
  ];
}

Widget _wrapApp(
  Widget home, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    themeAnimationDuration: Duration.zero,
    builder: (BuildContext context, Widget? child) => MediaQuery(
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
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('多警情长名称在窄屏大字体下不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gw = _FakeImportGateway()..multipleIncidents = true;
    await tester.pumpWidget(
      _wrapApp(
        IncidentImportPage(gateway: gw, incident: _testIncident),
        textScale: 1.5,
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

  testWidgets('文字导入三阶段流转：核对后应用，未知数量不编造，并生成幂等 opId', (tester) async {
    final gw = _FakeImportGateway();
    bool? result;

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute<bool>(
                    builder: (_) => IncidentImportPage(gateway: gw, incident: _testIncident),
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
      find.byKey(const Key('import-text-field')),
      '某村电表箱起火，甲站2车10人，调派乙队。',
    );
    await tester.tap(find.byKey(const Key('import-start-btn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('确认导入信息'), findsOneWidget);
    expect(gw.appliedBody, isNull);
    expect(find.textContaining('车辆待补充'), findsWidgets);

    await tester.tap(find.byKey(const Key('import-apply-btn')));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(gw.appliedBody!['title'], '某村电表箱火灾');
    final forces = gw.appliedBody!['forces'] as List;
    expect(forces[1]['vehicle_count_known'], isFalse);
    expect(forces[1]['personnel_count_known'], isFalse);
    expect(gw.appliedOpId, isNotEmpty);
  });

  testWidgets('信息导入入口提供拍照、相册和文字三种方式', (tester) async {
    final gw = _FakeImportGateway();
    await tester.pumpWidget(
      _wrapApp(
        IncidentImportPage(
          gateway: gw,
          incident: _testIncident,
          chooseSourceOnOpen: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '拍照'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '从手机相册选择'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '文字导入'), findsOneWidget);
  });

  testWidgets('支持出动力量核对编辑抽屉校验与更新', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gw = _FakeImportGateway();
    await tester.pumpWidget(
      _wrapApp(IncidentImportPage(gateway: gw, incident: _testIncident)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('import-text-field')), '某村起火');
    await tester.tap(find.byKey(const Key('import-start-btn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('import-force-edit-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-force-edit-1')));
    await tester.pumpAndSettle();

    expect(find.text('核对出动力量'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('import-force-vehicles-field')), '1200');
    await tester.tap(find.byKey(const Key('import-force-save-btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-force-validation-error')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('import-force-vehicles-field')), '3');
    await tester.enterText(find.byKey(const Key('import-force-people-field')), '15');
    await tester.tap(find.byKey(const Key('import-force-save-btn')));
    await tester.pumpAndSettle();

    expect(find.textContaining('3车 · 15人'), findsOneWidget);
  });

  testWidgets('失败页支持重试恢复、取消导入需二次确认且提交超时支持防重复重试', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gw = _FakeImportGateway()
      ..startWithFailedPage = true
      ..failFirstApplyWith500 = true;

    await tester.pumpWidget(
      _wrapApp(IncidentImportPage(gateway: gw, incident: _testIncident)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('import-text-field')), '测试失败重试');
    await tester.tap(find.byKey(const Key('import-start-btn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('import-retry-failed-pages-btn')), findsOneWidget);

    // 取消二次确认：选「继续保留」不取消
    await tester.tap(find.byKey(const Key('import-cancel-polling-btn')));
    await tester.pumpAndSettle();
    expect(find.text('确认取消导入'), findsOneWidget);
    await tester.tap(find.text('继续保留'));
    await tester.pumpAndSettle();
    expect(gw.cancelCalls, 0);

    // 点击重试失败页 -> 轮询恢复到确认阶段
    await tester.tap(find.byKey(const Key('import-retry-failed-pages-btn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(gw.retryCalls, 1);
    expect(find.text('确认导入信息'), findsOneWidget);

    // 首次提交 503 失败 -> 进入防重复重试态 -> 重试成功
    await tester.tap(find.byKey(const Key('import-apply-btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-pending-apply-card')), findsOneWidget);

    await tester.tap(find.byKey(const Key('import-retry-apply-btn')));
    await tester.pumpAndSettle();
    expect(gw.applyAttempts, 2);
    expect(gw.appliedOpId, isNotEmpty);
  });

  testWidgets('360dp @ 130% 大字号下多图旋转预览与确认页零溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gw = _FakeImportGateway();
    var rotateTurns = 0;
    final store = IncidentImportStore(
      gateway: gw,
      incident: _testIncident,
      imagePreparer: (Map<String, dynamic> input) async {
        rotateTurns += (input['turns'] as int? ?? 0);
        return Uint8List.fromList(<int>[1, 2, 3, rotateTurns]);
      },
    );
    addTearDown(store.dispose);

    await store.appendImageFiles(<ImportImageFile>[
      ImportImageFile(
        path: 'sample.jpg',
        readLength: () async => 4,
        readBytes: () async => Uint8List.fromList(<int>[1, 2, 3, 4]),
      ),
    ]);

    await tester.pumpWidget(
      _wrapApp(
        IncidentImportPage(gateway: gw, incident: _testIncident, store: store),
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已选1/9张 · 长按拖动排序'), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-image-rotate-0')));
    await tester.pumpAndSettle();
    expect(rotateTurns, 1);
    expect(tester.takeException(), isNull);
  });
}
