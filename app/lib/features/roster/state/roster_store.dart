import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/local_asr_service.dart';
import '../../../services/org_directory.dart';
import '../../../services/scoped_json_cache.dart';
import '../../../services/settings.dart';
import '../../../services/sync_reducer.dart';
import '../data/models/firefighter.dart';
import '../data/models/hotword.dart';
import '../data/models/station.dart';

/// 组织名单与热词域状态容器（独立于其他 Feature Store）。
///
/// 封装 [OrgDirectory]（人员名单、热词、消防站）及与 `app_controller.dart` 一致的
/// 安全不变量：
/// - 本地缓存强绑定 `cached_roster_unit_id`，严禁跨单位复用；
/// - 未认证或缓存缺失/损坏时仅保留通用词（不加载任何单位姓名或单位词）；
/// - 并发拉取自动合并为单次远端请求，并同步热词至冻结的 [LocalAsrService]。
class RosterStore extends ChangeNotifier {
  /// 当前认证单位名单/热词/消防站本地缓存键（与历史版本存储格式 100% 兼容）。
  static const String cachedFirefightersKey = 'cached_firefighters';
  static const String cachedHotwordsKey = 'cached_hotwords';
  static const String cachedStationsKey = 'cached_stations';
  static const String cachedRosterUnitIdKey = 'cached_roster_unit_id';

  /// 旧版本未绑定单位的遗留标记键，清理缓存时一并清除。
  static const String legacyBuiltinRosterKey = 'builtin_roster_initialized_v1';

  /// `ScopedJsonCache` 中的组织消防站列表类别键。
  static const String scopedStationsCacheKind = 'org-stations';

  final OrgDirectory orgDirectory;
  final LocalAsrService? localAsr;

  RosterStore({OrgDirectory? orgDirectory, this.localAsr})
    : orgDirectory = orgDirectory ?? OrgDirectory();

  Future<void>? _loadRosterFuture;
  bool _disposed = false;

  bool get disposed => _disposed;
  bool get isLoading => _loadRosterFuture != null;

  List<Firefighter> get firefighters => orgDirectory.firefighters;
  List<Hotword> get hotwords => orgDirectory.hotwords;
  List<Station> get stations => orgDirectory.stations;
  List<String> get parserNames => orgDirectory.parserNames;
  List<String> get asrTerms => orgDirectory.asrTerms;
  List<Map<String, String>> get stationCache => orgDirectory.stationCache;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setFirefighters(List<Firefighter> value, {bool notify = true}) {
    orgDirectory.firefighters = value;
    if (notify) _notify();
  }

  void setHotwords(List<Hotword> value, {bool notify = true}) {
    orgDirectory.hotwords = value;
    if (notify) _notify();
  }

  void setStations(List<Station> value, {bool notify = true}) {
    orgDirectory.stations = value;
    if (notify) _notify();
  }

  /// 清空内存中的名单、热词与消防站。
  void clear({bool notify = true}) {
    orgDirectory.clear();
    if (notify) _notify();
  }

  /// 未认证状态或缓存损坏时回退内置默认：不加载任何单位姓名或单位词，
  /// 仅保留 [OrgDirectory.asrTerms] 中的通用消防词。
  void loadBuiltinDefaults({bool notify = true}) {
    orgDirectory.clear();
    if (notify) _notify();
  }

  /// 将当前组织词库热词静默同步到冻结的 [LocalAsrService]。
  void syncHotwordsToAsr() {
    final asr = localAsr;
    if (asr == null) return;
    unawaited(
      asr.updateHotwords(orgDirectory.asrTerms).catchError((Object _) {}),
    );
  }

  /// 重置冻结的 [LocalAsrService] 热词（退出单位或认证吊销时调用）。
  Future<void> resetAsrHotwords() async {
    final asr = localAsr;
    if (asr == null) return;
    await asr.resetHotwords();
  }

