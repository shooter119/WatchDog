import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/ui/widgets/incident_category_style.dart';
import 'package:watchdog/models/models.dart';

void main() {
  group('警情三类分类与图标', () {
    test('classify 按主类别与关键词归入灭火/抢险/救助且空白默认灭火', () {
      expect(IncidentCategoryStyle.classify(), DsIncidentCategory.fire);
      expect(
        IncidentCategoryStyle.classify(category: '一级火灾扑救'),
        DsIncidentCategory.fire,
      );
      expect(
        IncidentCategoryStyle.classify(category: '二级抢险救援'),
        DsIncidentCategory.rescue,
      );
      expect(
        IncidentCategoryStyle.classify(category: '社会救助'),
        DsIncidentCategory.aid,
      );
      expect(
        IncidentCategoryStyle.classify(situation: '电梯困人请求开锁协助'),
        DsIncidentCategory.aid,
      );
      expect(
        IncidentCategoryStyle.classify(situation: '高速路段货车侧翻漏油'),
        DsIncidentCategory.rescue,
      );
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

      final data = IncidentCardViewModel.fromIncident(incident, now: now);
      expect(data.category, DsIncidentCategory.fire);
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
        IncidentCardViewModel.formatIncidentTime(
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
        IncidentCardViewModel.formatIncidentTime(
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
        IncidentCardViewModel.formatIncidentTime(
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
        IncidentCardViewModel.formatIncidentTime(
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

    test('4级地址兜底链有效解析 location -> address -> location_display -> crime_address', () {
      final now = DateTime(2026, 11, 13, 10, 0);

      final inc1 = Incident(
        id: 'inc-1',
        number: '1',
        status: 'active',
        createdAt: 0,
        lastActivityAt: 0,
        info: const {'location': '示范路1号'},
      );
      expect(inc1.effectiveLocation, '示范路1号');
      expect(IncidentCardViewModel.fromIncident(inc1, now: now).locationText, '示范路1号');

      final inc2 = Incident(
        id: 'inc-2',
        number: '2',
        status: 'active',
        createdAt: 0,
        lastActivityAt: 0,
        info: const {'address': '示范路2号'},
      );
      expect(inc2.effectiveLocation, '示范路2号');
      expect(IncidentCardViewModel.fromIncident(inc2, now: now).locationText, '示范路2号');

      final inc3 = Incident(
        id: 'inc-3',
        number: '3',
        status: 'active',
        createdAt: 0,
        lastActivityAt: 0,
        info: const {'location_display': '示范路3号'},
      );
      expect(inc3.effectiveLocation, '示范路3号');
      expect(IncidentCardViewModel.fromIncident(inc3, now: now).locationText, '示范路3号');

      final inc4 = Incident(
        id: 'inc-4',
        number: '4',
        status: 'active',
        createdAt: 0,
        lastActivityAt: 0,
        info: const {'crime_address': '示范路4号'},
      );
      expect(inc4.effectiveLocation, '示范路4号');
      expect(IncidentCardViewModel.fromIncident(inc4, now: now).locationText, '示范路4号');

      final inc5 = Incident(
        id: 'inc-5',
        number: '5',
        status: 'active',
        createdAt: 0,
        lastActivityAt: 0,
        info: const {'location': '地点待补充', 'address': 'null'},
      );
      expect(inc5.effectiveLocation, '');
      expect(IncidentCardViewModel.fromIncident(inc5, now: now).locationText, '地点待补充');
    });
  });
}
