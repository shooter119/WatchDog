import '../models/models.dart';

/// 本地规则解析器：纯 Dart 实现，不依赖网络。
/// 行为对齐后端 src/parse.js 的语义规则：
/// - action 判断：进入/进场 → enter；出来/撤离/收工 → exit；否则 unknown
/// - 名单内姓名优先匹配；非名单姓名从压力前的片段提取
/// - 压力支持阿拉伯与中文数字，单位：兆帕/MPa/个压/压
/// - 多人按说话顺序提取，人数上限 10
class LocalParser {
  static const _exitWords = ['出来了', '已出', '退场', '撤离', '离场', '离开', '收工', '结束作业'];
  static const _enterWords = ['进入', '进场', '进去', '开始作业', '气瓶余量', '入火场'];
  static const _separators = '，,、。；;和及与';

  /// 常见同音字组（消防员姓名高频字 + 常见同音错字）：同组 = 读音相同，
  /// 用于名单姓名同音纠正（本地识别同音错字，如 路和胜 → 陆河圣）
  static const _homophoneGroup = <String, int>{
    '丁': 1, '万': 2, '东': 3, '严': 4, '中': 5, '丰': 6,
    '丽': 7, '云': 8, '亮': 9, '仕': 10, '以': 11, '伊': 11,
    '伟': 12, '何': 13, '余': 14, '俊': 15, '健': 16, '储': 17,
    '军': 15, '冬': 3, '凤': 6, '凯': 18, '刘': 19, '刚': 20,
    '剑': 16, '力': 7, '劳': 21, '华': 22, '博': 23, '占': 24,
    '卫': 12, '友': 25, '叶': 26, '合': 13, '吉': 27, '向': 28,
    '吕': 29, '君': 15, '启': 30, '吴': 31, '周': 32, '和': 13,
    '哲': 33, '嘉': 34, '国': 35, '圣': 36, '均': 15, '坤': 37,
    '垚': 38, '墙': 39, '夫': 40, '奇': 30, '姚': 38, '姜': 41,
    '威': 12, '婷': 42, '子': 43, '孙': 44, '宁': 45, '宇': 14,
    '安': 46, '宋': 47, '宏': 48, '官': 49, '家': 34, '小': 50,
    '岩': 4, '峰': 6, '嵩': 47, '巫': 31, '巴': 51, '布': 52,
    '帅': 53, '平': 54, '庆': 55, '康': 56, '廖': 57, '建': 16,
    '张': 58, '强': 39, '彪': 59, '彬': 60, '征': 61, '徐': 62,
    '微': 12, '志': 63, '怡': 11, '恺': 18, '成': 64, '戴': 65,
    '扬': 66, '承': 64, '拉': 67, '拥': 68, '振': 69, '播': 23,
    '敏': 70, '文': 71, '斌': 60, '新': 72, '方': 73, '施': 10,
    '旭': 62, '昆': 37, '昊': 74, '明': 75, '易': 11, '晓': 50,
    '晖': 76, '晶': 77, '智': 63, '曹': 78, '有': 25, '朋': 79,
    '朝': 80, '本': 81, '李': 7, '杨': 66, '杰': 82, '松': 47,
    '林': 83, '柯': 84, '桃': 85, '梅': 86, '梦': 87, '楼': 88,
    '欣': 72, '毕': 89, '毛': 90, '江': 41, '沈': 91, '河': 13,
    '波': 23, '泽': 92, '洋': 66, '洪': 48, '浩': 74, '海': 93,
    '涛': 85, '淑': 94, '清': 55, '游': 25, '灵': 95, '灿': 96,
    '炎': 4, '烜': 97, '烨': 26, '焕': 98, '熙': 99, '燕': 4,
    '珂': 84, '琦': 30, '琪': 30, '琳': 83, '瑞': 100, '甲': 34,
    '盛': 36, '相': 28, '磊': 101, '祝': 102, '禾': 13, '程': 64,
    '立': 7, '章': 58, '红': 48, '纹': 71, '罗': 103, '罡': 20,
    '羽': 14, '翔': 28, '翰': 104, '耀': 38, '肖': 50, '胜': 36,
    '胡': 105, '臣': 106, '自': 43, '良': 9, '莉': 7, '莘': 91,
    '菲': 107, '董': 3, '蓝': 108, '蕾': 101, '袁': 109, '豪': 74,
    '贤': 110, '贺': 13, '赵': 111, '超': 80, '路': 112, '辉': 76,
    '辰': 106, '迁': 113, '进': 114, '远': 109, '逸': 11, '邢': 115,
    '郑': 61, '郭': 35, '金': 114, '鑫': 72, '钢': 20, '铭': 75,
    '锋': 6, '锴': 18, '闻': 71, '陆': 112, '陈': 106, '隆': 116,
    '雄': 117, '雪': 118, '雷': 101, '青': 55, '静': 77, '韬': 85,
    '顺': 119, '飞': 107, '马': 120, '魏': 12, '鸣': 75, '鹏': 79,
    '齐': 30, '龙': 116,
  };

