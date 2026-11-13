import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/hazmat.dart';
import 'package:watchdog/services/hazmat_local_store.dart';

class _FakeSyncApi extends ApiClient {
  final List<int> requestedSince = [];
  HazmatSyncResult Function(int since)? onSync;

  _FakeSyncApi() : super(baseUrl: 'http://localhost', incidentId: 'test-inc');

  @override
  Future<HazmatSyncResult> syncHazmats({
    int since = 0,
    int limit = 500,
  }) async {
    requestedSince.add(since);
    if (onSync != null) {
      return onSync!(since);
    }
    return const HazmatSyncResult();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory dir;
  late Database db;
  late HazmatLocalStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hazmat_store_test_');
    db = await databaseFactoryFfi.openDatabase('${dir.path}/hazmat.db');
    store = HazmatLocalStore.forDatabase(db);
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test('初始化内置种子库包含 65 种以上常见危化品及核心 UN 编号', () async {
    final total = await store.countAll();
    expect(total, greaterThanOrEqualTo(65));

    final un1075 = await store.search(query: '1075');
    expect(un1075, isNotEmpty);
    expect(un1075.first.unNumber, '1075');
    expect(un1075.first.nameCn, '液化石油气');
    expect(un1075.first.vaporDensityHint, contains('重于空气'));

    final un1017 = await store.search(query: '1017');
    expect(un1017, isNotEmpty);
    expect(un1017.first.unNumber, '1017');
    expect(un1017.first.nameCn, '氯气');

    final un1428 = await store.search(query: '1428');
    expect(un1428, isNotEmpty);
    expect(un1428.first.unNumber, '1428');
    expect(un1428.first.isWaterForbidden, isTrue);
    expect(un1428.first.forbiddenAgents, contains('水'));
  });

  test('支持 UN 前缀、中文俗名与禁水条件检索排序', () async {
    final withPrefix = await store.search(query: 'UN 1428');
    expect(withPrefix.first.unNumber, '1428');

    final withHyphen = await store.search(query: 'un-1428');
    expect(withHyphen.first.unNumber, '1428');

    final byAlias = await store.search(query: '金属钠');
    expect(byAlias, isNotEmpty);
    expect(byAlias.first.unNumber, '1428');

    final forbiddenList = await store.search(water: 'forbidden');
    expect(forbiddenList, isNotEmpty);
    expect(forbiddenList.every((e) => e.isWaterForbidden), isTrue);
  });

  test('服务端增量同步覆盖同 UN 种子记录并处理软删除', () async {
    final api = _FakeSyncApi();
    api.onSync = (since) {
      expect(since, 0);
      return HazmatSyncResult(
        serverTime: 1700000100000,
        items: [
          HazmatItem(
            id: 'srv-1075',
            nameCn: '液化石油气（云端核准版）',
            unNumber: '1075',
            dangerCategory: '第2.1类 易燃气体',
            waterReactivity: 'normal',
            forbiddenAgents: '断源前严禁盲目灭火',
            extinguishingAgents: '大流量水幕冷却 + 干粉',
            updatedAt: 1700000100000,
            source: 'server',
          ),
          HazmatItem(
            id: 'srv-custom-999',
            nameCn: '示例厂区特制试剂',
            unNumber: '9999',
            dangerCategory: '第3类 易燃液体',
            waterReactivity: 'normal',
            forbiddenAgents: '严禁直流水冲散',
            updatedAt: 1700000100000,
            source: 'server',
          ),
        ],
      );
    };

    final summary1 = await store.syncFromServer(api);
    expect(summary1.upserted, 2);
    expect(summary1.serverTime, 1700000100000);
    expect(await store.getLastSyncAt(), 1700000100000);

    // 搜索 1075 时去重，只返回云端核准版，不出现两条 1075
    final hits1075 = await store.search(query: '1075');
    expect(hits1075.where((e) => e.unNumber == '1075').length, 1);
    expect(hits1075.first.nameCn, '液化石油气（云端核准版）');
    expect(hits1075.first.source, 'server');

    // 搜索自定义试剂可命中
    final customHits = await store.search(query: '9999');
    expect(customHits.length, 1);
    expect(customHits.first.nameCn, '示例厂区特制试剂');

    // 二次同步携带 since=1700000100000 并软删除 srv-custom-999
    api.onSync = (since) {
      expect(since, 1700000100000);
      return const HazmatSyncResult(
        serverTime: 1700000200000,
        deletedIds: ['srv-custom-999'],
      );
    };
    final summary2 = await store.syncFromServer(api);
    expect(summary2.deleted, 1);
    expect(await store.getLastSyncAt(), 1700000200000);
    expect(await store.search(query: '9999'), isEmpty);
  });

  test('formatShareText 输出纯文本处置要点并在 AI 来源时附带警示', () {
    const seedItem = HazmatItem(
      id: 'seed-1428',
      nameCn: '钠',
      unNumber: '1428',
      dangerCategory: '第4.3项 遇水放出易燃气体的物质',
      waterReactivity: 'forbidden',
      forbiddenAgents: '严禁使用水、泡沫及二氧化碳！',
      extinguishingAgents: 'D类金属干粉、干燥砂土',
      isolationDistance: '初期隔离 50m',
      source: 'seed',
    );
    final seedText = seedItem.formatShareText();
    expect(seedText, contains('UN 1428 钠'));
    expect(seedText, contains('遇水属性：严禁用水'));
    expect(seedText, contains('绝对禁忌：严禁使用水、泡沫及二氧化碳！'));
    expect(seedText, isNot(contains('AI 辅助提炼')));

    final aiItem = seedItem.copyWith(source: 'ai');
    final aiText = aiItem.formatShareText(
      aiDisclaimer: 'AI 辅助提炼，请核对随车运单',
    );
    expect(aiText, contains('AI 辅助提炼，请核对随车运单'));
  });
}
