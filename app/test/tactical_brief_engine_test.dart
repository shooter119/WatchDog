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

    test('extractTacticalProgress filters entry/exit notes and finds latest progress', () {
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
          text: '东门出水2支水枪实施内攻推进',
          category: '出水',
          createdAt: 2000,
          updatedAt: 2000,
        ),
        const Note(
          id: '3',
          text: '张三已退场',
          category: '撤离',
          createdAt: 3000,
          updatedAt: 3000,
        ),
      ];

      final progress = TacticalBriefEngine.extractTacticalProgress(notes);
      expect(progress, '东门出水2支水枪实施内攻推进');
    });

    test('formatObjectiveBrief builds clean text without markdown symbols', () {
      final now = DateTime(2026, 11, 8, 11, 30);
      const incident = Incident(
        id: 'inc1',
        number: '20261108001',
        title: '示例商业广场火灾',
        status: 'active',
        createdAt: 1000,
        lastActivityAt: 2000,
        info: {'address': '示例路88号'},
      );

      final forces = <IncidentForce>[
        const IncidentForce(
          id: 'f1',
          incidentId: 'inc1',
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
        incident: incident,
        forces: forces,
        entries: entries,
        notes: notes,
        generatedAt: now,
      );

      expect(brief, contains('【火场态势速报】示例商业广场火灾（11:30）'));
      expect(brief, contains('事发对象：示例路88号'));
      expect(brief, contains('共出动2辆消防车、10名指战员（示例路站 2车10人）'));
      expect(brief, contains('现场部署：东门出水枪2支内攻推进'));
      expect(brief, contains('共1人在场（涉及：张三）'));
      expect(brief, contains('最低气瓶可用时间为14分钟（张三）'));
      expect(brief, isNot(contains('#')));
      expect(brief, isNot(contains('*')));
      expect(brief, isNot(contains('请指示')));
    });

    test('sanitizeBriefText masks sensitive verification codes', () {
      final raw = '内部验证码: 123456 请牢记';
      final cleaned = TacticalBriefEngine.sanitizeBriefText(raw);
      expect(cleaned, contains('验证码: ****'));
      expect(cleaned, isNot(contains('123456')));
    });
  });
}
