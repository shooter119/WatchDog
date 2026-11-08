import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/tactical_brief_engine.dart';

void main() {
  group('TacticalBriefEngine Tests', () {
    test('extractAirSafetySummary returns idle when entries list is empty', () {
      final summary = TacticalBriefEngine.extractAirSafetySummary([]);
      expect(summary.activeCount, 0);
      expect(summary.hasActive, isFalse);
      expect(summary.level, AirSafetyLevel.idle);
      expect(summary.shortestName, isNull);
      expect(summary.shortestRemainingMin, isNull);
    });

    test('extractAirSafetySummary filters out exited entries', () {
      final now = 100000000;
      final entries = <Entry>[
        Entry(
          id: '1',
          name: '张三',
          durationMin: 20,
          entryAt: now - 600000,
          exitAt: now + 600000, // 剩 10 分钟
          source: 'voice',
        ),
        Entry(
          id: '2',
          name: '李四',
          durationMin: 20,
          entryAt: now - 1200000,
          exitAt: now,
          exitedAt: now, // 已退场，虽为0但应被过滤
          source: 'voice',
        ),
      ];

      final summary = TacticalBriefEngine.extractAirSafetySummary(entries, nowMillis: now);
      expect(summary.activeCount, 1);
      expect(summary.shortestName, '张三');
      expect(summary.shortestRemainingMin, 10);
      expect(summary.level, AirSafetyLevel.warning);
    });

    test('extractAirSafetySummary detects critical level when remaining <= 5 min', () {
      final now = 100000000;
      final entries = <Entry>[
        Entry(
          id: '1',
          name: '王五',
          durationMin: 20,
          entryAt: now - 1000000,
          exitAt: now + 240000, // 剩 4 分钟
          source: 'voice',
        ),
        Entry(
          id: '2',
          name: '赵六',
          durationMin: 25,
          entryAt: now - 500000,
          exitAt: now + 900000, // 剩 15 分钟
          source: 'voice',
        ),
      ];

      final summary = TacticalBriefEngine.extractAirSafetySummary(entries, nowMillis: now);
      expect(summary.activeCount, 2);
      expect(summary.shortestName, '王五');
      expect(summary.shortestRemainingMin, 4);
      expect(summary.level, AirSafetyLevel.critical);
    });

    test('extractLocation prioritizes location over address and fallback', () {
      const incWithLoc = Incident(
        id: '1',
        number: '1',
        title: '警情A',
        status: 'active',
        createdAt: 1000,
        lastActivityAt: 1000,
        info: {'location': '龙游县湖镇镇竺溪桥', 'address': '备用地址'},
      );
      expect(TacticalBriefEngine.extractLocation(incWithLoc), '龙游县湖镇镇竺溪桥');

      const incWithAddr = Incident(
        id: '2',
        number: '2',
        title: '警情B',
        status: 'active',
        createdAt: 1000,
        lastActivityAt: 1000,
        info: {'address': '示例路88号'},
      );
      expect(TacticalBriefEngine.extractLocation(incWithAddr), '示例路88号');

      const incEmpty = Incident(
        id: '3',
        number: '3',
        title: '示例重点单位',
        status: 'active',
        createdAt: 1000,
        lastActivityAt: 1000,
        info: {},
      );
      expect(TacticalBriefEngine.extractLocation(incEmpty), '示例重点单位');
    });

    test('extractIntelligence buckets five tactical dimensions and filters telemetry', () {
      final notes = <Note>[
        const Note(
          id: '1',
          text: '张三进入救援现场，空气呼吸器压力24兆帕',
          category: '部署',
          createdAt: 1000,
          updatedAt: 1000,
        ),
        const Note(
          id: '2',
          text: '东侧砖混建筑有倒塌风险，设立观察哨',
          category: '险情',
          createdAt: 2000,
          updatedAt: 2000,
        ),
        const Note(
          id: '3',
          text: '搜救组成功搜救出1名被困人员并移交120',
          category: '搜救',
          createdAt: 3000,
          updatedAt: 3000,
        ),
        const Note(
          id: '4',
          text: '现场两支水枪出水控火',
          category: '出水',
          createdAt: 4000,
          updatedAt: 4000,
        ),
        const Note(
          id: '5',
          text: '破拆组利用液压顶撑破拆车门',
          category: '破拆',
          createdAt: 5000,
          updatedAt: 5000,
        ),
        const Note(
          id: '6',
          text: '群众大量围观，协调交警划定警戒区',
          category: '供水',
          createdAt: 6000,
          updatedAt: 6000,
        ),
        const Note(
          id: '7',
          text: '张三已退场',
          category: '撤离',
          createdAt: 7000,
          updatedAt: 7000,
        ),
      ];

      final intel = TacticalBriefEngine.extractIntelligence(notes);
      expect(intel.hazards, contains('东侧砖混建筑有倒塌风险，设立观察哨'));
      expect(intel.lifeSafety, contains('搜救组成功搜救出1名被困人员并移交120'));
      expect(intel.suppression, contains('现场两支水枪出水控火'));
      expect(intel.technicalRescue, contains('破拆组利用液压顶撑破拆车门'));
      expect(intel.perimeterAndSupport, contains('群众大量围观，协调交警划定警戒区'));
      expect(intel.hasCriticalHazards, isTrue);
      expect(intel.hasRescueProgress, isTrue);
    });

    test('formatObjectiveBrief adaptively hides breathing section for rescue incidents without SCBA entry', () {
      final now = DateTime(2026, 11, 8, 13, 20);
      const rescueIncident = Incident(
        id: 'r1',
        number: '20261108002',
        title: '湖镇镇竺溪桥抢险救援',
        status: 'active',
        createdAt: 1000,
        lastActivityAt: 2000,
        info: {
          'location': '龙游县湖镇镇竺溪桥',
          'specific_type': '抢险救援',
          'situation': '抢险救援',
        },
      );

      final forces = <IncidentForce>[
        const IncidentForce(
          id: 'f1',
          incidentId: 'r1',
          stationName: '龙翔路站',
          vehicleCount: 2,
          personnelCount: 12,
          version: 1,
          createdAt: 1000,
          updatedAt: 1000,
        ),
      ];

      final notes = <Note>[
        const Note(
          id: '1',
          text: '东侧建筑有倒塌风险',
          category: '险情',
          createdAt: 1000,
          updatedAt: 1000,
        ),
        const Note(
          id: '2',
          text: '已成功搜救出1名被困人员',
          category: '搜救',
          createdAt: 2000,
          updatedAt: 2000,
        ),
      ];

      final brief = TacticalBriefEngine.formatObjectiveBrief(
        incident: rescueIncident,
        forces: forces,
        entries: const [], // 无空呼内攻进场
        notes: notes,
        generatedAt: now,
      );

      expect(brief, contains('【抢险救援现场速报】湖镇镇竺溪桥抢险救援（13:20）'));
      expect(brief, contains('事发地点：龙游县湖镇镇竺溪桥'));
      expect(brief, contains('【核心要事】已成功搜救出1名被困人员；【警示】东侧建筑有倒塌风险'));
      expect(brief, contains('一、到场力量与救援展开'));
      expect(brief, contains('二、现场险情与风险控制'));
      expect(brief, contains('东侧建筑有倒塌风险'));
      expect(brief, contains('三、人员搜救与送医转移'));
      expect(brief, contains('已成功搜救出1名被困人员'));
      // 核心断言：抢险救援无内攻时，绝对不能出现内攻与空呼安全段落！
      expect(brief, isNot(contains('内攻作业与空呼安全')));
      expect(brief, isNot(contains('气瓶可用时间')));
    });

    test('formatObjectiveBrief retains breathing section for fire incidents with active entry', () {
      final now = DateTime(2026, 11, 8, 11, 30);
      const fireIncident = Incident(
        id: 'f1',
        number: '20261108001',
        title: '示例商业广场火灾',
        status: 'active',
        createdAt: 1000,
        lastActivityAt: 2000,
        info: {
          'location': '示例路88号',
          'specific_type': '火灾扑救',
        },
      );

      final forces = <IncidentForce>[
        const IncidentForce(
          id: 'f1',
          incidentId: 'f1',
          stationName: '示例路站',
          vehicleCount: 2,
          personnelCount: 10,
          version: 1,
          createdAt: 1000,
          updatedAt: 1000,
        ),
      ];

      final entries = <Entry>[
        Entry(
          id: '1',
          name: '张三',
          durationMin: 20,
          entryAt: now.millisecondsSinceEpoch - 300000,
          exitAt: now.millisecondsSinceEpoch + 840000, // 剩 14 分钟
          source: 'voice',
        ),
      ];

      final notes = <Note>[
        const Note(
          id: '1',
          text: '东门出水枪2支内攻推进',
          category: '出水',
          createdAt: 1000,
          updatedAt: 1000,
        ),
      ];

      final brief = TacticalBriefEngine.formatObjectiveBrief(
        incident: fireIncident,
        forces: forces,
        entries: entries,
        notes: notes,
        generatedAt: now,
      );

      expect(brief, contains('【火灾扑救战况速报】示例商业广场火灾（11:30）'));
      expect(brief, contains('事发地点：示例路88号'));
      expect(brief, contains('一、到场力量与战术部署'));
      expect(brief, contains('战术部署：东门出水枪2支内攻推进'));
      expect(brief, contains('四、内攻作业与空呼安全'));
      expect(brief, contains('共1人在场（涉及：张三）'));
      expect(brief, contains('最低气瓶可用时间为14分钟（张三）'));
    });

    test('sanitizeBriefText masks sensitive verification codes', () {
      final raw = '内部验证码: 123456 请牢记';
      final cleaned = TacticalBriefEngine.sanitizeBriefText(raw);
      expect(cleaned, contains('验证码: ****'));
      expect(cleaned, isNot(contains('123456')));
    });
  });
}