  /// 启动时恢复本地名单缓存：未认证时彻底清空内存与旧缓存，已认证时严格按 `unitId` 恢复。
  Future<void> ensureLocalRoster({
    required bool authenticated,
    String? unitId,
    bool notify = true,
  }) async {
    if (!authenticated) {
      orgDirectory.clear();
      await clearRosterCache();
      if (notify) _notify();
      return;
    }
    final resolvedUnitId = unitId ?? await Settings.unitId;
    if (resolvedUnitId.isEmpty) return;
    await restoreCachedRoster(resolvedUnitId, notify: notify);
  }

  /// 应用认证响应或实时同步快照中的组织词库，并按需持久化与同步 ASR 热词。
  void applySnapshot({
    Map<String, dynamic>? roster,
    Object? stations,
    String? unitId,
    String cacheScope = '',
    bool persistCache = true,
    bool syncHotwords = true,
    bool notify = true,
  }) {
    orgDirectory.applySnapshot(roster: roster, stations: stations);
    if (persistCache && unitId != null && unitId.isNotEmpty) {
      unawaited(cacheRoster(unitId, cacheScope: cacheScope));
    }
    if (syncHotwords) {
      syncHotwordsToAsr();
    }
    if (notify) _notify();
  }

  /// 应用 `roster.*` 增量同步事件；仅在实际变更时触发缓存持久化、热词同步与通知。
  bool applySyncEvent(
    SyncEvent event, {
    String unitId = '',
    String cacheScope = '',
    bool persistCache = true,
    bool syncHotwords = true,
    bool notify = true,
  }) {
    if (!orgDirectory.applyEvent(event)) return false;
    if (persistCache && unitId.isNotEmpty) {
      unawaited(cacheRoster(unitId, cacheScope: cacheScope));
    }
    if (syncHotwords) {
      syncHotwordsToAsr();
    }
    if (notify) _notify();
    return true;
  }

