/// 火场随手记分类（与后端白名单一致）
/// 依据消防实战作战环节设计：接警出动→火情侦察→警戒→战斗展开→
/// 救人搜救/疏散→灭火(控制/堵截/强攻/总攻/合围)→破拆→排烟→供水→消除残火→战斗结束
class NoteCategory {
  static const String deploy = '部署';
  static const String rescue = '搜救';
  static const String water = '出水';
  static const String withdraw = '撤离';
  static const String abnormal = '异常';
  static const String other = '其他';

  static const List<String> all = [
    deploy,
    rescue,
    water,
    withdraw,
    abnormal,
    other,
  ];

  /// 颜色映射由主题层负责（app_theme.dart），此处仅定义分类
  /// 关键词按"异常>撤离>出水>搜救>部署"优先级匹配，先命中先归类
  static String fromText(String text) {
    final t = text.trim();
    // 异常（险情与危险事件，优先）
    if (t.contains('爆炸') ||
        t.contains('爆燃') ||
        t.contains('闪燃') ||
        t.contains('轰燃') ||
        t.contains('回燃') ||
        t.contains('复燃') ||
        t.contains('阴燃') ||
        t.contains('倒塌') ||
        t.contains('坍塌') ||
        t.contains('泄漏') ||
        t.contains('中毒') ||
        t.contains('窒息') ||
        t.contains('触电') ||
        t.contains('受伤') ||
        t.contains('伤亡') ||
        t.contains('坠落') ||
        t.contains('失控') ||
        t.contains('蔓延') ||
        t.contains('飞火') ||
        t.contains('流淌火') ||
        t.contains('险情') ||
        t.contains('异常') ||
        t.contains('爆裂') ||
        t.contains('带电') ||
        t.contains('坍塌危险')) {
      return abnormal;
    }
    // 撤离（战斗结束与收尾）
    if (t.contains('撤离') ||
        t.contains('撤出') ||
        t.contains('撤退') ||
        t.contains('收队') ||
        t.contains('归队') ||
        t.contains('收工') ||
        t.contains('回撤') ||
        t.contains('收操') ||
        t.contains('撤收') ||
        t.contains('清理') ||
        t.contains('残火') ||
        t.contains('监护') ||
        t.contains('留守') ||
        t.contains('移交') ||
        t.contains('交接') ||
        t.contains('结束') ||
        t.contains('收尾') ||
        t.contains('战评') ||
        t.contains('总结')) {
      return withdraw;
    }
    // 出水（射水灭火与控制火势）
    if (t.contains('出水') ||
        t.contains('供水') ||
        t.contains('送水') ||
        t.contains('中继') ||
        t.contains('水带') ||
        t.contains('水枪') ||
        t.contains('水炮') ||
        t.contains('泡沫') ||
        t.contains('干粉') ||
        t.contains('灭火') ||
        t.contains('扑灭') ||
        t.contains('扑救') ||
        t.contains('冷却') ||
        t.contains('降温') ||
        t.contains('堵截') ||
        t.contains('夹攻') ||
        t.contains('强攻') ||
        t.contains('总攻') ||
        t.contains('合围') ||
        t.contains('突破') ||
        t.contains('掩护') ||
        t.contains('控制火势') ||
        t.contains('压制') ||
        t.contains('水幕') ||
        t.contains('火势控制')) {
      return water;
    }
    // 搜救（救人、侦察、破拆排烟等救援作业）
    if (t.contains('搜救') ||
        t.contains('搜寻') ||
        t.contains('搜索') ||
        t.contains('侦查') ||
        t.contains('侦察') ||
        t.contains('侦检') ||
        t.contains('探测') ||
        t.contains('被困') ||
        t.contains('遇险') ||
        t.contains('失联') ||
        t.contains('救人') ||
        t.contains('疏散') ||
        t.contains('转移') ||
        t.contains('救出') ||
        t.contains('抬出') ||
        t.contains('登高') ||
        t.contains('破拆') ||
        t.contains('排烟') ||
        t.contains('通风') ||
        t.contains('内攻') ||
        t.contains('开辟通道') ||
        t.contains('查找火源')) {
      return rescue;
    }
    // 部署（接警出动、力量调度与战斗展开）
    if (t.contains('出动') ||
        t.contains('接警') ||
        t.contains('调派') ||
        t.contains('调度') ||
        t.contains('增援') ||
        t.contains('到场') ||
        t.contains('到达') ||
        t.contains('进入') ||
        t.contains('集结') ||
        t.contains('部署') ||
        t.contains('展开') ||
        t.contains('阵地') ||
        t.contains('警戒') ||
        t.contains('封锁') ||
        t.contains('隔离') ||
        t.contains('指挥部') ||
        t.contains('集结点') ||
        t.contains('战备') ||
        t.contains('待命') ||
        t.contains('保障') ||
        t.contains('协同') ||
        t.contains('力量') ||
        t.contains('指挥')) {
      return deploy;
    }
    return other;
  }
}
