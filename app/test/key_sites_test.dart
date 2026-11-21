import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/key_site_recents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('最近查看只保存标识时间，按成员隔离并阻止退出后的迟到写入', () async {
    final store = KeySiteRecents();
    final one = store.begin(server: 'test', unitId: 'u', memberId: 'm1');
    await store.viewed(one, 'a', at: 1);
    await store.viewed(one, 'b', at: 2);
    await store.viewed(one, 'a', at: 3);
    expect(await store.read(one), ['a', 'b']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      (jsonDecode(prefs.getString(one)!) as List).first.keys,
      unorderedEquals(['id', 'viewedAt']),
    );
    final two = store.begin(server: 'test', unitId: 'u', memberId: 'm2');
    expect(await store.read(two), isEmpty);
    final clearing = store.clearAll();
    await store.viewed(two, 'late');
    await clearing;
    expect(
      prefs.getKeys().where((k) => k.startsWith('key_site_recent_v1:')),
      isEmpty,
    );
  });

  test('最近查看最多二十条且并发写入顺序稳定', () async {
    final store = KeySiteRecents();
    final scope = store.begin(server: 'test', unitId: 'u', memberId: 'm');
    await Future.wait(
      List.generate(25, (i) => store.viewed(scope, '$i', at: i)),
    );
    final result = await store.read(scope);
    expect(result.length, 20);
    expect(result.first, '24');
    expect(result.last, '5');
  });

  test('警情快照兼容旧响应并解析版本关联', () {
    expect(Incident.fromJson({'id': 'i'}).keySiteLink, isNull);
    final current = Incident.fromJson({
      'id': 'i',
      'key_site_link_revision': 3,
      'key_site_link': {
        'siteId': 's',
        'name': '合成单位',
        'address': '地址',
        'version': 2,
        'linkedBy': 'm',
        'linkedAt': 4,
      },
    });
    expect(current.keySiteLink!.version, 2);
    expect(current.keySiteLinkRevision, 3);
  });
}
