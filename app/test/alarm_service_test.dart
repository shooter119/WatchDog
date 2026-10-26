import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/alarm_service.dart';

class _Player extends Fake implements AudioPlayer {
  PlayerState playback = PlayerState.stopped;
  AudioContext? context;
  PlayerMode? modeUsed;
  ReleaseMode? releaseUsed;
  int starts = 0;
  bool failNextStart = false;
  Completer<void>? sourceWait;

  @override
  PlayerState get state => playback;
  @override
  Future<void> setAudioContext(AudioContext value) async => context = value;
  @override
  Future<void> setPlayerMode(PlayerMode value) async => modeUsed = value;
  @override
  Future<void> setSource(Source source) async {
    await sourceWait?.future;
  }
  @override
  Future<void> setReleaseMode(ReleaseMode value) async => releaseUsed = value;
  @override
  Future<void> resume() async {
    starts++;
    if (failNextStart) {
      failNextStart = false;
      throw StateError('播放启动失败');
    }
    playback = PlayerState.playing;
  }
  @override
  Future<void> stop() async => playback = PlayerState.stopped;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('持续报警使用闹钟流混音，正常播放不重复启动，暂停后可以恢复', () async {
    final player = _Player();
    final alarm = AlarmService(player: player);
    await alarm.startAlarmLoop();
    expect(player.modeUsed, PlayerMode.mediaPlayer);
    expect(player.context!.android.usageType, AndroidUsageType.alarm);
    expect(player.context!.android.audioFocus, AndroidAudioFocus.none);
    expect(player.releaseUsed, ReleaseMode.loop);
    await alarm.startAlarmLoop();
    expect(player.starts, 1);
    player.playback = PlayerState.paused;
    await alarm.startAlarmLoop();
    expect(player.starts, 2);
    alarm.soundEnabled = false;
    await alarm.startAlarmLoop();
    expect(player.playback, PlayerState.stopped);
  });

  test('报警启动失败不会锁死循环状态，下一次检查可重试', () async {
    final player = _Player()..failNextStart = true;
    final alarm = AlarmService(player: player);
    await expectLater(alarm.startAlarmLoop(), throwsStateError);
    await alarm.startAlarmLoop();
    expect(player.starts, 2);
    expect(player.playback, PlayerState.playing);
  });

  test('准备期间停止报警不会在准备结束后误响', () async {
    final player = _Player()..sourceWait = Completer<void>();
    final alarm = AlarmService(player: player);
    final starting = alarm.startAlarmLoop();
    await Future<void>.delayed(Duration.zero);
    await alarm.stopAlarm();
    player.sourceWait!.complete();
    await starting;
    expect(player.starts, 0);
    expect(player.playback, PlayerState.stopped);
  });

}
