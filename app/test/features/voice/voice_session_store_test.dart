import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/features/voice/data/models/voice_parse.dart';
import 'package:watchdog/features/voice/state/voice_draft_person.dart';
import 'package:watchdog/features/voice/state/voice_session_store.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/local_asr_service.dart';
import 'package:watchdog/services/realtime_asr_service.dart';

class _FakeAudioService extends AudioService {
  _FakeAudioService({
    this.permissionResult = true,
    this.permissionCompleter,
    this.throwOnPermission = false,
    Uint8List? stopBytes,
  }) : _stopBytes = stopBytes ?? Uint8List(128);

  bool permissionResult;
  Completer<bool>? permissionCompleter;
  bool throwOnPermission;
  final Uint8List _stopBytes;
  final StreamController<double> ampCtrl = StreamController<double>.broadcast();

  bool _recording = false;
  int starts = 0;
  int stops = 0;

  @override
  bool get isRecording => _recording;

  @override
  Future<bool> hasPermission() async {
    if (throwOnPermission) throw StateError('权限服务异常');
    if (permissionCompleter != null) return permissionCompleter!.future;
    return permissionResult;
  }

  @override
  Future<void> start() async {
    starts++;
    _recording = true;
  }

  @override
  Stream<double> amplitudeStream() => ampCtrl.stream;

  @override
  Future<Uint8List> stop() async {
    stops++;
    _recording = false;
    return _stopBytes;
  }

  @override
  Future<void> dispose() async {
    await ampCtrl.close();
  }
}

class _FakeRealtimeSession implements VoiceRealtimeSession {
  _FakeRealtimeSession({
    required this.onText,
    this.throwOnStart = false,
    this.throwOnStop = false,
    this.finalText = '',
    Uint8List? wavBytes,
  }) : _wavBytes = wavBytes ?? Uint8List(200);

  final RealtimeTextCallback onText;
  final bool throwOnStart;
  final bool throwOnStop;
  final String finalText;
  final Uint8List _wavBytes;
  final StreamController<double> ampCtrl = StreamController<double>.broadcast();

  int starts = 0;
  int stops = 0;
  int cancels = 0;
  int disposes = 0;

  void emitPartial(String text) => onText(text, finalText: false);

  @override
  Future<void> start({String? opId}) async {
    starts++;
    if (throwOnStart) throw StateError('ws connect failed');
  }

  @override
  Stream<double> amplitudeStream() => ampCtrl.stream;

  @override
  Future<RealtimeAsrResult> stop() async {
    stops++;
    final res = RealtimeAsrResult(text: finalText, wavBytes: _wavBytes);
    if (throwOnStop) {
      throw RealtimeAsrException(StateError('stream broken'), res);
    }
    return res;
  }

  @override
  Future<Uint8List> cancel() async {
    cancels++;
    return _wavBytes;
  }

  @override
  Future<void> dispose() async {
    disposes++;
    if (!ampCtrl.isClosed) await ampCtrl.close();
  }
}

class _FakeLocalAsr extends LocalAsrService {
  _FakeLocalAsr({this.reply = '张三20兆帕进场'});

  String reply;
  int calls = 0;
  List<String> lastHotwords = const <String>[];

