import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';

void main() {
  group('NoteCategory.fromText 按实战环节自动分类', () {
    test('部署：接警出动与到场展开', () {
      expect(NoteCategory.fromText('龙翔路站出动一车7人前往处置'), NoteCategory.deploy);
      expect(NoteCategory.fromText('支队全勤指挥部到达现场'), NoteCategory.deploy);
      expect(NoteCategory.fromText('龙翔路站到达现场'), NoteCategory.deploy);
      expect(NoteCategory.fromText('攻坚组进入火场内部'), NoteCategory.deploy);
      expect(NoteCategory.fromText('力量调度完成，主战车到场'), NoteCategory.deploy);
    });

    test('搜救：救人侦察与破拆排烟', () {
      expect(NoteCategory.fromText('二楼发现被困人员'), NoteCategory.rescue);
      expect(NoteCategory.fromText('搜救出一只宠物狗'), NoteCategory.rescue);
      expect(NoteCategory.fromText('破拆卷帘门开辟救援通道'), NoteCategory.rescue);
      expect(NoteCategory.fromText('利用排烟机正压送风排烟'), NoteCategory.rescue);
      expect(NoteCategory.fromText('侦查发现火源位于厨房'), NoteCategory.rescue);
    });

    test('出水：射水灭火与控制火势', () {
      expect(NoteCategory.fromText('铺设一条干线，出两支水枪，对火势进行打击'), NoteCategory.water);
      expect(NoteCategory.fromText('北侧出水正常，压力充足'), NoteCategory.water);
      expect(NoteCategory.fromText('泡沫覆盖地面冷却降温'), NoteCategory.water);
      expect(NoteCategory.fromText('总攻开始，堵截夹攻'), NoteCategory.water);
    });

    test('撤离：战斗结束与收队', () {
      expect(NoteCategory.fromText('火已扑灭，清理残火后收队'), NoteCategory.withdraw);
      expect(NoteCategory.fromText('全体人员撤离火场'), NoteCategory.withdraw);
      expect(NoteCategory.fromText('战斗结束，监护现场后交接'), NoteCategory.withdraw);
    });

    test('异常：险情与危险事件优先', () {
      expect(NoteCategory.fromText('二楼发生爆炸'), NoteCategory.abnormal);
      expect(NoteCategory.fromText('墙体有倒塌风险'), NoteCategory.abnormal);
      expect(NoteCategory.fromText('火势蔓延失控'), NoteCategory.abnormal);
      expect(NoteCategory.fromText('一名队员轻微受伤'), NoteCategory.abnormal);
    });

    test('其他：兜底', () {
      expect(NoteCategory.fromText('天气炎热，注意补水'), NoteCategory.other);
    });
  });
}
