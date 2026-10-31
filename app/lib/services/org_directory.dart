import '../models/models.dart';
import 'sync_reducer.dart';

/// 与后端 org-seed.js 的 GENERIC_ASR_TERMS 保持一致。
/// 无组织或缓存为空时，本地识别只使用这些通用词，不携带任何单位姓名。
const genericAsrTerms = <String>[
  '头车',
  '两车',
  '三车',
  '四车',
  '内攻',
  '搜救',
  '初战',
  '兆帕',
  '个压',
  '气瓶',
  '空气呼吸器',
  '余量',
  '进入火场',
  '出来了',
  '已出火场',
  '收到',
];

class OrgDirectory {
  List<Firefighter> firefighters = [];
  List<Hotword> hotwords = [];
  List<Station> stations = [];

  List<String> get parserNames => firefighters
      .map((item) => item.name.trim())
      .where((name) => name.isNotEmpty)
      .toList();

  List<String> get asrTerms {
    final seen = <String>{};
    final terms = <String>[];
    void add(String word) {
      final clean = word.trim();
      if (clean.isEmpty || !seen.add(clean)) return;
      terms.add(clean);
    }

    for (final name in parserNames) {
      add(name);
    }
    for (final hotword in hotwords) {
      add(hotword.word);
    }
    for (final station in stations) {
      add(station.name);
    }
    for (final term in genericAsrTerms) {
      add(term);
    }
    return terms;
  }

  void clear() {
    firefighters = [];
    hotwords = [];
    stations = [];
  }

  /// [roster] 或 [stations] 为 null 表示这次响应没有该字段（旧服务端），保留已有缓存。
  void applySnapshot({Map<String, dynamic>? roster, Object? stations}) {
    if (roster != null) {
      firefighters = SyncReducer.rosterNames(roster);
      hotwords = SyncReducer.rosterHotwords(roster);
    }
    if (stations is List) {
      this.stations = stations
          .whereType<Map>()
          .map((item) => Station.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.name.trim().isNotEmpty)
          .toList();
    }
  }

  bool applyEvent(SyncEvent event) {
    switch (event.eventType) {
      case 'roster.firefighter_added':
        final name = event.payload['name']?.toString().trim() ?? '';
        if (name.isEmpty) return false;
        final firefighter = Firefighter(
          id: event.payload['id']?.toString() ?? event.aggregateId ?? '',
          name: name,
          source: event.payload['source']?.toString() ?? 'user',
          createdByMemberId: event.payload['created_by_member_id']?.toString(),
        );
        firefighters = [
          firefighter,
          ...firefighters.where((item) => item.id != firefighter.id),
        ];
        return true;
      case 'roster.firefighter_removed':
        return _removeById(
          event,
          (id) => firefighters = firefighters.where((item) => item.id != id).toList(),
        );
      case 'roster.hotword_added':
        final word = event.payload['word']?.toString().trim() ?? '';
        if (word.isEmpty) return false;
        final hotword = Hotword(
          id: event.payload['id']?.toString() ?? event.aggregateId ?? '',
          word: word,
          source: event.payload['source']?.toString() ?? 'user',
          createdByMemberId: event.payload['created_by_member_id']?.toString(),
        );
        hotwords = [
          hotword,
          ...hotwords.where((item) => item.id != hotword.id),
        ];
        return true;
      case 'roster.hotword_removed':
        return _removeById(
          event,
          (id) => hotwords = hotwords.where((item) => item.id != id).toList(),
        );
      case 'roster.station_added':
        final name = event.payload['name']?.toString().trim() ?? '';
        if (name.isEmpty) return false;
        final station = Station(
          id: event.payload['id']?.toString() ?? event.aggregateId ?? '',
          name: name,
        );
        stations = [
          station,
          ...stations.where((item) => item.id != station.id),
        ];
        return true;
      case 'roster.station_removed':
        return _removeById(
          event,
          (id) => stations = stations.where((item) => item.id != id).toList(),
        );
      default:
        return false;
    }
  }

  bool _removeById(SyncEvent event, void Function(String id) remove) {
    final id = event.aggregateId ?? event.payload['id']?.toString();
    if (id == null || id.isEmpty) return false;
    remove(id);
    return true;
  }

  List<Map<String, String>> get stationCache => stations
      .map((item) => {'id': item.id, 'name': item.name})
      .toList();

  void restoreStationCache(Object? raw) {
    if (raw is! List) {
      stations = [];
      return;
    }
    stations = raw.map((item) {
      if (item is Map) return Station.fromJson(Map<String, dynamic>.from(item));
      final name = item.toString().trim();
      return Station(id: '', name: name);
    }).where((item) => item.name.trim().isNotEmpty).toList();
  }
}
