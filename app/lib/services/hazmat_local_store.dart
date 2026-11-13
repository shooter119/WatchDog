import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../api/api_client.dart';
import '../models/hazmat.dart';

class HazmatSyncSummary {
  final int upserted;
  final int deleted;
  final int serverTime;

  const HazmatSyncSummary({
    this.upserted = 0,
    this.deleted = 0,
    this.serverTime = 0,
  });
}

/// 危化品双层本地存储（内置 65+ 种常见危化品离线种子库 + 服务端增量覆盖同步）
///
/// 在真机/单元测试环境下持久化至 SQLite；若在未注册 sqflite 插件的纯 Widget
/// 测试环境中运行，则自动降级为内存种子缓存，确保页面与检索始终可用。
class HazmatLocalStore {
  static const String seedAssetPath = 'assets/data/hazmat_seed.json';
  static const String _dbName = 'watchdog_hazmat.db';
  static const int _dbVersion = 1;

  static final HazmatLocalStore instance = HazmatLocalStore._();

  final Database? _injectedDb;
  final AssetBundle? _injectedBundle;

  Database? _db;
  Future<void>? _initFuture;
  bool _initialized = false;
  bool _memoryFallback = false;
  int _memorySeedVersion = 0;
  int _memoryLastSyncAt = 0;
  final Map<String, HazmatItem> _memoryItems = <String, HazmatItem>{};

  HazmatLocalStore._()
      : _injectedDb = null,
        _injectedBundle = null;

  HazmatLocalStore.forDatabase(Database db, {AssetBundle? bundle})
      : _injectedDb = db,
        _injectedBundle = bundle;

  AssetBundle get _bundle => _injectedBundle ?? rootBundle;

