import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-private cache keyed by server, unit and user; never keyed by credentials.
class ScopedJsonCache {
  static Future<void> _tail = Future<void>.value();
  static String _key(String scope, String kind) =>
      'incident_cache_${sha256.convert(utf8.encode('$scope|$kind'))}';
  static Future<void> write(String scope, String kind, Object value) {
    if (scope.isEmpty) return Future.value();
    final next = _tail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (kind.startsWith('details:') && value is Map) {
        final old = prefs.getString(_key(scope, kind));
        if (old != null) {
          try {
            final previous = jsonDecode(old);
            if (previous is Map &&
                (previous['version'] as num? ?? 0) >
                    (value['version'] as num? ?? 0)) {
              return;
            }
          } catch (_) {
            /* replace corrupt cache */
          }
        }
      }
      await prefs.setString(_key(scope, kind), jsonEncode(value));
    });
    // Disk failure must neither fail a successful network write nor poison later cache writes.
    _tail = next.catchError((_) {});
    return _tail;
  }

  static Future<dynamic> read(String scope, String kind) async {
    if (scope.isEmpty) return null;
    await _tail;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(scope, kind));
      return raw == null ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}
