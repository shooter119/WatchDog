import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_palette.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';
import 'package:watchdog/widgets/incident_category_badge.dart';

class _TestAudio extends AudioService {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {}

  @override
  Stream<double> amplitudeStream() => const Stream.empty();

  @override
  Future<Uint8List> stop() async => Uint8List(0);

  @override
  Future<void> dispose() async {}
}

class _TestAdjustApi extends ApiClient {
  _TestAdjustApi({Map<String, dynamic>? initialData})
    : detailData = Map<String, dynamic>.from(
        initialData ?? {'original_category': '一级火灾扑救'},
      ),
      super(baseUrl: 'http://test', incidentId: 'i-adjust');

  Map<String, dynamic> detailData;
  Map<String, dynamic>? updatedData;
  int detailsVersion = 1;

  @override
  ApiClient forIncident(String id) => this;

  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() async => {
    'data': Map<String, dynamic>.from(detailData),
    'version': detailsVersion,
  };

  @override
  Future<Map<String, dynamic>> updateIncidentDetails(
    Map<String, dynamic> data,
    int version,
    String opId,
  ) async {
    updatedData = Map<String, dynamic>.from(data);
    detailData = Map<String, dynamic>.from(data);
    detailsVersion++;
    return {'ok': true, 'version': detailsVersion};
  }

  @override
  Future<Incident> fetchIncident(String id) async => Incident(
    id: id,
    number: '2026-11-13-09',
    status: 'active',
    createdAt: 1,
    lastActivityAt: 1,
    info: Map<String, dynamic>.from(detailData),
  );

  @override
  Future<List<IncidentForce>> fetchIncidentForces({
    String? forIncidentId,
  }) async => const [];
}

class _TestController extends AppController {
  _TestController({
    Incident? incident,
    List<IncidentForce> forces = const [],
  }) : super() {
    currentIncident = incident;
    this.forces = forces;
    asrCloudEnabled = true;
    parseCloudEnabled = true;
  }

  @override
  bool get needsAuthentication => false;

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}
}

