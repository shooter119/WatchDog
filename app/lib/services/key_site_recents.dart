import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 只持久化标识和访问时间。串行队列及代际检查防止退出后的迟到请求重建记录。
class KeySiteRecents {
  static const _prefix = 'key_site_recent_v1:';
  static final instance = KeySiteRecents();
  Future<void> _tail = Future<void>.value();
  String? _scope;
  int _epoch = 0;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  String begin({
    required String server,
    required String unitId,
    required String memberId,
  }) {
    final scope =
        '$_prefix${base64Url.encode(utf8.encode(jsonEncode([server, unitId, memberId])))}';
    if (_scope != scope) {
      _scope = scope;
      _epoch++;
    }
    return scope;
  }

  Future<List<String>> read(String scope) {
    final epoch = _epoch;
    return _serial(() async {
      if (_scope != scope || epoch != _epoch) return <String>[];
      final prefs = await SharedPreferences.getInstance();
      if (_scope != scope || epoch != _epoch) return <String>[];
      return _decode(
        prefs.getString(scope),
      ).map((item) => item['id'] as String).toList();
    });
  }

  Future<void> viewed(String scope, String id, {int? at}) {
    final epoch = _epoch;
    return _serial(() async {
      if (_scope != scope || epoch != _epoch) return;
      final prefs = await SharedPreferences.getInstance();
      if (_scope != scope || epoch != _epoch) return;
      final items = _decode(prefs.getString(scope))
        ..removeWhere((item) => item['id'] == id);
      items.insert(0, {
        'id': id,
        'viewedAt': at ?? DateTime.now().millisecondsSinceEpoch,
      });
      await prefs.setString(scope, jsonEncode(items.take(20).toList()));
    });
  }

  Future<void> clearAll() {
    _scope = null;
    _epoch++;
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith(_prefix),
      )) {
        await prefs.remove(key);
      }
    });
  }

  List<Map<String, dynamic>> _decode(String? raw) {
    try {
      return (jsonDecode(raw ?? '[]') as List)
          .whereType<Map>()
          .where((item) => item['id'] is String && item['viewedAt'] is num)
          .map(
            (item) => <String, dynamic>{
              'id': item['id'],
              'viewedAt': item['viewedAt'],
            },
          )
          .take(20)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