  static final _pressureRe = RegExp(
    r'(?<num>[0-9]+(?:\.[0-9]+)?|[零〇一二两三四五六七八九十百千万]+)\s*(?<unit>兆帕|MPa|mpa|MPA|个压|个大气压|大气压|压)',
  );
  static final _cnNumRe = RegExp(r'[零〇一二两三四五六七八九十百千万]+');

  ParseResult parse(
    String text, {
    List<String> firefighters = const [],
    List<String> hotwords = const [],
  }) {
    final clean = text.replaceAll(' ', '').replaceAll('\t', '').replaceAll('\n', '');

    final pressures = _extractPressures(clean);
    final rosterMatches = _matchRoster(clean, firefighters);
    final action = _detectAction(clean, hasValidPressure: pressures.isNotEmpty);

    final people = <ParsePerson>[];
    if (action == 'exit') {
      if (rosterMatches.isEmpty && _hasAllExit(clean)) {
        return ParseResult(action: 'exit', people: [], intent: VoiceIntent.exit);
      }
      for (final m in rosterMatches) {
        people.add(ParsePerson(name: m.name));
      }
      if (people.isEmpty) {
        for (final name in _extractExitNames(clean)) {
          people.add(ParsePerson(name: name));
        }
      }
      return ParseResult(
        action: 'exit',
        people: people.take(10).toList(),
        intent: _intentFor(clean, 'exit', people.take(10).toList(), firefighters),
      );
    }

    if (pressures.isEmpty) {
      return ParseResult(
        action: action,
        people: [],
        note: _buildNote(clean, pressures, const []),
        intent: _intentFor(clean, action, const [], firefighters),
      );
    }

    final usedPressure = List<bool>.filled(pressures.length, false);

    // 名单姓名：按位置顺序与后续最近压力配对。
    // 间距上限 24：兼容「李翔进入火场，空气呼吸器压力20兆帕」这类
    // 姓名与压力间隔较长的报数（此前 12 过紧导致配对失败、进场被误判为日志）
    final rosterSorted = List.of(rosterMatches)..sort((a, b) => a.start.compareTo(b.start));
    for (final m in rosterSorted) {
      double? matched;
      for (var i = 0; i < pressures.length; i++) {
        if (usedPressure[i]) continue;
        if (pressures[i].start <= m.start) continue;
        final gap = pressures[i].start - m.end;
        if (gap > 24) continue;
        matched = pressures[i].value;
        usedPressure[i] = true;
        break;
      }
      people.add(ParsePerson(name: m.name, pressureMpa: matched));
    }

    // 非名单姓名：压力前的 2-4 字片段
    for (var i = 0; i < pressures.length; i++) {
      if (usedPressure[i]) continue;
      final name = _nameBefore(clean, pressures[i], rosterMatches);
      if (name == null) continue;
      usedPressure[i] = true;
      people.add(ParsePerson(name: name, pressureMpa: pressures[i].value));
    }

    final note = _buildNote(clean, pressures, people);
    if (people.isEmpty) {
      return ParseResult(
        action: action,
        people: [],
        note: note,
        intent: _intentFor(clean, action, const [], firefighters),
      );
    }
    return ParseResult(
      action: action,
      people: people.take(10).toList(),
      note: note,
      intent: _intentFor(clean, action, people.take(10).toList(), firefighters),
    );
  }

