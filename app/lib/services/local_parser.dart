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

    // 名单姓名：按位置顺序与后续最近压力配对
    final rosterSorted = List.of(rosterMatches)..sort((a, b) => a.start.compareTo(b.start));
    for (final m in rosterSorted) {
      double? matched;
      for (var i = 0; i < pressures.length; i++) {
        if (usedPressure[i]) continue;
        if (pressures[i].start <= m.start) continue;
        final gap = pressures[i].start - m.end;
        if (gap > 12) continue;
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
  static const _noiseWords = ['测试', '喂喂', '喂', '嗯', '哦', '啊', '咳咳', '哈哈', '试试', '语音', '说话'];
  static const _fireWords = ['火', '救援', '救', '水带', '气瓶', '浓烟', '烟', '被困', '明火', '燃烧', '消防', '搜救', '灭火', '破拆', '内攻', '进场', '出场', '出来', '撤离', '兆帕', '个压', '压力'];

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
    // 纯环境音：无名单姓名/压力/消防痕迹 → 丢弃；否则宁记不错过
    final hasTrace = firefighters.any((n) => text.contains(n)) ||
        _pressureRe.hasMatch(text) ||
        _fireWords.any(text.contains);
    if (!hasTrace && (text.length <= 6 || _noiseWords.any(text.contains))) {
      return VoiceIntent.ignore;
    }
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
    }
    return matches;
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
