import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Saves selected, metadata-stripped JPEGs before launching an external camera.
/// A process killed by Android can restore earlier selections plus lost camera data.
class IncidentImageDraft {
  static Future<void> _tail = Future<void>.value();
  static String _id(String scope, String incident) =>
      sha256.convert(utf8.encode('$scope|$incident')).toString();
  static Future<Directory> _dir(
    String scope,
    String incident,
  ) async => Directory(
    '${(await getApplicationSupportDirectory()).path}/incident-image-drafts/${_id(scope, incident)}',
  );
  static Future<void> save(
    String scope,
    String incident,
    List<Uint8List> images,
  ) {
    if (scope.isEmpty) return Future.value();
    final copy = List<Uint8List>.of(images);
    final result = _tail.then((_) async {
      final dir = await _dir(scope, incident);
      await dir.create(recursive: true);
      for (var i = 0; i < copy.length; i++) {
        final file = File('${dir.path}/$i.jpg');
        await file.writeAsBytes(copy[i], flush: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'image_draft_${_id(scope, incident)}',
        jsonEncode({
          'count': copy.length,
          'expires_at': DateTime.now().millisecondsSinceEpoch + 86400000,
        }),
      );
    });
    _tail = result.catchError((_) {});
    return result;
  }

  static Future<List<Uint8List>> load(String scope, String incident) async {
    if (scope.isEmpty) return [];
    await _tail;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('image_draft_${_id(scope, incident)}');
    if (raw == null) return [];
    try {
      final value = jsonDecode(raw) as Map;
      if ((value['expires_at'] as num).toInt() <
          DateTime.now().millisecondsSinceEpoch) {
        await clear(scope, incident);
        return [];
      }
      final count = (value['count'] as num).toInt();
      if (count < 0 || count > 9) return [];
      final dir = await _dir(scope, incident);
      final images = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        final file = File('${dir.path}/$i.jpg');
        if (!await file.exists()) return [];
        images.add(await file.readAsBytes());
      }
      return images;
    } catch (_) {
      return [];
    }
  }

  static Future<void> clear(String scope, String incident) {
    if (scope.isEmpty) return Future.value();
    final result = _tail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('image_draft_${_id(scope, incident)}');
      final dir = await _dir(scope, incident);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    _tail = result.catchError((_) {});
    return result;
  }
}