  static const _askWords = ['怎么办', '咋办', '怎么', '如何', '为什么', '为啥', '能不能', '可不可以', '是否', '什么', '多少', '哪里', '在哪', '怎样', '怎么办才好'];
  // 明确噪音特征：命中任一即允许丢弃（语气词/测试/试音，不构成任务信息）
  static const _noiseWords = ['测试', '试试', '试音', '喂', '嗯', '哦', '啊', '哈哈', '咳咳', '听得到吗', '能听到吗', '在吗', '嘀嗒'];
  // 灭火救援任务全生命周期痕迹词（对齐后端 FIRE_KEYWORDS）：
  // 出动/行进/侦察/指挥/战斗/搜救/收尾/通信/装备——命中任一即不允许判为 ignore（宁记不错过）
  static const _fireWords = [
    // 压力/气瓶（安全员核心报告内容）
    '兆帕', '个压', '压力', '气压', '余气', '气量', '空呼', '气瓶',
    // 进场作业
    '进场', '进入', '进去', '进火场', '入场', '入火场', '开始作业', '上气瓶',
    // 灭火战斗
    '火', '救援', '救', '水带', '浓烟', '烟', '被困', '明火', '燃烧', '消防', '搜救', '灭火', '破拆', '内攻', '外攻',
    '水枪', '水炮', '供水', '出水', '断水', '泡沫', '阵地', '排烟', '照明', '灭火剂', '被困人员',
    // 指挥/组织
    '指挥员', '带队', '指挥部', '全勤', '到场', '到达现场', '赶赴', '出动', '出警', '接警', '警情', '增援',
    '战况', '部署', '警戒', '封控', '疏散', '处置', '作战', '协同', '请示', '报告',
    // 行进/路况（出警途中通报）
    '途中', '路况', '堵车', '让行', '鸣笛', '警笛', '抵达', '沿路', '通行', '路口', '车辆', '车队', '红绿灯',
    // 侦察/灾情
    '侦察', '侦查', '火势', '蔓延', '楼层', '燃烧物', '伤亡', '位置',
    // 搜救/救助
    '担架', '营救', '转移',
    // 破拆/处置
    '切割', '扩张', '顶撑', '断电', '断气', '登高', '云梯',
    // 安全/通信
    '安全员', '呼救', '避险', '收到', '明白', '完毕', '复述', '通报', '上报', '确认',
    // 收尾/保障
    '收水带', '清点', '洗消', '器材', '装备', '战备', '演练',
    // 出场动作（本地 exit 场景）
    '出场', '出来', '撤离', '退场', '离场', '离开', '收工', '撤退', '归队', '结束作业',
  ];

  /// 规则版意图判断，对齐后端 guardrailIntent：宁记不错过
  String _intentFor(String text, String action, List<ParsePerson> people, List<String> firefighters) {
    if (action == 'exit') {
      return people.isNotEmpty || _hasAllExit(text) ? VoiceIntent.exit : VoiceIntent.note;
    }
    if (action == 'enter') {
      return people.isNotEmpty ? VoiceIntent.entry : VoiceIntent.note;
    }
    // 疑问句/求助口吻 → 提问
    if (_askWords.any(text.contains)) return VoiceIntent.ask;
    // 环境音意图：默认保留（安全员主动按键报话即记录信号），仅明确噪音才允许丢弃——
    // 命中名单/压力/火场痕迹 → 必救回；长完整陈述句（路况、情况通报等）同样救回
    final hasTrace = firefighters.any((n) => text.contains(n)) ||
        _pressureRe.hasMatch(text) ||
        _fireWords.any(text.contains);
    if (hasTrace) return VoiceIntent.note;
    final isNoise = text.length <= 6 || _noiseWords.any(text.contains);
    if (isNoise) return VoiceIntent.ignore;
    return VoiceIntent.note;
  }

  String _detectAction(String text, {required bool hasValidPressure}) {
    if (_exitWords.any(text.contains)) return 'exit';
    if (_enterWords.any(text.contains) || hasValidPressure) return 'enter';
    return 'unknown';
  }

  bool _hasAllExit(String text) {
    return text.contains('全员') || text.contains('全部') || text.contains('所有人');
  }

