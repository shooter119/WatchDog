import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/local_parser.dart';

void main() {
  final p = LocalParser();

  group('LocalParser 进场解析', () {
    test('单人：姓名 + 兆帕压力', () {
      final r = p.parse('张伟，20兆帕', firefighters: ['张伟']);
      expect(r.action, 'enter');
      expect(r.people, hasLength(1));
      expect(r.people[0].name, '张伟');
      expect(r.people[0].pressureMpa, 20);
    });

    test('单人：中文数字压力（十五个压）', () {
      final r = p.parse('王强气瓶还有十五个压', firefighters: ['王强']);
      expect(r.action, 'enter');
      expect(r.people[0].name, '王强');
      expect(r.people[0].pressureMpa, 15);
    });

    test('单人：中文数字压力（二十兆帕）', () {
      final r = p.parse('张伟二十兆帕', firefighters: ['张伟']);
      expect(r.people[0].pressureMpa, 20);
    });

    test('多人：按顺序提取全部人员', () {
      final r = p.parse('张伟20兆帕，李娜22兆帕，王强十五个压', firefighters: ['张伟', '李娜', '王强']);
      expect(r.action, 'enter');
      expect(r.people, hasLength(3));
      expect(r.people.map((e) => e.name), ['张伟', '李娜', '王强']);
      expect(r.people.map((e) => e.pressureMpa), [20.0, 22.0, 15.0]);
    });

    test('名单外姓名：从压力前片段提取', () {
      final r = p.parse('李娜，22兆帕', firefighters: ['张伟']);
      expect(r.people, hasLength(1));
      expect(r.people[0].name, '李娜');
      expect(r.people[0].pressureMpa, 22);
    });

    test('长名优先：短名不嵌入长名', () {
      final r = p.parse('张伟强20兆帕', firefighters: ['张伟', '张伟强']);
      expect(r.people, hasLength(1));
      expect(r.people[0].name, '张伟强');
    });

    test('未识别到信息返回 unknown 与说明', () {
      final r = p.parse('今天天气不错');
      expect(r.action, 'unknown');
      expect(r.people, isEmpty);
      expect(r.note, '未识别到人员与压力信息');
    });

    test('压力数值异常范围被忽略', () {
      final r = p.parse('张伟200兆帕', firefighters: ['张伟']);
      expect(r.action, 'unknown');
      expect(r.people, isEmpty);
    });

    test('出警途中路况通报：完整陈述句保留为 note（宁记不错过）', () {
      final r = p.parse('路上遇到小学放学，车队堵车。', firefighters: []);
      expect(r.intent, 'note');
    });

    test('火场指挥语境：无名单姓名也保留为 note', () {
      final r = p.parse('带队指挥员陆和胜', firefighters: ['陆河圣']);
      expect(r.intent, 'note');
    });

    test('纯噪音（测试/语气词）判 ignore', () {
      expect(p.parse('咳咳，测试测试').intent, 'ignore');
      expect(p.parse('嗯').intent, 'ignore');
      expect(p.parse('喂喂').intent, 'ignore');
      expect(p.parse('哦哦哦').intent, 'ignore');
    });

    test('通信确认短句保留为 note（收到/明白）', () {
      expect(p.parse('收到').intent, 'note');
      expect(p.parse('明白').intent, 'note');
    });
  });

  group('LocalParser 出场解析', () {
    test('名单内两人出场', () {
      final r = p.parse('张伟和李娜出来了', firefighters: ['张伟', '李娜']);
      expect(r.action, 'exit');
      expect(r.people.map((e) => e.name), ['张伟', '李娜']);
      expect(r.people.every((e) => e.pressureMpa == null), isTrue);
    });

    test('单人出场', () {
      final r = p.parse('王强退场', firefighters: ['王强']);
      expect(r.action, 'exit');
      expect(r.people.single.name, '王强');
    });

    test('全员离场：people 为空，由客户端弹确认框', () {
      final r = p.parse('全部人员离开火场', firefighters: ['张伟']);
      expect(r.action, 'exit');
      expect(r.people, isEmpty);
    });

    test('名单外姓名出场：从分隔符片段提取', () {
      final r = p.parse('李娜和赵磊出来了', firefighters: ['张伟']);
      expect(r.action, 'exit');
      expect(r.people.map((e) => e.name), containsAll(['李娜', '赵磊']));
    });

    test('出场文本不带人名时为空名单', () {
      final r = p.parse('撤收，收工', firefighters: ['张伟']);
      expect(r.action, 'exit');
      expect(r.people, isEmpty);
    });
  });

  group('LocalParser 长距离报数（进入火场句式）', () {
    test('名单姓名与压力间隔较长仍判进场（李翔进入火场，空气呼吸器压力20兆帕）', () {
      final p = LocalParser().parse(
        '李翔进入火场，空气呼吸器压力20兆帕',
        firefighters: ['李翔'],
      );
      expect(p.action, 'enter');
      expect(p.intent, VoiceIntent.entry);
      expect(p.people, hasLength(1));
      expect(p.people.first.name, '李翔');
      expect(p.people.first.pressureMpa, 20);
    });
  });
}