  @override
  Future<String> transcribe(
    Uint8List wavBytes, {
    List<String> hotwords = const <String>[],
  }) async {
    calls++;
    lastHotwords = List<String>.of(hotwords);
    return reply;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('VoiceDraftPerson & 容积提取纯逻辑', () {
    test('提取与标准化气瓶容积（9升/九升/6.8升/非法值）', () {
      expect(extractCylinderVolumeL('张三20兆帕，钢瓶9升'), 9.0);
      expect(extractCylinderVolumeL('全部九公升气瓶'), 9.0);
      expect(extractCylinderVolumeL('使用6.8升气瓶'), 6.8);
      expect(extractCylinderVolumeL('使用12升气瓶'), isNull);
      expect(extractCylinderVolumeL('张三20兆帕进场'), isNull);
      expect(normalizeCylinderVolume(9.0), 9.0);
      expect(normalizeCylinderVolume(5.0), 6.8);
    });

    test('单人与批量人员校验规则与可用时长公式', () {
      const params = VoiceCalcParams(cylinderVolL: 6.8, consumptionLpm: 80);
      expect(params.durationMinFor(20).round(), 17);
      expect(params.durationMinFor(20, cylinderVolL: 9.0).round(), 23);

      const missingName = VoiceDraftPerson(id: '1', name: '', pressureText: '20');
      const missingP = VoiceDraftPerson(id: '2', name: '张三', pressureText: '');
      const badP = VoiceDraftPerson(id: '3', name: '李四', pressureText: '55');
      const badVol = VoiceDraftPerson(
        id: '4',
        name: '王五',
        pressureText: '20',
        volumeL: 12.0,
      );
      const ok = VoiceDraftPerson(id: '5', name: '赵六', pressureText: '22');

      expect(missingName.validate(), '缺少姓名');
      expect(missingP.validate(), '「张三」缺少气瓶压力');
      expect(badP.validate(), '「李四」压力数值异常');
      expect(badVol.validate(), '「王五」气瓶容积只能选择 6.8L 或 9L');
      expect(ok.validate(), isNull);
      expect(
        validateVoiceDrafts([missingName, missingP, ok]),
        ['1. 缺少姓名', '2. 「张三」缺少气瓶压力'],
      );
    });
  });

  group('VoiceSessionStore 状态机与并发/回退链路', () {
    testWidgets('50 秒进入预警态并在 60 秒自动触发 finishRecording', (tester) async {
      final audio = _FakeAudioService();
      VoiceFinishOutcome? autoOutcome;
      var elapsedSeconds = 0;
      final baseTime = DateTime(2026, 1, 1);
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        cloudTranscribe: (_, {String? opId}) async => '张三20兆帕进场',
        onAutoFinished: (outcome) => autoOutcome = outcome,
        now: () => baseTime.add(Duration(seconds: elapsedSeconds)),
      );

      await store.beginRecording();
      expect(store.isRecording, isTrue);
      expect(store.isWarningPhase, isFalse);

      elapsedSeconds = 50;
      await tester.pump(const Duration(seconds: 50));
      expect(store.recordingSeconds, 50);
      expect(store.remainingSeconds, 10);
      expect(store.isWarningPhase, isTrue);

      elapsedSeconds = 60;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(audio.stops, 1);
      expect(store.isConfirming, isTrue);
      expect(autoOutcome?.type, VoiceFinishOutcomeType.entryConfirm);
      expect(store.drafts.single.name, '张三');

      store.dispose();
      await audio.dispose();
    });

    test('权限检查抛异常进入 error 态且不残留启动锁', () async {
      final audio = _FakeAudioService(throwOnPermission: true);
      final store = VoiceSessionStore(audioService: audio);

      await store.beginRecording();
      expect(store.hasError, isTrue);
      expect(store.permissionDenied, isFalse);
      expect(store.errorMessage, contains('麦克风权限检查失败'));

      store.dispose();
      await audio.dispose();
    });

    test('权限弹窗响应慢时重复 beginRecording 仅允许一次启动', () async {
      final perm = Completer<bool>();
      final audio = _FakeAudioService(permissionCompleter: perm);
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        cloudTranscribe: (_, {String? opId}) async => '张三20兆帕进场',
      );

      final first = store.beginRecording();
      final second = store.beginRecording();
      perm.complete(true);
      await Future.wait([first, second]);

      expect(audio.starts, 1);
      expect(store.isRecording, isTrue);

      await store.cancelRecording();
      store.dispose();
      await audio.dispose();
    });

    test('权限尚未返回前松手 finishRecording 会撤销启动且不泄漏录音', () async {
      final perm = Completer<bool>();
      final audio = _FakeAudioService(permissionCompleter: perm);
      final store = VoiceSessionStore(audioService: audio);

      final startFuture = store.beginRecording();
      final finishOutcome = await store.finishRecording();
      expect(finishOutcome.type, VoiceFinishOutcomeType.cancelled);

      perm.complete(true);
      await startFuture;
      expect(audio.starts, 0);
      expect(store.isIdle, isTrue);

      store.dispose();
      await audio.dispose();
    });

    test('权限被拒进入 error 态并标记 permissionDenied', () async {
      final audio = _FakeAudioService(permissionResult: false);
      final store = VoiceSessionStore(audioService: audio);

      await store.beginRecording();
      expect(store.hasError, isTrue);
      expect(store.permissionDenied, isTrue);
      expect(store.errorMessage, '需要麦克风权限');

      store.dispose();
      await audio.dispose();
    });

    test('振幅流实时刷新 amplitude 且松手后复位', () async {
      final audio = _FakeAudioService();
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        cloudTranscribe: (_, {String? opId}) async => '张三20兆帕进场',
      );

      await store.beginRecording();
      audio.ampCtrl.add(0.82);
      await Future<void>.delayed(Duration.zero);
      expect(store.amplitude, 0.82);

      await store.finishRecording();
      expect(store.amplitude, 0.15);

      store.dispose();
      await audio.dispose();
    });

