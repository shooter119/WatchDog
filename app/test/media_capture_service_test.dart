import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/local_media_store.dart';
import 'package:watchdog/services/media_capture_service.dart';

class _DeleteStore extends LocalMediaStore {
  _DeleteStore() : super.forTesting();

  final List<String> deletedIds = [];
  bool failDelete = false;

  @override
  Future<void> deleteById(String id) async {
    if (failDelete) throw StateError('database unavailable');
    deletedIds.add(id);
  }
}

LocalMedia _media({
  required String path,
  String sourcePath = '',
  List<String> frames = const [],
}) {
  return LocalMedia(
    id: 'media-cleanup-1',
    incidentId: 'incident-1',
    kind: 'photo',
    path: path,
    sourcePath: sourcePath,
    durationMs: 0,
    capturedAt: 1,
    lat: null,
    lon: null,
    address: '',
    weather: '',
    transcript: '',
    segments: const [],
    frames: frames,
    observationId: '',
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('后台清理未在预期时间内完成');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late _DeleteStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('watchdog-media-cleanup-');
    store = _DeleteStore();
    LocalMediaStore.overrideInstance = store;
  });

  tearDown(() {
    LocalMediaStore.overrideInstance = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('removeLocalCopy 删除工作文件并清理数据库记录', () async {
    final watermarked = File('${temp.path}/IMG_1_WM.jpg')
      ..writeAsBytesSync([1]);
    final source = File('${temp.path}/SRC_IMG_1.jpg')..writeAsBytesSync([2]);
    final framesDir = Directory('${temp.path}/frames_media-cleanup-1')
      ..createSync();
    final frame = File('${framesDir.path}/frame-1.jpg')..writeAsBytesSync([3]);

    await MediaCaptureService.removeLocalCopy(
      _media(
        path: watermarked.path,
        sourcePath: source.path,
        frames: [frame.path],
      ),
    );

    expect(store.deletedIds, ['media-cleanup-1']);
    await _waitUntil(
      () =>
          !watermarked.existsSync() &&
          !source.existsSync() &&
          !frame.existsSync() &&
          !framesDir.existsSync() &&
          !Directory('${temp.path}/.cleanup').existsSync(),
    );
  });

  test('数据库删除失败时保留清理标记和文件，供下次启动重试', () async {
    final watermarked = File('${temp.path}/IMG_2_WM.jpg')
      ..writeAsBytesSync([1]);
    final source = File('${temp.path}/SRC_IMG_2.jpg')..writeAsBytesSync([2]);
    store.failDelete = true;

    await MediaCaptureService.removeLocalCopy(
      _media(path: watermarked.path, sourcePath: source.path),
    );

    expect(store.deletedIds, isEmpty);
    expect(watermarked.existsSync(), isTrue);
    expect(source.existsSync(), isTrue);
    expect(Directory('${temp.path}/.cleanup').existsSync(), isTrue);
  });
}