  /// 拉取名单与热词（并发调用自动合并为同一 Future）：
  /// - 无有效 `unitId` 时立即清空并保持通用识别模式；
  /// - 拉取前先按 `unitId` 恢复本单位缓存，断网/服务器不可达时回退缓存；
  /// - 消防站接口单独失败时保留已恢复的本组织站列表，不回滚名单热词。
  Future<void> loadRoster({
    required String fallbackUnitId,
    required Future<List<Firefighter>> Function() fetchFirefighters,
    required Future<List<Hotword>> Function() fetchHotwords,
    required Future<List<Station>> Function() fetchStations,
    String cacheScope = '',
    bool Function()? isStillCurrent,
    bool syncHotwords = false,
  }) {
    if (_disposed) return Future<void>.value();
    final existing = _loadRosterFuture;
    if (existing != null) return existing;
    final future = _loadRosterInternal(
      fallbackUnitId: fallbackUnitId,
      fetchFirefighters: fetchFirefighters,
      fetchHotwords: fetchHotwords,
      fetchStations: fetchStations,
      cacheScope: cacheScope,
      isStillCurrent: isStillCurrent,
      syncHotwords: syncHotwords,
    );
    _loadRosterFuture = future;
    future.then<void>(
      (_) {
        if (identical(_loadRosterFuture, future)) _loadRosterFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_loadRosterFuture, future)) _loadRosterFuture = null;
      },
    );
    return future;
  }

  Future<void> _loadRosterInternal({
    required String fallbackUnitId,
    required Future<List<Firefighter>> Function() fetchFirefighters,
    required Future<List<Hotword>> Function() fetchHotwords,
    required Future<List<Station>> Function() fetchStations,
    required String cacheScope,
    bool Function()? isStillCurrent,
    required bool syncHotwords,
  }) async {
    if (_disposed || (isStillCurrent != null && !isStillCurrent())) return;
    final configuredUnitId = await Settings.unitId;
    final unitId = configuredUnitId.isNotEmpty
        ? configuredUnitId
        : fallbackUnitId;
    if (unitId.isEmpty) {
      orgDirectory.clear();
      _notify();
      return;
    }
    await restoreCachedRoster(unitId);
    if (_disposed || (isStillCurrent != null && !isStillCurrent())) return;
    try {
      final fetchedFirefighters = await fetchFirefighters();
      final fetchedHotwords = await fetchHotwords();
      if (_disposed || (isStillCurrent != null && !isStillCurrent())) return;
      // 空数组是当前单位的合法词库状态，不能恢复其他单位或旧版本缓存。
      orgDirectory.firefighters = fetchedFirefighters;
      orgDirectory.hotwords = fetchedHotwords;
      try {
        final fetchedStations = await fetchStations();
        if (_disposed || (isStillCurrent != null && !isStillCurrent())) return;
        orgDirectory.stations = fetchedStations;
      } catch (_) {
        // 消防站接口失败时保留已恢复的本组织缓存，名单热词仍采用本次成功结果。
      }
      _notify();
      await cacheRoster(unitId, cacheScope: cacheScope);
      if (syncHotwords) {
        syncHotwordsToAsr();
      }
    } catch (_) {
      if (_disposed || (isStillCurrent != null && !isStillCurrent())) return;
      await restoreCachedRoster(unitId);
    }
  }

  /// 将当前组织名单/热词/消防站按 `unitId` 写入本地缓存。
  Future<void> cacheRoster(String unitId, {String cacheScope = ''}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(cachedRosterUnitIdKey, unitId);
      await sp.setString(
        cachedFirefightersKey,
        jsonEncode(firefighters.map((f) => f.name).toList()),
      );
      await sp.setString(
        cachedHotwordsKey,
        jsonEncode(hotwords.map((h) => h.word).toList()),
      );
      await sp.setString(
        cachedStationsKey,
        jsonEncode(orgDirectory.stationCache),
      );
      if (cacheScope.isNotEmpty) {
        await ScopedJsonCache.write(
          cacheScope,
          scopedStationsCacheKind,
          orgDirectory.stationCache,
        );
      }
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  /// 严格校验 `cached_roster_unit_id == unitId` 后恢复本地缓存；不匹配即清空，严禁跨单位复用。
  Future<void> restoreCachedRoster(String unitId, {bool notify = true}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getString(cachedRosterUnitIdKey) != unitId) {
        orgDirectory.clear();
        if (notify) _notify();
        return;
      }
      final fNames =
          (jsonDecode(sp.getString(cachedFirefightersKey) ?? '[]') as List)
              .map((e) => e.toString())
              .toList();
      final hWords =
          (jsonDecode(sp.getString(cachedHotwordsKey) ?? '[]') as List)
              .map((e) => e.toString())
              .toList();
      orgDirectory.firefighters = fNames
          .map((n) => Firefighter(id: '', name: n))
          .toList();
      orgDirectory.hotwords = hWords
          .map((w) => Hotword(id: '', word: w))
          .toList();
      final rawStations = sp.getString(cachedStationsKey);
      orgDirectory.restoreStationCache(
        rawStations == null ? const [] : jsonDecode(rawStations),
      );
      if (notify) _notify();
    } catch (_) {
      // 缓存损坏时也回退内置默认
      loadBuiltinDefaults(notify: notify);
    }
  }

  /// 清除本机所有单位名单缓存键（含历史遗留未绑定单位键）。
  Future<void> clearRosterCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(cachedRosterUnitIdKey);
      await sp.remove(cachedFirefightersKey);
      await sp.remove(cachedHotwordsKey);
      await sp.remove(cachedStationsKey);
      // 删除旧版本未绑定单位的缓存，避免认证切换时误用。
      await sp.remove(legacyBuiltinRosterKey);
    } catch (_) {}
  }

  /// 退出单位或认证失效时的原子清理：清空内存词库、清除本地缓存并重置 ASR 热词。
  Future<void> resetForSessionClear({bool notify = true}) async {
    orgDirectory.clear();
    await clearRosterCache();
    await resetAsrHotwords();
    if (notify) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadRosterFuture = null;
    super.dispose();
  }
}