    test('实时流式识别成功：推送实时字幕并跳过批量云端转写', () async {
      final audio = _FakeAudioService();
      _FakeRealtimeSession? createdSession;
      var batchCalls = 0;
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        realtimeSessionFactory: (onText) {
          createdSession = _FakeRealtimeSession(
            onText: onText,
            finalText: '张三20兆帕进场',
          );
          return createdSession!;
        },
        cloudTranscribe: (_, {String? opId}) async {
          batchCalls++;
          return 'should-not-run';
        },
      );

      await store.beginRecording();
      createdSession!.emitPartial('张三20');
      expect(store.transcript, '张三20');

      final outcome = await store.finishRecording();
      expect(outcome.type, VoiceFinishOutcomeType.entryConfirm);
      expect(batchCalls, 0);
      expect(createdSession!.disposes, 1);
      expect(store.drafts.single.name, '张三');

      store.dispose();
      await audio.dispose();
    });

    test('实时建连失败自动降级到 AudioService 兼容录音 + 云端批量转写', () async {
      final audio = _FakeAudioService();
      var batchCalls = 0;
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        realtimeSessionFactory: (onText) =>
            _FakeRealtimeSession(onText: onText, throwOnStart: true),
        cloudTranscribe: (_, {String? opId}) async {
          batchCalls++;
          return '李四22兆帕进场';
        },
      );

      await store.beginRecording();
      expect(audio.starts, 1);

      final outcome = await store.finishRecording();
      expect(outcome.type, VoiceFinishOutcomeType.entryConfirm);
      expect(batchCalls, 1);
      expect(store.drafts.single.name, '李四');

      store.dispose();
      await audio.dispose();
    });

    test('实时流式 stop 抛异常时降级批量云端，云端再失败则回退 LocalAsrService 注入热词', () async {
      final audio = _FakeAudioService();
      final localAsr = _FakeLocalAsr(reply: '王五24兆帕进场');
      var cloudCalls = 0;
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        realtimeSessionFactory: (onText) => _FakeRealtimeSession(
          onText: onText,
          throwOnStop: true,
          wavBytes: Uint8List(256),
        ),
        cloudTranscribe: (_, {String? opId}) async {
          cloudCalls++;
          throw StateError('503');
        },
        localAsr: localAsr,
        asrHotwordsProvider: () => const ['王五', '兆帕'],
      );

      await store.beginRecording();
      final outcome = await store.finishRecording();

      expect(cloudCalls, 1);
      expect(localAsr.calls, 1);
      expect(localAsr.lastHotwords, ['王五', '兆帕']);
      expect(outcome.type, VoiceFinishOutcomeType.entryConfirm);
      expect(store.drafts.single.name, '王五');

      store.dispose();
      await audio.dispose();
    });

    test('实时流未录到有效 PCM（<=44B WAV 头）直接报无语音不调用批量转写', () async {
      final audio = _FakeAudioService();
      var batchCalls = 0;
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        realtimeSessionFactory: (onText) => _FakeRealtimeSession(
          onText: onText,
          finalText: '',
          wavBytes: Uint8List(44),
        ),
        cloudTranscribe: (_, {String? opId}) async {
          batchCalls++;
          return '不该执行';
        },
      );

      await store.beginRecording();
      final outcome = await store.finishRecording();

      expect(outcome.type, VoiceFinishOutcomeType.noSpeech);
      expect(batchCalls, 0);
      expect(store.hasError, isTrue);
      expect(store.errorMessage, '未识别到语音，请再说一次');

      store.dispose();
      await audio.dispose();
    });

    test('云端解析失败自动回退本地 LocalParser 并保留名单过滤', () async {
      final audio = _FakeAudioService();
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        isCloudParseEnabled: () => true,
        cloudTranscribe: (_, {String? opId}) async => '张三20兆帕进场',
        cloudParse: (_, {String? opId}) async => throw StateError('timeout'),
        rosterNamesProvider: () => const ['张三'],
      );

      await store.beginRecording();
      final outcome = await store.finishRecording();
      expect(outcome.type, VoiceFinishOutcomeType.entryConfirm);
      expect(store.drafts.single.name, '张三');
      expect(store.drafts.single.pressureMpa, 20.0);

      store.dispose();
      await audio.dispose();
    });

    test('分批语音累加：同名更正压力、新人追加、语音声明9升同步更新既有草稿', () async {
      final audio = _FakeAudioService();
      final replies = <String>[
        '张三20兆帕，李四22兆帕进场',
        '张三15兆帕，王五24兆帕，钢瓶9升进场',
      ];
      var callIdx = 0;
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        cloudTranscribe: (_, {String? opId}) async => replies[callIdx++],
        rosterNamesProvider: () => const ['张三', '李四', '王五'],
      );

      await store.beginRecording();
      await store.finishRecording();
      expect(store.drafts.length, 2);
      expect(store.drafts[0].volumeL, 6.8);
      expect(store.drafts[1].volumeL, 6.8);

      await store.beginRecording();
      await store.finishRecording();
      expect(store.drafts.length, 3);
      expect(store.drafts[0].name, '张三');
      expect(store.drafts[0].pressureMpa, 15.0);
      expect(store.drafts[0].volumeL, 9.0);
      expect(store.drafts[1].name, '李四');
      expect(store.drafts[1].volumeL, 9.0);
      expect(store.drafts[2].name, '王五');
      expect(store.drafts[2].pressureMpa, 24.0);
      expect(store.drafts[2].volumeL, 9.0);

      store.dispose();
      await audio.dispose();
    });

    test('非名单姓名自动留空并保留 sourceName；出场指令不清空待确认名单', () async {
      final audio = _FakeAudioService();
      var round = 0;
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        isCloudParseEnabled: () => true,
        cloudTranscribe: (_, {String? opId}) async =>
            round == 0 ? '张三20兆帕，李四22兆帕' : '张三撤离',
        cloudParse: (_, {String? opId}) async {
          if (round++ == 0) {
            return ParseResult(
              intent: VoiceIntent.entry,
              action: 'enter',
              people: const [
                ParsePerson(name: '张三', pressureMpa: 20),
                ParsePerson(name: '李四', pressureMpa: 22),
              ],
            );
          }
          return ParseResult(
            intent: VoiceIntent.exit,
            action: 'exit',
            people: const [ParsePerson(name: '张三')],
          );
        },
        rosterNamesProvider: () => const ['张三'],
      );

      await store.beginRecording();
      await store.finishRecording();
      expect(store.drafts[0].name, '张三');
      expect(store.drafts[0].sourceName, isNull);
      expect(store.drafts[1].name, '');
      expect(store.drafts[1].sourceName, '李四');

      await store.beginRecording();
      final exitOutcome = await store.finishRecording();
      expect(exitOutcome.type, VoiceFinishOutcomeType.exit);
      expect(store.hasPendingDrafts, isTrue);
      expect(store.drafts.length, 2);

      store.showPendingConfirm();
      expect(store.isConfirming, isTrue);
      expect(store.transcript, '已录入 2 人，待统一确认');

      store.dispose();
      await audio.dispose();
    });

    test('进场无姓名 / 环境音 / 日志 / 提问意图精确落入对应状态与结果', () async {
      final audio = _FakeAudioService();
      final parses = <ParseResult>[
        ParseResult(intent: VoiceIntent.entry, action: 'enter', people: const []),
        ParseResult(intent: VoiceIntent.ignore, action: 'unknown', people: const []),
        ParseResult(intent: VoiceIntent.note, action: 'unknown', people: const []),
        ParseResult(intent: VoiceIntent.ask, action: 'unknown', people: const []),
      ];
      var i = 0;
      final store = VoiceSessionStore(
        audioService: audio,
        isCloudAsrEnabled: () => true,
        isCloudParseEnabled: () => true,
        cloudTranscribe: (_, {String? opId}) async => '语音文本$i',
        cloudParse: (_, {String? opId}) async => parses[i++],
      );

      await store.beginRecording();
      final r0 = await store.finishRecording();
      expect(r0.type, VoiceFinishOutcomeType.entryEmpty);
      expect(store.hasError, isTrue);
      expect(store.errorMessage, contains('未识别到进场人员姓名'));

      await store.beginRecording();
      final r1 = await store.finishRecording();
      expect(r1.type, VoiceFinishOutcomeType.ignored);
      expect(store.hasError, isTrue);
      expect(store.errorMessage, '未识别到有效指令，请重新录入');

      await store.beginRecording();
      final r2 = await store.finishRecording();
      expect(r2.type, VoiceFinishOutcomeType.note);
      expect(store.isIdle, isTrue);

      await store.beginRecording();
      final r3 = await store.finishRecording();
      expect(r3.type, VoiceFinishOutcomeType.ask);
      expect(store.isIdle, isTrue);

      store.dispose();
      await audio.dispose();
    });
  });
}
