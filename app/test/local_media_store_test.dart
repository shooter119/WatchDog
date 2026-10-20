import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/local_media_store.dart';

LocalMedia _legacyMedia() {
  return const LocalMedia(
    id: 'media-1',
    incidentId: 'incident-1',
    kind: 'photo',
    path: '/tmp/IMG_1_WM.jpg',
    durationMs: 0,
    capturedAt: 1,
    lat: null,
    lon: null,
    address: '',
    weather: '',
    transcript: '',
    segments: [],
    frames: [],
    observationId: '',
  );
}

void main() {
  test('旧版数据库行缺少 source_path 时按无母版资料读取', () {
    final media = LocalMedia.fromRow({
      'id': 'media-1',
      'incident_id': 'incident-1',
      'kind': 'photo',
      'path': '/tmp/IMG_1_WM.jpg',
      'duration_ms': 0,
      'captured_at': 1,
      'address': '',
      'weather': '',
      'transcript': '',
      'segments': '[]',
      'frames': '[]',
      'observation_id': '',
    });

    expect(media.sourcePath, isEmpty);
  });

  test('copyWith 可以将已清理的隐藏母版路径清空', () {
    final withSource = _legacyMedia().copyWith(
      sourcePath: '/tmp/SRC_IMG_1.jpg',
    );

    expect(withSource.sourcePath, '/tmp/SRC_IMG_1.jpg');
    expect(withSource.copyWith(sourcePath: '').sourcePath, isEmpty);
  });
}
