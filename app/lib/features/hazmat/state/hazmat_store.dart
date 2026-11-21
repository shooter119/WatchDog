import 'package:flutter/foundation.dart';

import '../../../services/hazmat_local_store.dart';
import '../data/hazmat_repository.dart';
import '../data/models/hazmat.dart';

/// 危化品云端能力网关（增量同步 + 显式手动 AI 提炼，零 `AppController` / `ApiClient` 耦合）。
class HazmatGateway {
  const HazmatGateway({
    required this.syncHazmats,
    required this.generateHazmatAiCard,
  });

  /// 基于 [HazmatRepository] 构建网关的便捷工厂。
  factory HazmatGateway.fromRepository(HazmatRepository repository) {
    return HazmatGateway(
      syncHazmats: ({int since = 0, int limit = 500}) =>
          repository.syncHazmats(since: since, limit: limit),
      generateHazmatAiCard: repository.generateHazmatAiCard,
    );
  }

  final Future<HazmatSyncResult> Function({int since, int limit}) syncHazmats;
  final Future<HazmatAiResult> Function(String query) generateHazmatAiCard;
}

/// 危化品应急速查状态容器。
///
/// 双层离线保障：依托冻结的 [HazmatLocalStore] 实现 UN 编号 / 品名 / 俗名 / 遇水属性
/// 秒级离线检索，联网时静默增量同步服务端标准库。
/// 严格保证：本地未命中时**绝不自动调用 AI**，仅在用户显式点击按钮时触发 [requestAiCard]。
class HazmatStore extends ChangeNotifier {
  HazmatStore({HazmatLocalStore? localStore, this.gateway})
    : _localStore = localStore ?? HazmatLocalStore.instance;

  static const int _syncPageSize = 500;
  static const int _maxSyncPages = 10;

  final HazmatLocalStore _localStore;
  final HazmatGateway? gateway;

  List<HazmatItem> _results = const [];
  HazmatItem? _selected;
  HazmatAiResult? _aiResult;
  bool _loadingLocal = true;
  bool _syncing = false;
  bool _syncedFromServer = false;
  bool _loadingAi = false;
  String? _aiError;
  String _query = '';
  String _waterFilter = ''; // '' | 'forbidden' | 'reactive' | 'normal'
  int _totalCount = 0;

  int _searchGeneration = 0;
  int _aiGeneration = 0;
  bool _disposed = false;

  List<HazmatItem> get results => List<HazmatItem>.unmodifiable(_results);
  HazmatItem? get selected => _selected;
  HazmatAiResult? get aiResult => _aiResult;
  bool get loadingLocal => _loadingLocal;
  bool get syncing => _syncing;
  bool get syncedFromServer => _syncedFromServer;
  bool get loadingAi => _loadingAi;
  String? get aiError => _aiError;
  String get query => _query;
  String get trimmedQuery => _query.trim();
  String get waterFilter => _waterFilter;
  int get totalCount => _totalCount;

  bool get canSync => gateway != null;
  bool get canGenerateAi => gateway != null;

  HazmatItem? get activeItem =>
      _selected ?? (_aiResult?.found == true ? _aiResult!.item : null);

  bool get isActiveItemAi =>
      (activeItem?.isAiGenerated ?? false) || _aiResult?.source == 'ai';

  /// 首次载入本地离线词库，若具备云端能力则静默增量同步。
  Future<void> initialize() async {
    await loadLocal();
    if (_disposed || gateway == null) return;
    await syncFromServer();
  }

  /// 通过 [HazmatGateway.syncHazmats] 分页增量同步服务端标准库并落入冻结的 [HazmatLocalStore]。
  Future<void> syncFromServer() async {
    final activeGateway = gateway;
    if (activeGateway == null || _syncing || _disposed) return;

    _syncing = true;
    _notify();
    try {
      await _localStore.ensureInitialized();
      var since = await _localStore.getLastSyncAt();
      for (var page = 0; page < _maxSyncPages; page++) {
        if (_disposed) return;
        final res = await activeGateway.syncHazmats(
          since: since,
          limit: _syncPageSize,
        );
        if (_disposed) return;
        if (res.items.isNotEmpty ||
            res.deletedIds.isNotEmpty ||
            res.serverTime > since) {
          await _localStore.applySyncResult(res);
        }
        if (res.items.length < _syncPageSize || res.serverTime <= since) {
          break;
        }
        since = res.serverTime;
      }
      if (_disposed) return;
      _syncedFromServer = true;
      await loadLocal();
    } catch (_) {
      // 现场网络不稳时静默保留本地离线词库，不弹出阻塞提示
    } finally {
      _syncing = false;
      _notify();
    }
  }

  /// 离线瞬时检索本地危化品库（绝不触发云端 AI 请求）。
  Future<void> loadLocal() async {
    final generation = ++_searchGeneration;
    final querySnapshot = _query;
    final waterSnapshot = _waterFilter;
    final items = await _localStore.search(
      query: querySnapshot,
      water: waterSnapshot,
      limit: 80,
    );
    final total = await _localStore.countAll();
    if (_disposed || generation != _searchGeneration) return;
    _results = items;
    _totalCount = total;
    _loadingLocal = false;
    _selected = resolveAutoSelected(querySnapshot, items);
    _notify();
  }

  /// 更新检索词并立即执行本地离线检索；不自动调用 AI。
  Future<void> updateQuery(String value) async {
    _query = value;
    _aiGeneration++;
    _aiResult = null;
    _aiError = null;
    _loadingAi = false;
    _notify();
    await loadLocal();
  }

  /// 切换遇水属性筛选并立即刷新本地列表。
  Future<void> setWaterFilter(String value) async {
    _waterFilter = value;
    _selected = null;
    _aiGeneration++;
    _aiResult = null;
    _aiError = null;
    _loadingAi = false;
    _notify();
    await loadLocal();
  }

  /// 选中或取消选中列表中的单条危化品记录。
  void selectItem(HazmatItem? item) {
    if (identical(_selected, item)) return;
    _selected = item;
    _notify();
  }

  /// 仅由用户显式点击触发：请求云端精确库或 AI 应急提炼战术卡。
  Future<void> requestAiCard() async {
    final activeGateway = gateway;
    final cleanQuery = _query.trim();
    if (activeGateway == null || cleanQuery.isEmpty || _loadingAi || _disposed) {
      return;
    }

    final generation = ++_aiGeneration;
    _loadingAi = true;
    _aiError = null;
    _aiResult = null;
    _notify();

    try {
      final result = await activeGateway.generateHazmatAiCard(cleanQuery);
      if (_disposed || generation != _aiGeneration) return;
      _aiResult = result;
      _loadingAi = false;
      _notify();
    } catch (e) {
      if (_disposed || generation != _aiGeneration) return;
      _aiError = e.toString().replaceFirst('Exception: ', '');
      _loadingAi = false;
      _notify();
    }
  }

  /// 输入完整 4 位 UN 号精确命中（或仅命中 1 条记录）时直出战术卡。
  static HazmatItem? resolveAutoSelected(
    String rawQuery,
    List<HazmatItem> items,
  ) {
    if (items.isEmpty) return null;
    final stripped = rawQuery
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^un[\s-]*', caseSensitive: false), '')
        .trim();
    if (stripped.isEmpty) return null;
    if (RegExp(r'^\d{4}$').hasMatch(stripped)) {
      for (final item in items) {
        if (item.unNumber.toLowerCase() == stripped) {
          return item;
        }
      }
    }
    if (items.length == 1) {
      return items.first;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
