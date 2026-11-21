import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/video_resources.dart';
import 'package:watchdog/services/video_playback_session.dart';

const _resource = VideoResource(
  id: 'camera-1',
  name: '现场监控',
  streamUrl: 'https://video.example.test/live.flv',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PostgreSQL BIGINT 字符串可解析为整数', () {
    final resource = VideoResource.fromJson({
      'id': 'camera-1',
      'name': '现场监控',
      'stream_url': 'https://video.example.test/live.flv',
      'description': '',
      'active': true,
      'sort_order': '10',
      'version': '2',
      'updated_at': '1792510609327',
    });

    expect(resource.sortOrder, 10);
    expect(resource.version, 2);
    expect(resource.updatedAt, 1792510609327);
  });

  test('reattachSurface 不改变会话状态，无会话时安全返回', () {
    final session = VideoPlaybackSession.forTesting(
      resource: _resource,
      status: VideoPlaybackStatus.playing,
    );
    final beforeStatus = session.status;
    final beforePresentation = session.presentation;
    expect(() => session.reattachSurface(), returnsNormally);
    expect(session.status, beforeStatus);
    expect(session.presentation, beforePresentation);
    session.dispose();

    final idle = VideoPlaybackSession.forTesting();
    var notified = 0;
    idle.addListener(() => notified++);
    expect(() => idle.reattachSurface(), returnsNormally);
    expect(notified, 0, reason: '无播放器时不应触发重建通知');
    idle.dispose();
  });
}