Future<void> _pumpHome(WidgetTester tester, _TestController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (_, __) =>
              HomePage(controller: controller, audioService: _TestAudio()),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController.instance.resetForTest();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
  });

  group('警情三类分类与图标', () {
    test('classify 按主类别与关键词归入灭火/抢险/救助且空白默认灭火', () {
      expect(IncidentCategory.classify(), IncidentCategory.fire);
      expect(
        IncidentCategory.classify(category: '一级火灾扑救'),
        IncidentCategory.fire,
      );
      expect(
        IncidentCategory.classify(category: '二级抢险救援'),
        IncidentCategory.rescue,
      );
      expect(
        IncidentCategory.classify(category: '社会救助'),
        IncidentCategory.aid,
      );
      expect(
        IncidentCategory.classify(situation: '电梯困人请求开锁协助'),
        IncidentCategory.aid,
      );
      expect(
        IncidentCategory.classify(situation: '高速路段货车侧翻漏油'),
        IncidentCategory.rescue,
      );
    });

    testWidgets('三类 Badge 渲染正确 Key 与自定义矢量画板', (tester) async {
      for (final category in IncidentCategory.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: IncidentCategoryBadge(
                key: Key('badge-${category.name}'),
                category: category,
              ),
            ),
          ),
        );
        expect(find.byKey(Key('badge-${category.name}')), findsOneWidget);
        expect(find.byType(CustomPaint), findsWidgets);
      }
    });
  });

  group('警情数据二次清洗与时间格式化', () {
    test('清洗冗余省市区前缀与相邻重复区县并在 title 等于地址时提炼事件名', () {
      final now = DateTime(2026, 11, 13, 14, 30);
      final todayCreatedAt = DateTime(2026, 11, 13, 9, 5).millisecondsSinceEpoch;
      final incident = Incident(
        id: 'clean-1',
        number: '2026-11-13-02',
        title: '示例省示例市示例县示例县示范路18号',
        info: const {
          'location': '示例省示例市示例县示例县示范路18号',
          'original_category': '二级火灾扑救',
          'specific_type': '居民住宅',
          'situation': '二级火灾扑救 · 示范小区居民楼冒烟，暂无人员被困 · 官方状态: 到场',
        },
        status: 'active',
        createdAt: todayCreatedAt,
        lastActivityAt: todayCreatedAt,
      );

      final data = IncidentCardData.fromIncident(incident, now: now);
      expect(data.category, IncidentCategory.fire);
      expect(data.locationText, '示例县示范路18号');
      expect(data.hasRealLocation, isTrue);
      expect(data.eventTitle, '示范小区居民楼冒烟');
      expect(data.timeText, '今日 09:05');
      expect(data.officialStatus, '到场');
      expect(data.isTerminalStatus, isFalse);
      expect(
        data.extraNotes.any((note) => note.contains('示范小区居民楼冒烟')),
        isFalse,
      );
    });

    test('时间格式化覆盖今日/昨日/当年/跨年及缺省兜底', () {
      final now = DateTime(2026, 11, 13, 14, 30);
      final yesterdayMs = DateTime(2026, 11, 12, 8, 9).millisecondsSinceEpoch;
      final earlierSameYearMs = DateTime(2026, 5, 4, 21, 7).millisecondsSinceEpoch;
      final lastYearMs = DateTime(2025, 12, 31, 23, 59).millisecondsSinceEpoch;

      expect(
        IncidentCardData.formatIncidentTime(
          Incident(
            id: 't1',
            number: 'n',
            status: 'active',
            createdAt: yesterdayMs,
            lastActivityAt: yesterdayMs,
          ),
          now: now,
        ),
        '昨日 08:09',
      );
      expect(
        IncidentCardData.formatIncidentTime(
          Incident(
            id: 't2',
            number: 'n',
            status: 'active',
            createdAt: earlierSameYearMs,
            lastActivityAt: earlierSameYearMs,
          ),
          now: now,
        ),
        '05-04 21:07',
      );
      expect(
        IncidentCardData.formatIncidentTime(
          Incident(
            id: 't3',
            number: 'n',
            status: 'active',
            createdAt: lastYearMs,
            lastActivityAt: lastYearMs,
          ),
          now: now,
        ),
        '2025-12-31 23:59',
      );
      expect(
        IncidentCardData.formatIncidentTime(
          const Incident(
            id: 't4',
            number: 'n',
            status: 'active',
            createdAt: 0,
            lastActivityAt: 0,
          ),
          now: now,
        ),
        '时间待补充',
      );
    });
  });

  group('终态冲突治理与首页卡片渲染', () {
    testWidgets('终态归队/已结案隐藏力量待登记，出动状态显示力量待登记', (tester) async {
      final terminalController = _TestController(
        incident: const Incident(
          id: 'inc-term',
          number: '2026-11-13-03',
          title: '示范商场火警',
          info: {
            'location': '示范路88号',
            'original_category': '一级火灾扑救',
            'incident_status': '归队',
          },
          status: 'active',
          createdAt: 1,
          lastActivityAt: 1,
        ),
      );
      await _pumpHome(tester, terminalController);

      expect(find.text('示范商场火警'), findsOneWidget);
      expect(find.byKey(const Key('incident-collapse-pill')), findsOneWidget);
      expect(find.text('力量待登记'), findsNothing);

      await tester.tap(find.byKey(const Key('toggle-incident-card')));
      await tester.pumpAndSettle();
      expect(find.text('官方状态: 归队'), findsOneWidget);
      expect(find.text('力量待登记'), findsNothing);

      final activeController = _TestController(
        incident: const Incident(
          id: 'inc-active',
          number: '2026-11-13-04',
          title: '示范仓库火警',
          info: {
            'location': '示范路99号',
            'original_category': '一级火灾扑救',
            'incident_status': '出动',
          },
          status: 'active',
          createdAt: 1,
          lastActivityAt: 1,
        ),
      );
      await _pumpHome(tester, activeController);
      await tester.tap(find.byKey(const Key('toggle-incident-card')));
      await tester.pumpAndSettle();
      expect(find.text('官方状态: 出动'), findsOneWidget);
      expect(find.text('力量待登记'), findsOneWidget);
    });

    testWidgets('已登记参战力量时始终展示队伍数量胶囊', (tester) async {
      final controller = _TestController(
        incident: const Incident(
          id: 'inc-force',
          number: '2026-11-13-05',
          title: '示范厂房抢险',
          info: {
            'location': '示例工业园3号',
            'original_category': '二级抢险救援',
            'incident_status': '归队',
          },
          status: 'active',
          createdAt: 1,
          lastActivityAt: 1,
        ),
        forces: const [
          IncidentForce(
            id: 'f1',
            incidentId: 'inc-force',
            stationName: '示例路站',
            personnelCount: 6,
            vehicleCount: 2,
            createdAt: 1,
            updatedAt: 1,
            version: 1,
          ),
        ],
      );
      await _pumpHome(tester, controller);
      await tester.tap(find.byKey(const Key('toggle-incident-card')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('incident-category-badge-rescue')),
        findsOneWidget,
      );
      expect(find.text('1支队伍'), findsNWidgets(2));
      expect(find.text('力量待登记'), findsNothing);
    });
  });

  group('警情调整三类芯片联动与防孤字排版', () {
    testWidgets('警情调整弹窗切换灭火/抢险/救助芯片联动刷新级别选项并保存', (tester) async {
      final api = _TestAdjustApi(
        initialData: {'original_category': '一级火灾扑救'},
      );
      final controller = _TestController(
        incident: const Incident(
          id: 'i-adjust',
          number: '2026-11-13-09',
          status: 'active',
          createdAt: 1,
          lastActivityAt: 1,
          info: {'original_category': '一级火灾扑救'},
        ),
      )..api = api;

      await _pumpHome(tester, controller);
      await tester.tap(find.byKey(const Key('toggle-incident-card')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('警情调整'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-category-chip-aid')));
      await tester.pumpAndSettle();
      expect(find.text('二级社会救助'), findsOneWidget);

      await tester.tap(find.text('二级社会救助'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('incident-level-save')));
      await tester.pumpAndSettle();

      expect(api.updatedData?['original_category'], '二级社会救助');
      expect(api.updatedData?['level'], '二级社会救助');
      expect(
        find.byKey(const Key('incident-category-badge-aid')),
        findsOneWidget,
      );
    });

    testWidgets('AntiOrphanText 在 320dp 窄屏不遗留单字尾行且不篡改文本', (tester) async {
      const sample = '示例县示例镇示例示范新村三组十二号';
      final style = AppTextStyles.caption.copyWith(fontSize: 13);

      // 动态寻找会让原始排版产生单字尾行的临界宽度
      double? orphanWidth;
      for (var w = 260.0; w >= 120.0; w -= 1.0) {
        final painter = TextPainter(
          text: TextSpan(text: sample, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 2,
        )..layout(maxWidth: w);
        final metrics = painter.computeLineMetrics();
        if (metrics.length == 2) {
          final pos = painter.getPositionForOffset(
            Offset(0, metrics.last.baseline),
          );
          final range = painter.getLineBoundary(pos);
          final lastLine = sample
              .substring(
                range.start.clamp(0, sample.length),
                range.end.clamp(0, sample.length),
              )
              .trim();
          if (lastLine.runes.length == 1) {
            orphanWidth = w;
            break;
          }
        }
      }
      expect(orphanWidth, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: orphanWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AntiOrphanText(
                    text: sample,
                    style: style,
                    maxLines: 2,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final textFinder = find.text(sample);
      final textWidget = tester.widget<Text>(textFinder);
      expect(textWidget.data, sample);
      expect(tester.getSize(textFinder).width, lessThan(orphanWidth!));
      expect(tester.takeException(), isNull);
    });

    testWidgets('daylight 与 warmSand 双主题切换时三类语义色动态响应', (tester) async {
      Future<Color> pumpAndReadFireColor() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Builder(
              builder: (_) => Container(
                key: const Key('color-probe'),
                color: IncidentCategory.fire.iconColor,
              ),
            ),
          ),
        );
        final container = tester.widget<Container>(
          find.byKey(const Key('color-probe')),
        );
        return container.color!;
      }

      expect(
        await pumpAndReadFireColor(),
        AppPalette.daylight.incidentFire,
      );

      ThemeController.instance.select(AppPalette.warmSand);
      expect(
        await pumpAndReadFireColor(),
        AppPalette.warmSand.incidentFire,
      );
    });
  });

  group('首页与警情获取页全量字段对齐及力量同步展示', () {
    test('ExternalIncident 全字段 fromJson / toJson 无损往返与 getters', () {
      const source = ExternalIncident(
        externalId: 'ext-rt-1',
        incidentNumber: '20261114099',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '火灾扑救',
        disposalObjectName: '民房',
        incidentLevel: '二级',
        incidentStatus: '出动',
        crimeAddress: '示例省示例市示例县和平街9号',
        incidentDescribe: '民房厨房油锅起火',
        registerTime: 1786177140000,
        latitude: '29.01',
        longitude: '119.12',
        alarmPhone: '0110',
        alarmPersonPhone: '13800001111',
        alarmPersonName: '李四',
        alarmModeName: '电话报警',
        incidentNatureName: '真警',
        dispatchVehicle: '3',
        dispatchOrganization: '1',
        eventSummary: '和平街民房厨房油锅起火',
        disasterCategory: 'fire',
        specificType: '民房火灾',
        locationDisplay: '示例县和平街9号',
        officialStatus: '出动',
        situationDetail: '民房厨房油锅起火，暂无人员被困',
        trapped: '',
        injured: '',
        hazardousMaterials: '液化气',
        dispatchSummary: '3车 1站 (主调: 示例路站)',
        dispatchedForces: [
          ExternalDispatchedForce(
            stationName: '示例路站',
            vehicleCount: 3,
            personnelCount: null,
          ),
        ],
        factHighlights: ['涉液化气', '二级'],
        aiStatus: 'ready',
        rawMergedText: '警情编号: 20261114099',
      );

      final roundTrip = ExternalIncident.fromJson(source.toJson());
      expect(roundTrip.eventSummary, '和平街民房厨房油锅起火');
      expect(roundTrip.disasterCategory, 'fire');
      expect(roundTrip.dispatchVehicle, '3');
      expect(roundTrip.dispatchOrganization, '1');
      expect(roundTrip.alarmPersonPhone, '13800001111');
      expect(roundTrip.alarmPersonName, '李四');
      expect(roundTrip.dispatchedForces.length, 1);
      expect(roundTrip.dispatchedForces.first.vehicleCount, 3);
      expect(roundTrip.dispatchedForces.first.personnelCount, isNull);
      expect(roundTrip.compactForceTags, ['示例路站 3车']);
      expect(roundTrip.effectiveEventTitle, '和平街民房厨房油锅起火');
      expect(roundTrip.effectiveLocation, '示例县和平街9号');
    });

    testWidgets('首页折叠态在有出动力量时紧凑展示并在无力量时不占位', (tester) async {
      final emptyController = _TestController(
        incident: const Incident(
          id: 'inc-no-force',
          number: '2026-11-14-01',
          title: '沿街商铺烟道冒烟',
          info: {
            'location': '示例县示范路10号',
            'original_category': '火灾扑救',
          },
          status: 'active',
          createdAt: 1786177140000,
          lastActivityAt: 1786177140000,
        ),
      );
      await _pumpHome(tester, emptyController);
      expect(find.byKey(const Key('incident-collapsed-forces')), findsNothing);
      final collapsedHeight = tester
          .getSize(find.byKey(const Key('incident-card')))
          .height;
      expect(collapsedHeight, lessThan(120));

      final withForceController = _TestController(
        incident: const Incident(
          id: 'inc-with-force',
          number: '2026-11-14-02',
          title: '居民楼厨房起火',
          info: {
            'location': '示例县示范路20号',
            'original_category': '火灾扑救',
          },
          status: 'active',
          createdAt: 1786177140000,
          lastActivityAt: 1786177140000,
        ),
        forces: const [
          IncidentForce(
            id: 'f-sync-1',
            incidentId: 'inc-with-force',
            stationName: '示例路站',
            vehicleCount: 3,
            personnelCount: 0,
            vehicleCountKnown: true,
            personnelCountKnown: false,
            createdAt: 1,
            updatedAt: 1,
            version: 1,
          ),
        ],
      );
      await _pumpHome(tester, withForceController);
      expect(
        find.byKey(const Key('incident-collapsed-forces')),
        findsOneWidget,
      );
      expect(find.text('示例路站 3车'), findsOneWidget);

      await tester.tap(find.byKey(const Key('toggle-incident-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident-collapsed-forces')), findsNothing);
      expect(find.text('参战力量'), findsOneWidget);
      expect(find.textContaining('示例路站'), findsOneWidget);
    });
  });
}