  static const _numMap = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };

  /// 中文数字 → 阿拉伯数字（支持 十五/二十/一百二/两千三百/两万 等常规表达）
  double? _cnToNum(String s) {
    if (s.isEmpty) return null;
    double total = 0;
    double curr = 0;
    var pending = 0;
    for (final ch in s.split('')) {
      final d = _numMap[ch];
      if (d != null) {
        pending = pending * 10 + d;
        continue;
      }
      if (ch == '十') {
        curr += (pending == 0 ? 1 : pending) * 10;
      } else if (ch == '百') {
        curr += (pending == 0 ? 1 : pending) * 100;
      } else if (ch == '千') {
        curr += (pending == 0 ? 1 : pending) * 1000;
      } else if (ch == '万') {
        total += (curr + (pending == 0 ? 1 : pending)) * 10000;
        curr = 0;
      }
      pending = 0;
    }
    total += curr + pending;
    return total;
  }

  List<_PressureMatch> _extractPressures(String text) {
    final out = <_PressureMatch>[];
    for (final m in _pressureRe.allMatches(text)) {
      final raw = m.namedGroup('num')!;
      final value = _cnNumRe.hasMatch(raw) ? _cnToNum(raw) : double.tryParse(raw);
      if (value == null || value <= 0 || value > 100) continue;
      out.add(_PressureMatch(start: m.start, end: m.end, value: value));
    }
    return out;
  }

  /// 名单姓名匹配：长名优先，避免短名嵌入长名（如"张伟"vs"张伟强"）
  List<_RosterMatch> _matchRoster(String text, List<String> firefighters) {
    final names = firefighters.map((n) => n.trim()).where((n) => n.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final matches = <_RosterMatch>[];
    for (final name in names) {
      var idx = text.indexOf(name);
      while (idx >= 0) {
        final overlapped = matches.any((m) => m.start < idx + name.length && idx < m.end);
        if (!overlapped) {
          matches.add(_RosterMatch(start: idx, end: idx + name.length, name: name));
          break;
        }
        idx = text.indexOf(name, idx + 1);
      }
      // 同音匹配：本地 ASR 可能把名单姓名听成同音字（如 陆河圣 → 路和胜），
      // 在文本中查找与名单姓名读音相同的连续片段，纠正为名单姓名
      if (idx == -1 || matches.every((m) => m.name != name)) {
        final code = _soundCode(name);
        if (code != null) {
          for (var i = 0; i + name.length <= text.length; i++) {
            final seg = text.substring(i, i + name.length);
            if (seg == name) continue;
            final segCode = _soundCode(seg);
            if (segCode == null || segCode != code) continue;
            final overlapped = matches.any((m) => m.start < i + name.length && i < m.end);
            if (!overlapped) {
              matches.add(_RosterMatch(start: i, end: i + name.length, name: name));
              break;
            }
          }
        }
      }
    }
    return matches;
  }

  /// 姓名读音编码：逐字查同音组（表外字返回 null，不参与同音纠正）
  String? _soundCode(String s) {
    final buf = StringBuffer();
    for (final c in s.split('')) {
      final g = _homophoneGroup[c];
      if (g == null) return null;
      buf.write('$g,');
    }
    return buf.toString();
  }

  /// 压力值前的 2-4 字片段作为姓名：跳过紧邻分隔符，取前一个分隔符后的片段，且不与名单匹配重叠
  String? _nameBefore(String text, _PressureMatch p, List<_RosterMatch> roster) {
    var i = p.start - 1;
    while (i >= 0 && _separators.contains(text[i])) {
      i--;
    }
    final segEnd = i + 1;
    while (i >= 0 && !_separators.contains(text[i])) {
      i--;
    }
    final segStart = i + 1;
    final seg = text.substring(segStart, segEnd).trim();
    if (seg.length < 2 || seg.length > 4) return null;
    if (roster.any((m) => m.start >= segStart && m.end <= segEnd)) return null;
    return seg;
  }

  static const _exitNoiseWords = ['出来了', '已出', '退场', '撤离', '离场', '离开', '收工', '结束作业', '人员', '全部', '全员', '所有人', '已经', '撤收', '撤退', '结束', '完毕', '下班', '归队'];

  /// 出场场景无名单姓名时：按分隔符提取姓名片段，剥掉尾部动作词后校验长度
  List<String> _extractExitNames(String text) {
    final out = <String>[];
    var seg = StringBuffer();
    void flush() {
      var s = seg.toString();
      seg = StringBuffer();
      for (final w in [..._exitWords, '已经']) {
        if (s.endsWith(w)) {
          s = s.substring(0, s.length - w.length);
          break;
        }
      }
      if (s.length < 2 || s.length > 4) return;
      if (_exitNoiseWords.contains(s)) return;
      if (_exitWords.any(s.contains)) return;
      out.add(s);
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (_separators.contains(ch)) {
        flush();
      } else {
        seg.write(ch);
      }
    }
    flush();
    return out;
  }

  String _buildNote(String text, List<_PressureMatch> pressures, List<ParsePerson> people) {
    if (people.isEmpty && pressures.isEmpty) return '未识别到人员与压力信息';
    if (people.length >= 10) return '人数超过 10 人，仅保留前 10 人';
    return '';
  }
}

class _PressureMatch {
  final int start;
  final int end;
  final double value;
  _PressureMatch({required this.start, required this.end, required this.value});
}

class _RosterMatch {
  final int start;
  final int end;
  final String name;
  _RosterMatch({required this.start, required this.end, required this.name});
}