  /// 确保建表并载入最新版本号的离线种子数据
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    if (_initFuture != null) {
      await _initFuture;
      return;
    }
    final future = _initInternal();
    _initFuture = future;
    try {
      await future;
      _initialized = true;
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _initInternal() async {
    if (_injectedDb != null) {
      _db = _injectedDb;
      await _ensureSchema(_db!);
      await _loadSeedIntoDb(_db!);
      return;
    }
    try {
      final dbDir = await getDatabasesPath();
      final dbPath = p.join(dbDir, _dbName);
      _db = await openDatabase(
        dbPath,
        version: _dbVersion,
        onCreate: (db, version) async => _ensureSchema(db),
        onOpen: (db) async => _ensureSchema(db),
      );
      await _loadSeedIntoDb(_db!);
    } catch (_) {
      // 纯 Widget 测试环境无 sqflite 原生通道时，降级至内存种子表
      _memoryFallback = true;
      await _loadSeedIntoMemory();
    }
  }

  Future<void> _ensureSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS hazmat_items (
        id TEXT PRIMARY KEY,
        un_number TEXT NOT NULL DEFAULT '',
        name_cn TEXT NOT NULL DEFAULT '',
        name_en TEXT NOT NULL DEFAULT '',
        aliases_text TEXT NOT NULL DEFAULT '',
        danger_category TEXT NOT NULL DEFAULT '',
        water_reactivity TEXT NOT NULL DEFAULT 'normal',
        source TEXT NOT NULL DEFAULT 'seed',
        updated_at INTEGER NOT NULL DEFAULT 0,
        payload_json TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_hazmat_un ON hazmat_items(un_number)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_hazmat_water ON hazmat_items(water_reactivity)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS hazmat_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<({int version, List<HazmatItem> items})> _readSeedAsset() async {
    final data = await _bundle.load(seedAssetPath);
    final raw = utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return (version: 1, items: const <HazmatItem>[]);
    }
    final versionRaw = decoded['version'];
    final version = versionRaw is num ? versionRaw.toInt() : 1;
    final rawItems = decoded['items'];
    final items = <HazmatItem>[];
    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map) {
          final item = HazmatItem.fromJson(
            Map<String, dynamic>.from(entry),
            defaultSource: 'seed',
          );
          if (item.id.isNotEmpty && item.nameCn.isNotEmpty) {
            items.add(item);
          }
        }
      }
    }
    return (version: version, items: items);
  }

  Future<void> _loadSeedIntoDb(Database db) async {
    final seed = await _readSeedAsset();
    final metaRows = await db.query(
      'hazmat_meta',
      where: 'key = ?',
      whereArgs: ['seed_version'],
      limit: 1,
    );
    final currentVersion = metaRows.isEmpty
        ? 0
        : (int.tryParse((metaRows.first['value'] ?? '0').toString()) ?? 0);
    final countRes = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM hazmat_items',
    );
    final totalRows = countRes.isEmpty
        ? 0
        : ((countRes.first['cnt'] as num?)?.toInt() ?? 0);

    if (currentVersion >= seed.version && totalRows > 0) {
      return;
    }

    await db.transaction((txn) async {
      await txn.delete(
        'hazmat_items',
        where: 'source = ?',
        whereArgs: ['seed'],
      );
      final batch = txn.batch();
      for (final item in seed.items) {
        batch.insert(
          'hazmat_items',
          _rowFromItem(item),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert(
        'hazmat_meta',
        {'key': 'seed_version', 'value': '${seed.version}'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> _loadSeedIntoMemory() async {
    final seed = await _readSeedAsset();
    if (_memorySeedVersion >= seed.version && _memoryItems.isNotEmpty) {
      return;
    }
    _memoryItems.removeWhere((_, item) => item.source == 'seed');
    for (final item in seed.items) {
      _memoryItems[item.id] = item;
    }
    _memorySeedVersion = seed.version;
  }

  Map<String, Object?> _rowFromItem(HazmatItem item) => {
    'id': item.id,
    'un_number': item.unNumber,
    'name_cn': item.nameCn,
    'name_en': item.nameEn,
    'aliases_text': item.aliases.join(' '),
    'danger_category': item.dangerCategory,
    'water_reactivity': item.waterReactivity,
    'source': item.source,
    'updated_at': item.updatedAt,
    'payload_json': jsonEncode(item.toJson()),
  };

  Future<int> countAll() async {
    await ensureInitialized();
    final items = await _loadAllRawItems();
    return _deduplicateItems(items).length;
  }

  Future<int> getLastSyncAt() async {
    await ensureInitialized();
    if (_memoryFallback || _db == null) return _memoryLastSyncAt;
    final rows = await _db!.query(
      'hazmat_meta',
      where: 'key = ?',
      whereArgs: ['last_sync_at'],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return int.tryParse((rows.first['value'] ?? '0').toString()) ?? 0;
  }

  Future<List<HazmatItem>> _loadAllRawItems() async {
    if (_memoryFallback || _db == null) {
      return _memoryItems.values.toList();
    }
    final rows = await _db!.query('hazmat_items');
    final items = <HazmatItem>[];
    for (final row in rows) {
      final rawJson = (row['payload_json'] ?? '').toString();
      if (rawJson.isEmpty) continue;
      try {
        final decoded = jsonDecode(rawJson);
        if (decoded is Map) {
          items.add(
            HazmatItem.fromJson(
              Map<String, dynamic>.from(decoded),
              defaultSource: (row['source'] ?? 'seed').toString(),
            ),
          );
        }
      } catch (_) {
        // 忽略损坏单行，避免影响其他危化品检索
      }
    }
    return items;
  }

  /// 同 UN 编号或同标准中文名时，服务端记录优先覆盖内置种子记录
  List<HazmatItem> _deduplicateItems(List<HazmatItem> raw) {
    final sorted = List<HazmatItem>.from(raw)
      ..sort((a, b) {
        final aPriority = a.source == 'server' ? 1 : 0;
        final bPriority = b.source == 'server' ? 1 : 0;
        if (aPriority != bPriority) return bPriority.compareTo(aPriority);
        return b.updatedAt.compareTo(a.updatedAt);
      });

    final seenKeys = <String>{};
    final result = <HazmatItem>[];
    for (final item in sorted) {
      if (!item.active) continue;
      final unKey = item.unNumber.isNotEmpty ? 'un:${item.unNumber}' : '';
      final nameKey = item.nameCn.isNotEmpty
          ? 'name:${item.nameCn.toLowerCase()}'
          : '';
      if ((unKey.isNotEmpty && seenKeys.contains(unKey)) ||
          (nameKey.isNotEmpty && seenKeys.contains(nameKey))) {
        continue;
      }
      if (unKey.isNotEmpty) seenKeys.add(unKey);
      if (nameKey.isNotEmpty) seenKeys.add(nameKey);
      result.add(item);
    }
    return result;
  }

  /// 检索本地危化品库（支持 UN 编号、带 UN 前缀、中文名、俗名别名、CAS 号、水属性与危险类别过滤）
  Future<List<HazmatItem>> search({
    String query = '',
    String water = '',
    String category = '',
    int limit = 80,
  }) async {
    await ensureInitialized();
    final items = _deduplicateItems(await _loadAllRawItems());

    final cleanWater = water.trim();
    final cleanCategory = category.trim().toLowerCase();
    final rawQ = query.trim().toLowerCase();
    final noUnQ = rawQ
        .replaceFirst(RegExp(r'^un[\s-]*', caseSensitive: false), '')
        .trim();
    final isNumericUnQuery = RegExp(r'^\d{1,4}$').hasMatch(noUnQ);

    final scored = <({HazmatItem item, int score, int order})>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (cleanWater.isNotEmpty && item.waterReactivity != cleanWater) {
        continue;
      }
      if (cleanCategory.isNotEmpty &&
          !item.dangerCategory.toLowerCase().contains(cleanCategory)) {
        continue;
      }

      if (rawQ.isEmpty) {
        final serverBonus = item.source == 'server' ? 10 : 0;
        scored.add((item: item, score: serverBonus, order: i));
        continue;
      }

      final score = _matchScore(
        item,
        rawQ: rawQ,
        noUnQ: noUnQ,
        isNumericUnQuery: isNumericUnQuery,
      );
      if (score > 0) {
        scored.add((item: item, score: score, order: i));
      }
    }

    scored.sort((a, b) {
      if (a.score != b.score) return b.score.compareTo(a.score);
      if (a.item.source != b.item.source) {
        return a.item.source == 'server' ? -1 : 1;
      }
      return a.order.compareTo(b.order);
    });

    if (scored.length <= limit) {
      return scored.map((e) => e.item).toList();
    }
    return scored.take(limit).map((e) => e.item).toList();
  }

  int _matchScore(
    HazmatItem item, {
    required String rawQ,
    required String noUnQ,
    required bool isNumericUnQuery,
  }) {
    final un = item.unNumber.toLowerCase();
    final nameCn = item.nameCn.toLowerCase();
    final nameEn = item.nameEn.toLowerCase();
    final cas = item.casNumber.toLowerCase();
    final aliases = item.aliases.map((e) => e.toLowerCase()).toList();

    if (noUnQ.isNotEmpty && un == noUnQ) return 100;
    if (nameCn == rawQ || aliases.any((a) => a == rawQ)) return 90;
    if ((cas.isNotEmpty && cas == rawQ) || (nameEn.isNotEmpty && nameEn == rawQ)) {
      return 85;
    }
    if (isNumericUnQuery && noUnQ.isNotEmpty && un.startsWith(noUnQ)) {
      return 80;
    }
    if (nameCn.startsWith(rawQ) || aliases.any((a) => a.startsWith(rawQ))) {
      return 70;
    }
    if (noUnQ.isNotEmpty && un.contains(noUnQ)) return 60;
    if (nameCn.contains(rawQ) ||
        aliases.any((a) => a.contains(rawQ)) ||
        nameEn.contains(rawQ) ||
        cas.contains(rawQ)) {
      return 50;
    }
    if (item.dangerCategory.toLowerCase().contains(rawQ) ||
        item.dangerSummary.toLowerCase().contains(rawQ)) {
      return 30;
    }
    return 0;
  }

  /// 将单条同步响应写入本地持久化（供 syncFromServer 与单元测试使用）
  Future<void> applySyncResult(HazmatSyncResult result) async {
    await ensureInitialized();
    if (_memoryFallback || _db == null) {
      for (final deletedId in result.deletedIds) {
        _memoryItems.remove(deletedId);
      }
      for (final item in result.items) {
        final normalized = item.copyWith(source: 'server');
        _memoryItems[normalized.id] = normalized;
      }
      if (result.serverTime > _memoryLastSyncAt) {
        _memoryLastSyncAt = result.serverTime;
      }
      return;
    }

    final currentSyncAt = await getLastSyncAt();
    final nextSyncAt = result.serverTime > currentSyncAt
        ? result.serverTime
        : currentSyncAt;

    await _db!.transaction((txn) async {
      final batch = txn.batch();
      for (final deletedId in result.deletedIds) {
        batch.delete('hazmat_items', where: 'id = ?', whereArgs: [deletedId]);
      }
      for (final item in result.items) {
        final normalized = item.copyWith(source: 'server');
        batch.insert(
          'hazmat_items',
          _rowFromItem(normalized),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert(
        'hazmat_meta',
        {'key': 'last_sync_at', 'value': '$nextSyncAt'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
  }

  /// 在线静默增量同步服务端标准库（分页拉取，最多 10 页防死循环）
  Future<HazmatSyncSummary> syncFromServer(ApiClient api) async {
    await ensureInitialized();
    var since = await getLastSyncAt();
    var totalUpserted = 0;
    var totalDeleted = 0;
    var latestServerTime = since;

    for (var page = 0; page < 10; page++) {
      final res = await api.syncHazmats(since: since, limit: 500);
      if (res.items.isNotEmpty ||
          res.deletedIds.isNotEmpty ||
          res.serverTime > since) {
        await applySyncResult(res);
      }
      totalUpserted += res.items.length;
      totalDeleted += res.deletedIds.length;
      if (res.serverTime > latestServerTime) {
        latestServerTime = res.serverTime;
      }
      if (res.items.length < 500 || res.serverTime <= since) {
        break;
      }
      since = res.serverTime;
    }

    return HazmatSyncSummary(
      upserted: totalUpserted,
      deleted: totalDeleted,
      serverTime: latestServerTime,
    );
  }
}
